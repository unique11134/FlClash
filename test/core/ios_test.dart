import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/core/ios.dart';
import 'package:fl_clash/core/method.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
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

  const denied = {
    'method': 'status',
    'stage': 'NETunnelProviderManager.loadAllFromPreferences',
    'permissionDenied': true,
    'error': {
      'domain': 'NEConfigurationErrorDomain',
      'code': 10,
      'message': 'permission denied',
    },
  };

  test('unavailable VPN status preserves offline Core startup', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'status' => {'state': 'unavailable', 'permissionDenied': true},
        'coreHome' => '/app-private/FlClashCore/App',
        _ => throw StateError('Unexpected ${call.method}'),
      };
    });
    final notification = core.statuses.first;
    await core.start();
    final status = await notification;
    expect(status.unavailable, isTrue);
    expect(status.permissionDenied, isTrue);
    expect(status.running, isFalse);
    expect(await core.homePath, '/app-private/FlClashCore/App');
    expect(calls, ['status', 'coreHome']);
  });

  test(
    'failed preferences query is diagnosable and never starts VPN',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') {
          throw PlatformException(
            code: 'ios_vpn',
            message: 'permission denied',
            details: denied,
          );
        }
        expect(call.method, 'diagnostics');
        return {
          'embeddedProviderIdentifier': 'test.app.PacketTunnel',
          'errors': [denied],
        };
      });
      core.recordInitFailure(
        'initGeo',
        const FileSystemException(
          'write failed',
          '/app',
          OSError('permission denied', 13),
        ),
      );
      final report = jsonDecode(await core.diagnosticReport()) as Map;
      expect(report['state'], 'unavailable');
      expect(report['permissionDenied'], isTrue);
      expect((report['native'] as Map)['errors'], [denied]);
      final init = (report['flutter'] as Map)['core.init/initGeo'] as Map;
      expect(init['underlying'], {
        'domain': 'OSError',
        'code': 13,
        'message': 'permission denied',
      });
    },
  );

  test('explicit VPN start retains the system error and fails', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'start');
      throw PlatformException(
        code: 'ios_vpn',
        message: 'permission denied',
        details: denied,
      );
    });
    await expectLater(
      core.startListener(),
      throwsA(
        isA<CoreMethodException>().having(
          (error) => error.details,
          'details',
          denied,
        ),
      ),
    );
    expect(core.lastStatus?.running, isNot(true));
  });

  test(
    'storage and core.init channel failures retain independent stages',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        final stage = call.method == 'coreHome'
            ? 'CoreStorage.private.createDirectory.App'
            : 'CoreBridge.invoke';
        throw PlatformException(
          code: 'ios_storage',
          message: 'denied',
          details: {'stage': stage},
        );
      });
      await expectLater(
        core.homePath,
        throwsA(
          isA<CoreMethodException>().having(
            (error) => error.details,
            'details',
            {'stage': 'CoreStorage.private.createDirectory.App'},
          ),
        ),
      );
      await expectLater(
        core.invokeMethod(method: CoreMethod.coreInit),
        throwsA(
          isA<CoreMethodException>().having(
            (error) => error.details,
            'details',
            {'stage': 'CoreBridge.invoke'},
          ),
        ),
      );
    },
  );
}
