# FlClash on iOS

The build uses the iOS 27.2 SDK in Xcode 27.2. Runner and PacketTunnel set an iOS 16.0 deployment target. Test on iOS 27 before treating another OS version as supported.

## Build

On an Apple Silicon Mac with Xcode, CocoaPods, Flutter 3.47.6, Go 1.27.1 and Rust 1.99.0, run these commands from the repository root.

```bash
git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init --recursive
rustup target add --toolchain 1.99.0 aarch64-apple-ios aarch64-apple-ios-sim
flutter config --no-enable-swift-package-manager
flutter pub get
bash tool/build_ios_core.sh
flutter build ios --config-only --no-codesign
pod install --project-directory=ios
flutter build ios --release --no-codesign
```

The iOS workflow uploads `FlClash-iOS-arm64-unsigned.tar.gz` after both Swift targets compile and the archive is verified. The unsigned `.app` is for build inspection. Install a signed build on an iPhone for VPN testing.

## Install on an iPhone

1. In the Apple Developer account register an App ID and its `.PacketTunnel` extension ID. Enable Network Extensions with the Packet Tunnel Provider capability on both. Register the shared App Group and include it in both provisioning profiles.
2. Open `ios/Runner.xcworkspace` in Xcode. Set `FLCLASH_APP_ID` and `FLCLASH_APP_GROUP` consistently for both targets and select the same development team. Verify that the signed Runner embeds `PlugIns/PacketTunnel.appex`.
3. Select a paired iPhone running iOS 27 and run the Runner scheme. Import a Clash subscription, select a node and authorize the system VPN. In Xcode use Product → Archive and Distribute App when an exportable signed IPA is needed.
4. Confirm actual TCP, UDP, DNS and IPv6 traffic against endpoints with a known expected path. Repeat after lock screen and transitions between Wi‑Fi and cellular. Inspect the extension logs and memory in Xcode during these tests.
