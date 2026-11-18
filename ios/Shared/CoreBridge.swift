import Darwin
import Foundation

struct TunnelError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CoreRequest {
    let method: String
    let arguments: [String: Any]
    let original: Data?

    init(method: String, arguments: [String: Any] = [:]) {
        self.method = method
        self.arguments = arguments
        self.original = nil
    }

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            throw TunnelError(message: "Invalid Core request")
        }
        self.method = method
        arguments = object["arguments"] as? [String: Any] ?? [:]
        original = data
    }

    func encoded() throws -> Data {
        if let original { return original }
        return try JSONSerialization.data(withJSONObject: ["method": method, "arguments": arguments])
    }
}

enum CoreBridge {
    static func invoke(_ request: Data) throws -> Data {
        guard let json = String(data: request, encoding: .utf8),
              let result = json.withCString({ flclash_core_invoke($0) }) else {
            throw TunnelError(message: "Core returned no response")
        }
        defer { free(result) }
        return Data(bytes: result, count: strlen(result))
    }

    static func run(_ request: CoreRequest) throws {
        let data = try invoke(request.encoded())
        if let error = try response(data)["error"] as? [String: Any] {
            throw TunnelError(message: error["message"] as? String ?? "Core rejected \(request.method)")
        }
    }

    static func response(_ data: Data) throws -> [String: Any] {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TunnelError(message: "Invalid Core response")
        }
        return response
    }

    static func events() throws -> Data {
        var batches: [String] = []
        for _ in 0..<8 {
            guard let batch = flclash_core_event() else { break }
            batches.append(String(cString: batch))
            free(batch)
        }
        return try JSONSerialization.data(withJSONObject: batches)
    }
}

struct CoreStorage {
    let root: URL
    let app: URL
    let tunnel: URL
    let rpc: URL

    init() throws {
        let manager = FileManager.default
        let group = Bundle.main.object(forInfoDictionaryKey: "FlClashAppGroup") as? String ?? ""
        let container = manager.containerURL(forSecurityApplicationGroupIdentifier: group)
        #if targetEnvironment(simulator)
        let location = try container ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        #else
        guard let location = container else {
            throw TunnelError(message: "FlClash App Group is unavailable. Check the signing profile.")
        }
        #endif
        root = location.appendingPathComponent("FlClashCore", isDirectory: true)
        app = root.appendingPathComponent("App", isDirectory: true)
        tunnel = root.appendingPathComponent("Tunnel", isDirectory: true)
        rpc = root.appendingPathComponent("RPC", isDirectory: true)
        for directory in [app, tunnel, rpc] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
    }

    var snapshot: URL { root.appendingPathComponent("state.json") }

    func rpcFile(_ id: UUID, response: Bool = false) -> URL {
        rpc.appendingPathComponent(id.uuidString + (response ? ".response" : ".request"))
    }

    func write(_ data: Data, to target: URL) throws {
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func copyBaseConfigIfNeeded(_ request: CoreRequest) throws {
        if request.arguments["base"] is [String: Any] { return }
        let name = "config.yaml"
        let data = try Data(contentsOf: app.appendingPathComponent(name))
        try write(data, to: tunnel.appendingPathComponent(name))
    }

    func prepareGeoData() throws {
        let manager = FileManager.default
        for name in ["GEOIP.metadb", "GEOIP.dat", "GEOSITE.dat", "ASN.mmdb"] {
            let source = app.appendingPathComponent(name)
            let target = tunnel.appendingPathComponent(name)
            if manager.fileExists(atPath: source.path), !manager.fileExists(atPath: target.path) {
                try manager.copyItem(at: source, to: target)
            }
        }
    }
}

struct CoreSnapshot {
    let version: Int
    var setup: [String: Any]
    var update: [String: Any]
    let configuration: String

    init(storage: CoreStorage) throws {
        let data = try Data(contentsOf: storage.snapshot)
        let values = try CoreBridge.response(data)
        guard let version = values["version"] as? Int,
              let setup = values["setup"] as? [String: Any],
              let configuration = values["configuration"] as? String else {
            throw TunnelError(message: "Saved Core configuration is incomplete")
        }
        self.version = version
        self.setup = setup
        update = values["update"] as? [String: Any] ?? [:]
        self.configuration = configuration
    }

    init(version: Int, setup: [String: Any], configuration: String) {
        self.version = version
        self.setup = setup
        self.setup.removeValue(forKey: "base")
        update = [:]
        self.configuration = configuration
    }

    func save(storage: CoreStorage) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": version, "setup": setup, "update": update, "configuration": configuration,
        ])
        try storage.write(data, to: storage.snapshot)
    }

    func restore(storage: CoreStorage, forTunnel: Bool) throws {
        let home = forTunnel ? storage.tunnel : storage.app
        try CoreBridge.run(CoreRequest(method: "core.init", arguments: ["version": version, "home-dir": home.path]))
        let config = CoreRequest(method: "config.setup", arguments: setup)
        if forTunnel { try storage.prepareGeoData() }
        try storage.write(Data(configuration.utf8), to: home.appendingPathComponent("config.yaml"))
        try CoreBridge.run(config)
        if !update.isEmpty {
            try CoreBridge.run(CoreRequest(method: "config.update", arguments: update))
        }
    }
}
