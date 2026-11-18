import XCTest

final class RunnerTests: XCTestCase {
    func testTunnelIsEmbedded() {
        let plugins = Bundle.main.builtInPlugInsURL
        XCTAssertNotNil(plugins.flatMap { Bundle(url: $0.appendingPathComponent("PacketTunnel.appex")) })
    }
}
