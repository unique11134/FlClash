import Darwin
import Flutter
import Foundation
import NetworkExtension
import OSLog

private struct BridgeFailure: Error {
    let method: String
    let stage: String
    let category: String
    let cause: NSError

    var permissionDenied: Bool {
        if category == "app_group" { return true }
        guard category == "vpn" else { return false }
        var error: NSError? = cause
        for _ in 0..<8 {
            guard let current = error else { break }
            if (current.domain == "NEConfigurationErrorDomain" && current.code == 10) ||
                (current.domain == NSPOSIXErrorDomain && (current.code == Int(EACCES) || current.code == Int(EPERM))) {
                return true
            }
            error = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    var details: [String: Any] {
        ["method": method, "stage": stage, "category": category,
         "permissionDenied": permissionDenied, "error": Self.describe(cause, depth: 0)]
    }

    private static func describe(_ error: NSError, depth: Int) -> [String: Any] {
        var value: [String: Any] = ["domain": error.domain, "code": error.code, "message": error.localizedDescription]
        if depth < 7, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            value["underlying"] = describe(underlying, depth: depth + 1)
        }
        return value
    }
}

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
    private var storage: CoreStorage?
    private var sharedStorageFailure: BridgeFailure?
    private var vpnFailure: BridgeFailure?
    private var extensionFailure: BridgeFailure?
    private var failures: [String: BridgeFailure] = [:]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FlClash", category: "iOSBridge")

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
                    result(FlutterError(code: "ios_bridge_unavailable", message: "iOS bridge is unavailable", details: nil))
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
            case "coreHome": result(try runnerStorage(method: call.method).app.path)
            case "status":
                await refreshStatus()
                result(status())
            case "diagnostics":
                result(diagnostics())
            case "start": try await start(); result(status())
            case "stop": try await stop(); result(status())
            case "events":
                let storage = try runnerStorage(method: call.method)
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
                        catch { result(self.flutterError(error, method: request.method)) }
                    }
                } else {
                    result(try await invoke(request, data: bytes.data))
                }
            default: result(FlutterMethodNotImplemented)
            }
        } catch {
            result(flutterError(error, method: call.method))
        }
    }

    private func record(_ failure: BridgeFailure) {
        failures["\(failure.method)/\(failure.stage)"] = failure
        logger.error("\(failure.method, privacy: .public) \(failure.stage, privacy: .public) \(failure.cause.domain, privacy: .public) Code=\(failure.cause.code, privacy: .public) \(String(describing: failure.details), privacy: .private)")
    }

    private func flutterError(_ error: Error, method: String) -> FlutterError {
        let failure = error as? BridgeFailure ??
            BridgeFailure(method: method, stage: "dispatch", category: "bridge", cause: error as NSError)
        record(failure)
        if failure.permissionDenied && failure.category == "vpn" {
            vpnFailure = failure
            channel.invokeMethod("statusChanged", arguments: status())
        }
        return FlutterError(code: "ios_\(failure.category)", message: failure.cause.localizedDescription, details: failure.details)
    }

    private func runnerStorage(method: String) throws -> CoreStorage {
        if let storage {
            if let sharedStorageFailure, method == "coreHome" {
                record(BridgeFailure(method: method, stage: sharedStorageFailure.stage,
                                     category: sharedStorageFailure.category, cause: sharedStorageFailure.cause))
            }
            return storage
        }
        do {
            let shared = try CoreStorage()
            storage = shared
            sharedStorageFailure = nil
            return shared
        } catch let error as CoreStorageError {
            let failure = BridgeFailure(method: method, stage: "CoreStorage.AppGroup.\(error.stage)",
                                        category: error.stage == "containerURL" ? "app_group" : "storage",
                                        cause: error.underlying)
            sharedStorageFailure = failure
            record(failure)
            channel.invokeMethod("statusChanged", arguments: status())
        }
        do {
            let offline = try CoreStorage(privateContainer: true)
            storage = offline
            return offline
        } catch let error as CoreStorageError {
            throw BridgeFailure(method: method, stage: "CoreStorage.private.\(error.stage)",
                                category: "storage", cause: error.underlying)
        }
    }

    private func refreshStatus() async {
        checkExtension()
        guard manager == nil || vpnFailure != nil else { return }
        let revision = intent
        do {
            let existing = try await existingManager(method: "status")
            guard intent == revision else { return }
            manager = existing
            vpnFailure = nil
        } catch {
            guard intent == revision else { return }
            let failure = error as? BridgeFailure ?? BridgeFailure(
                method: "status", stage: "NETunnelProviderManager.loadAllFromPreferences", category: "vpn", cause: error as NSError
            )
            vpnFailure = failure
            record(failure)
        }
    }

    private lazy var extensionBundle: Bundle? = {
        Bundle.main.builtInPlugInsURL.flatMap { Bundle(url: $0.appendingPathComponent("PacketTunnel.appex")) }
    }()

    private func checkExtension() {
        guard extensionFailure == nil, extensionBundle?.bundleIdentifier != providerID else { return }
        let failure = BridgeFailure(method: "status", stage: "embeddedPacketTunnel", category: "extension", cause: NSError(
            domain: "FlClash.PacketTunnel", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The installed Packet Tunnel is missing or its bundle identifier does not match the app."]
        ))
        extensionFailure = failure
        record(failure)
    }

    private func diagnostics() -> [String: Any] {
        var report = status()
        report["bundleIdentifier"] = Bundle.main.bundleIdentifier
        report["expectedProviderIdentifier"] = providerID
        report["embeddedProviderIdentifier"] = (extensionBundle?.bundleIdentifier as Any?) ?? NSNull()
        report["appGroup"] = Bundle.main.object(forInfoDictionaryKey: "FlClashAppGroup")
        report["extensionAppGroup"] = extensionBundle?.object(forInfoDictionaryKey: "FlClashAppGroup") ?? NSNull()
        report["appProvisioningProfilePresent"] = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
        report["extensionProvisioningProfilePresent"] = extensionBundle?.url(forResource: "embedded", withExtension: "mobileprovision") != nil
        report["coreStorage"] = storage == nil ? "unresolved" : sharedStorageFailure == nil ? "shared" : "app-private"
        report["errors"] = failures.keys.sorted().compactMap { failures[$0]?.details }
        return report
    }

    private var activeSession: NETunnelProviderSession? {
        guard sharedStorageFailure == nil, let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected || session.status == .reasserting else { return nil }
        return session
    }

    private func status() -> [String: Any] {
        let blocking = [vpnFailure, sharedStorageFailure, extensionFailure].compactMap { $0 }
        if !blocking.isEmpty {
            return ["state": "unavailable", "permissionDenied": blocking.contains(where: \.permissionDenied)]
        }
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
        let storage = try runnerStorage(method: request.method)
        let session = Self.offlineMethods.contains(request.method) ? nil : activeSession
        let response: Data
        do {
            if let session {
                response = try await send(data, session: session, storage: storage)
            } else {
                response = try await withCheckedThrowingContinuation { continuation in
                    coreQueue.async { continuation.resume(with: Result { try CoreBridge.invoke(data) }) }
                }
            }
        } catch {
            throw BridgeFailure(method: request.method, stage: session == nil ? "CoreBridge.invoke" : "sendProviderMessage",
                                category: "core_invoke", cause: error as NSError)
        }
        if request.method == "core.init" {
            do {
                if let error = try CoreBridge.response(response)["error"] as? [String: Any] {
                    let failure = NSError(domain: "FlClash.Core", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Core rejected initialization"])
                    record(BridgeFailure(method: request.method, stage: "CoreBridge.response.\(error["code"] as? String ?? "unknown")",
                                         category: "core_init", cause: failure))
                } else {
                    version = request.arguments["version"] as? Int
                }
            } catch {
                throw BridgeFailure(method: request.method, stage: "CoreBridge.response", category: "core_init", cause: error as NSError)
            }
        }
        switch request.method {
        case "log.start", "log.stop": subscriptions["log"] = data
        case "route.watch": subscriptions["route"] = data
        default: break
        }
        if sharedStorageFailure == nil, Self.savedMethods.contains(request.method), let version {
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

    private func existingManager(method: String) async throws -> NETunnelProviderManager? {
        let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: BridgeFailure(method: method, stage: "NETunnelProviderManager.loadAllFromPreferences",
                                                                 category: "vpn", cause: error as NSError))
                } else {
                    continuation.resume(returning: managers ?? [])
                }
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
        let existing = try await existingManager(method: "start")
        guard intent == revision else { throw CancellationError() }
        checkExtension()
        if let failure = extensionFailure {
            throw BridgeFailure(method: "start", stage: failure.stage, category: failure.category, cause: failure.cause)
        }
        let storage = try runnerStorage(method: "start")
        if let failure = sharedStorageFailure {
            throw BridgeFailure(method: "start", stage: failure.stage, category: failure.category, cause: failure.cause)
        }
        do { _ = try CoreSnapshot(storage: storage) }
        catch { throw BridgeFailure(method: "start", stage: "CoreSnapshot.load", category: "storage", cause: error as NSError) }
        let vpn = existing ?? NETunnelProviderManager()
        if existing == nil || !vpn.isEnabled {
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = providerID
            configuration.serverAddress = "FlClash"
            vpn.protocolConfiguration = configuration
            vpn.localizedDescription = "FlClash"
            vpn.isEnabled = true
            do { try await vpn.saveToPreferences() }
            catch { throw BridgeFailure(method: "start", stage: "saveToPreferences", category: "vpn", cause: error as NSError) }
            do { try await vpn.loadFromPreferences() }
            catch { throw BridgeFailure(method: "start", stage: "loadFromPreferences", category: "vpn", cause: error as NSError) }
        }
        guard intent == revision else { throw CancellationError() }
        vpnFailure = nil
        manager = vpn
        do {
            if vpn.connection.status != .connecting { try vpn.connection.startVPNTunnel() }
        } catch {
            throw BridgeFailure(method: "start", stage: "startVPNTunnel", category: "vpn", cause: error as NSError)
        }
        do { try await waitForStatus(running: true, revision: revision, connection: vpn.connection) }
        catch { throw BridgeFailure(method: "start", stage: "waitForConnection", category: "vpn", cause: error as NSError) }
        if let session = activeSession {
            for data in Array(subscriptions.values) {
                _ = try? await send(data, session: session, storage: storage, timeout: 2)
            }
        }
    }

    private func stop() async throws {
        intent += 1
        let revision = intent
        if manager == nil { manager = try await existingManager(method: "stop") }
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
