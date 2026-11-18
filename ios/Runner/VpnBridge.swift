import Flutter
import Foundation
import NetworkExtension

@MainActor
final class VpnBridge {
    private let channel: FlutterMethodChannel
    private let coreQueue = DispatchQueue(label: "flclash.app.core", qos: .userInitiated, attributes: .concurrent)
    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var intent = 0
    private var version: Int?
    private var mutations: Task<Void, Never>?
    private var subscriptions: [String: Data] = [:]

    private static let offlineMethods: Set<String> = [
        "core.init", "core.initialized", "config.validate", "config.decrypt", "config.read",
        "profile.base", "profile.outbounds", "profile.build", "proxy.validate", "proxy.convert",
        "shareLink.encode", "shareLink.decode", "filter.validate", "ruleSet.compile",
    ]
    private static let savedMethods: Set<String> = ["config.setup", "config.update", "proxy.select"]

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.follow.clash/ios-vpn", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            Task { @MainActor in
                guard let self else {
                    result(FlutterError(code: "ios_core", message: "VPN bridge is unavailable", details: nil))
                    return
                }
                await self.handle(call, result: result)
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) {
            [weak self] note in
            Task { @MainActor in
                guard let self, let connection = note.object as? NEVPNConnection,
                      connection === self.manager?.connection else { return }
                self.channel.invokeMethod("statusChanged", arguments: self.status())
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
        do {
            switch call.method {
            case "coreHome": result(try CoreStorage().app.path)
            case "status":
                if manager == nil { manager = try await existingManager() }
                result(status())
            case "start": try await start(); result(status())
            case "stop": try await stop(); result(status())
            case "events":
                let storage = try CoreStorage()
                let request = try CoreRequest(method: "ios.events").encoded()
                let data: Data
                if let session = activeSession {
                    data = try await send(request, session: session, storage: storage, timeout: 5)
                } else {
                    data = try CoreBridge.events()
                }
                result(FlutterStandardTypedData(bytes: data))
            case "invoke":
                guard let bytes = call.arguments as? FlutterStandardTypedData else {
                    throw TunnelError(message: "Core request must be UTF-8 bytes")
                }
                let request = try CoreRequest(data: bytes.data)
                if Self.savedMethods.contains(request.method) {
                    let previous = mutations
                    mutations = Task { @MainActor in
                        await previous?.value
                        do { result(try await self.invoke(request, data: bytes.data)) }
                        catch { result(Self.flutterError(error)) }
                    }
                } else {
                    result(try await invoke(request, data: bytes.data))
                }
            default: result(FlutterMethodNotImplemented)
            }
        } catch {
            result(Self.flutterError(error))
        }
    }

    private static func flutterError(_ error: Error) -> FlutterError {
        FlutterError(code: "ios_core", message: error.localizedDescription, details: nil)
    }

    private var activeSession: NETunnelProviderSession? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected || session.status == .reasserting else { return nil }
        return session
    }

    private func status() -> [String: Any] {
        let connection = manager?.connection
        let value: String
        switch connection?.status {
        case .connected: value = "connected"
        case .connecting: value = "connecting"
        case .reasserting: value = "reasserting"
        case .disconnecting: value = "disconnecting"
        default: value = "disconnected"
        }
        var info: [String: Any] = ["state": value]
        if let time = connection?.connectedDate {
            info["connectedAt"] = Int64(time.timeIntervalSince1970 * 1000)
        }
        return info
    }

    private func invoke(_ request: CoreRequest, data: Data) async throws -> FlutterStandardTypedData {
        let storage = try CoreStorage()
        if request.method == "core.init" { version = request.arguments["version"] as? Int }
        let session = Self.offlineMethods.contains(request.method) ? nil : activeSession
        let response: Data
        if let session {
            response = try await send(data, session: session, storage: storage)
        } else {
            response = try await withCheckedThrowingContinuation { continuation in
                coreQueue.async { continuation.resume(with: Result { try CoreBridge.invoke(data) }) }
            }
        }
        switch request.method {
        case "log.start", "log.stop": subscriptions["log"] = data
        case "route.watch": subscriptions["route"] = data
        default: break
        }
        if Self.savedMethods.contains(request.method), let version {
            let forTunnel = session != nil
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                coreQueue.async {
                    reply.resume(with: Result {
                        try Self.save(request: request, response: response, storage: storage,
                                      forTunnel: forTunnel, version: version)
                    })
                }
            }
        }
        return FlutterStandardTypedData(bytes: response)
    }

    private nonisolated static func save(request: CoreRequest, response: Data, storage: CoreStorage,
                                         forTunnel: Bool, version: Int) throws {
        let values = try CoreBridge.response(response)
        guard values["error"] == nil else { return }
        if request.method == "config.setup" {
            let home = forTunnel ? storage.tunnel : storage.app
            let configuration = try String(contentsOf: home.appendingPathComponent("config.yaml"), encoding: .utf8)
            try CoreSnapshot(version: version, setup: request.arguments, configuration: configuration).save(storage: storage)
            return
        }
        guard var snapshot = try? CoreSnapshot(storage: storage) else { return }
        if request.method == "config.update" {
            snapshot.update.merge(request.arguments.filter { !($0.value is NSNull) }) { _, new in new }
        } else if let selection = values["result"] as? [String: Any],
                  (selection["message"] as? String ?? "").isEmpty,
                  let group = request.arguments["group-name"] as? String,
                  let proxy = request.arguments["proxy-name"] as? String {
            var selected = snapshot.setup["selected-map"] as? [String: String] ?? [:]
            selected[group] = proxy
            snapshot.setup["selected-map"] = selected
        }
        try snapshot.save(storage: storage)
    }

    private func send(_ data: Data, session: NETunnelProviderSession, storage: CoreStorage, timeout: TimeInterval = 180) async throws -> Data {
        let id = UUID()
        let request = storage.rpcFile(id)
        let response = storage.rpcFile(id, response: true)
        try storage.write(data, to: request)
        defer {
            try? FileManager.default.removeItem(at: request)
            try? FileManager.default.removeItem(at: response)
        }
        let ack: Data? = try await withCheckedThrowingContinuation { continuation in
            let reply = ProviderReply(continuation)
            do {
                try session.sendProviderMessage(Data(id.uuidString.utf8)) { data in
                    reply.finish(.success(data))
                }
            } catch {
                reply.finish(.failure(error))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                reply.finish(.failure(TunnelError(message: "Packet Tunnel Core request timed out")))
            }
        }
        guard ack == Data([1]) else { throw TunnelError(message: "Packet Tunnel did not complete the Core request") }
        return try Data(contentsOf: response)
    }

    private func existingManager() async throws -> NETunnelProviderManager? {
        let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: managers ?? []) }
            }
        }
        return managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }
    }

    private var providerID: String { (Bundle.main.bundleIdentifier ?? "com.follow.clash.ios") + ".PacketTunnel" }

    private func start() async throws {
        if activeSession != nil { return }
        intent += 1
        let revision = intent
        await mutations?.value
        _ = try CoreSnapshot(storage: CoreStorage())
        let existing = try await existingManager()
        guard intent == revision else { throw CancellationError() }
        let vpn = existing ?? NETunnelProviderManager()
        if existing == nil || !vpn.isEnabled {
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = providerID
            configuration.serverAddress = "FlClash"
            vpn.protocolConfiguration = configuration
            vpn.localizedDescription = "FlClash"
            vpn.isEnabled = true
            try await vpn.saveToPreferences()
            try await vpn.loadFromPreferences()
        }
        guard intent == revision else { throw CancellationError() }
        manager = vpn
        if vpn.connection.status != .connecting { try vpn.connection.startVPNTunnel() }
        try await waitForStatus(running: true, revision: revision, connection: vpn.connection)
        if let session = activeSession, let storage = try? CoreStorage() {
            for data in Array(subscriptions.values) {
                _ = try? await send(data, session: session, storage: storage, timeout: 2)
            }
        }
    }

    private func stop() async throws {
        intent += 1
        let revision = intent
        if manager == nil { manager = try await existingManager() }
        guard intent == revision else { throw CancellationError() }
        guard let connection = manager?.connection else { return }
        connection.stopVPNTunnel()
        try await waitForStatus(running: false, revision: revision, connection: connection)
    }

    private func waitForStatus(running: Bool, revision: Int, connection: NEVPNConnection) async throws {
        for attempt in 0..<200 {
            guard intent == revision else { throw CancellationError() }
            let disconnected = connection.status == .disconnected || connection.status == .invalid
            if running && connection.status == .connected || !running && disconnected { return }
            if running && disconnected && attempt >= 10 {
                let error: Error? = await withCheckedContinuation { continuation in
                    connection.fetchLastDisconnectError { continuation.resume(returning: $0) }
                }
                throw error ?? TunnelError(message: "iOS disconnected before the tunnel started")
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if running && intent == revision { connection.stopVPNTunnel() }
        throw TunnelError(message: "iOS timed out while changing the VPN state")
    }
}

private final class ProviderReply {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Error>?

    init(_ continuation: CheckedContinuation<Data?, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Data?, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
