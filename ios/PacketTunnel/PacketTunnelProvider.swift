import Darwin
import Foundation
import Network
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "flclash.tunnel.lifecycle", qos: .userInitiated)
    private let rpcQueue = DispatchQueue(label: "flclash.tunnel.rpc", qos: .userInitiated, attributes: .concurrent)
    private let logger = Logger(subsystem: "com.follow.clash.ios", category: "PacketTunnel")
    private static let ipv4 = "198.19.255.1"
    private static let ipv6 = "fd00:fc::1"
    private static let mtu = 1400
    private var generation = 0
    private var pump: PacketPump?
    private var monitor: NWPathMonitor?
    private var recover: DispatchWorkItem?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        queue.async {
            self.generation += 1
            let current = self.generation
            do {
                let storage = try CoreStorage()
                try CoreSnapshot(storage: storage).restore(storage: storage, forTunnel: true)
                let failure = "\(Self.ipv4)/30".withCString { v4 in
                    "\(Self.ipv6)/126".withCString { v6 in
                        flclash_core_start(v4, v6, Int32(Self.mtu))
                    }
                }
                if let failure {
                    defer { free(failure) }
                    throw TunnelError(message: String(cString: failure))
                }
                self.setTunnelNetworkSettings(self.networkSettings()) { error in
                    self.queue.async {
                        if self.generation != current {
                            completionHandler(TunnelError(message: "VPN start was superseded"))
                            return
                        }
                        if let error {
                            self.cleanup()
                            completionHandler(error)
                            return
                        }
                        let pump = PacketPump(flow: self.packetFlow)
                        self.pump = pump
                        pump.start()
                        self.watchNetwork()
                        completionHandler(nil)
                    }
                }
            } catch {
                self.cleanup()
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.generation += 1
            self.cleanup()
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let text = String(data: messageData, encoding: .utf8), let id = UUID(uuidString: text) else {
            completionHandler?(nil)
            return
        }
        rpcQueue.async {
            do {
                guard self.queue.sync(execute: { self.pump != nil }) else {
                    throw TunnelError(message: "Packet Tunnel is not active")
                }
                let storage = try CoreStorage()
                let data = try Data(contentsOf: storage.rpcFile(id))
                let request = try CoreRequest(data: data)
                let result: Data
                if request.method == "ios.events" {
                    result = try CoreBridge.events()
                } else {
                    if request.method == "config.setup" { try storage.copyBaseConfigIfNeeded(request) }
                    result = try CoreBridge.invoke(data)
                }
                try storage.write(result, to: storage.rpcFile(id, response: true))
                completionHandler?(Data([1]))
            } catch {
                self.logger.error("Tunnel RPC failed: \(error.localizedDescription, privacy: .private)")
                completionHandler?(nil)
            }
        }
    }

    private func networkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Self.ipv4)
        let ipv4 = NEIPv4Settings(addresses: [Self.ipv4], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        let ipv6 = NEIPv6Settings(addresses: [Self.ipv6], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        let dns = NEDNSSettings(servers: ["198.19.255.2", "fd00:fc::2"])
        dns.matchDomains = [""]
        settings.ipv4Settings = ipv4
        settings.ipv6Settings = ipv6
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: Self.mtu)
        return settings
    }

    private func watchNetwork() {
        let monitor = NWPathMonitor()
        var initialPath = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.pump != nil else { return }
            let first = initialPath
            initialPath = false
            guard !first || path.status != .satisfied else { return }
            self.recover?.cancel()
            self.reasserting = true
            guard path.status == .satisfied else { return }
            let reconnect = DispatchWorkItem { [weak self] in
                guard let self, self.pump != nil else { return }
                flclash_core_network_changed()
                self.reasserting = false
                self.recover = nil
            }
            self.recover = reconnect
            self.queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: reconnect)
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    private func cleanup() {
        recover?.cancel()
        recover = nil
        monitor?.cancel()
        monitor = nil
        reasserting = false
        pump?.stop()
        pump = nil
        flclash_core_stop()
    }
}
