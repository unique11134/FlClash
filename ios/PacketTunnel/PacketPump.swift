import Darwin
import Foundation
import NetworkExtension

final class PacketPump {
    private static let packetLimit = 64
    private static let packetSize = 1500
    private let flow: NEPacketTunnelFlow
    private let queue = DispatchQueue(label: "flclash.packet-flow", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var outbound = [UInt8](repeating: 0, count: packetLimit * (packetSize + 2))

    init(flow: NEPacketTunnelFlow) { self.flow = flow }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.writeToSystem() }
            timer = source
            source.resume()
            readFromSystem()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func readFromSystem() {
        flow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.queue.async {
                guard self.timer != nil else { return }
                for offset in stride(from: 0, to: packets.count, by: Self.packetLimit) {
                    var batch = Data()
                    for packet in packets[offset..<min(offset + Self.packetLimit, packets.count)] {
                        guard packet.count <= Self.packetSize, packet.count >= 20 else { continue }
                        batch.append(UInt8(packet.count >> 8))
                        batch.append(UInt8(truncatingIfNeeded: packet.count))
                        batch.append(packet)
                    }
                    batch.withUnsafeBytes { bytes in
                        if let base = bytes.bindMemory(to: UInt8.self).baseAddress, !bytes.isEmpty {
                            flclash_core_write_packets(base, Int32(bytes.count))
                        }
                    }
                }
                self.readFromSystem()
            }
        }
    }

    private func writeToSystem() {
        let count = outbound.withUnsafeMutableBufferPointer { buffer in
            Int(flclash_core_read_packets(buffer.baseAddress, Int32(buffer.count)))
        }
        var offset = 0
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        while offset + 2 <= count {
            let length = Int(outbound[offset]) << 8 | Int(outbound[offset + 1])
            offset += 2
            guard length >= 20, offset + length <= count else { return }
            let version = outbound[offset] >> 4
            if version == 4 || version == 6 {
                packets.append(Data(outbound[offset..<(offset + length)]))
                protocols.append(NSNumber(value: version == 6 ? AF_INET6 : AF_INET))
            }
            offset += length
        }
        if !packets.isEmpty { _ = flow.writePackets(packets, withProtocols: protocols) }
    }
}
