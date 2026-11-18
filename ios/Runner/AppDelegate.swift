import Flutter
import UIKit

@main
@objc final class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    private var vpnBridge: VpnBridge?

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FlClashVpn") {
            vpnBridge = VpnBridge(messenger: registrar.messenger())
        }
    }
}
