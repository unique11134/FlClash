import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/core/ios.dart';
import 'package:fl_clash/core/method.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flclash.test/ios');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late CoreIOS core;

  setUp(() => core = CoreIOS(channel: channel));
  tearDown(() async {
    await core.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('calls the existing Core wire protocol with a correlated ID', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'invoke');
      final bytes = call.arguments as Uint8List;
      final request = jsonDecode(utf8.decode(bytes)) as Map;
      expect(request['method'], 'proxy.list');
      return Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'id': request['id'],
            'result': ['DIRECT'],
          }),
        ),
      );
    });
    expect(await core.invokeMethod(method: CoreMethod.proxyList), ['DIRECT']);
  });

  test('a system disconnect never completes a VPN start', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'start');
      return {'state': 'disconnected'};
    });
    await expectLater(core.startListener(), throwsStateError);
  });

  test('maps the timestamp from Network Extension', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'status');
      return {'state': 'reasserting', 'connectedAt': 1234};
    });
    final status = await core.getStatus();
    expect(status.running, isTrue);
    expect(status.connectedAt?.millisecondsSinceEpoch, 1234);
  });
}
