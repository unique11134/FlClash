import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/core.dart' show CoreEvent;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show MethodChannel, PlatformException;

import 'desktop/model.dart';
import 'event.dart';
import 'interface.dart';
import 'method.dart';
import 'spill.dart';

final iosCore = CoreIOS();

class IOSVpnStatus {
  const IOSVpnStatus(this.state, this.connectedAt);

  factory IOSVpnStatus.fromMap(Map<Object?, Object?> value) {
    final time = value['connectedAt'];
    return IOSVpnStatus(
      value['state'] as String,
      time is int ? DateTime.fromMillisecondsSinceEpoch(time) : null,
    );
  }

  final String state;
  final DateTime? connectedAt;

  bool get running => state == 'connected' || state == 'reasserting';
}

class CoreIOS extends CoreHandlerInterface {
  CoreIOS({
    MethodChannel channel = const MethodChannel('com.follow.clash/ios-vpn'),
  }) : _channel = channel;

  final MethodChannel _channel;
  final _statuses = StreamController<IOSVpnStatus>.broadcast();
  Timer? _eventTimer;
  bool _readingEvents = false;
  bool _closed = false;
  int _revision = 0;
  int _requestId = 0;
  Future<CoreLifecycleResult>? _closeOperation;

  Stream<IOSVpnStatus> get statuses => _statuses.stream;

  Future<String> get homePath async {
    final path = await _channel.invokeMethod<String>('coreHome');
    if (path == null || path.isEmpty) {
      throw StateError('iOS Core data directory is unavailable');
    }
    return path;
  }

  Future<IOSVpnStatus> getStatus() => _statusCall('status');

  @override
  Future<CoreLifecycleResult> start() async {
    if (_closed) throw StateError('iOS Core lifecycle is closed');
    if (_eventTimer != null) return _lifecycle(CoreLifecycleOutcome.coalesced);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'statusChanged' && !_closed) {
        _statuses.add(IOSVpnStatus.fromMap(call.arguments as Map));
      }
    });
    final status = await getStatus();
    if (_closed) throw StateError('iOS Core lifecycle is closed');
    _statuses.add(status);
    _eventTimer ??= Timer.periodic(const Duration(milliseconds: 350), (_) {
      unawaited(_readEvents());
    });
    return _lifecycle();
  }

  @override
  Future<CoreLifecycleResult> stop() async {
    if (_closed) throw StateError('iOS Core lifecycle is closed');
    await stopListener();
    return _lifecycle();
  }

  @override
  Future<CoreLifecycleResult> restart() async {
    final wasRunning = (await getStatus()).running;
    await stop();
    if (wasRunning) await startListener();
    return start();
  }

  @override
  Future<CoreLifecycleResult> close() => _closeOperation ??= _close();

  Future<CoreLifecycleResult> _close() async {
    _closed = true;
    _eventTimer?.cancel();
    _eventTimer = null;
    _channel.setMethodCallHandler(null);
    await _statuses.close();
    return _lifecycle();
  }

  CoreLifecycleResult _lifecycle([
    CoreLifecycleOutcome outcome = CoreLifecycleOutcome.applied,
  ]) => CoreLifecycleResult(revision: ++_revision, outcome: outcome);

  @override
  Future<void> startListener() async {
    if (_closed) throw StateError('iOS Core lifecycle is closed');
    final status = await _statusCall('start');
    if (!status.running) throw StateError('iOS VPN did not connect');
    if (!_closed) _statuses.add(status);
  }

  @override
  Future<void> stopListener() async {
    if (_closed) throw StateError('iOS Core lifecycle is closed');
    final status = await _statusCall('stop');
    if (!_closed) _statuses.add(status);
  }

  Future<IOSVpnStatus> _statusCall(String method) async {
    try {
      final value = await _channel
          .invokeMapMethod<Object?, Object?>(method)
          .timeout(const Duration(seconds: 45));
      if (value == null) throw StateError('iOS VPN returned no status');
      return IOSVpnStatus.fromMap(value);
    } on PlatformException catch (error) {
      throw CoreMethodException(
        code: error.code,
        message: error.message ?? 'iOS VPN request failed',
      );
    }
  }

  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    if (_closed) throw StateError('iOS Core lifecycle is closed');
    final call = CoreMethodCall(
      id: '${++_requestId}',
      method: method,
      arguments: arguments,
    );
    final response = _invoke(call);
    final result = await response.withTimeout(
      timeout: timeout,
      onTimeout: () {
        unawaited(response.then(discardSpilledResponse, onError: (_) {}));
        throw TimeoutException('iOS Core method ${method.wireName} timed out');
      },
    );
    return (await resolveSpilledResponse(
      result,
      method: method,
    )).unwrap<Object?>();
  }

  Future<CoreMethodResponse> _invoke(CoreMethodCall call) async {
    final request = Uint8List.fromList(utf8.encode(jsonEncode(call.toJson())));
    final Uint8List? data;
    try {
      data = await _channel.invokeMethod<Uint8List>('invoke', request);
    } on PlatformException catch (error) {
      throw CoreMethodException(
        code: error.code,
        message: error.message ?? 'iOS Core request failed',
      );
    }
    if (data == null) {
      throw const CoreMethodException(
        code: 'no_response',
        message: 'iOS Core returned no response',
      );
    }
    final response = CoreMethodResponse.fromJson(
      await compute(_decodeResponse, (data, call.method)),
    );
    if (response.id != call.id) {
      throw const CoreMethodException(
        code: 'invalid_response',
        message: 'iOS Core response ID did not match the request',
      );
    }
    return response;
  }

  Future<void> _readEvents() async {
    if (_readingEvents || _closed) return;
    _readingEvents = true;
    try {
      final data = await _channel.invokeMethod<Uint8List>('events');
      if (data == null || _closed) return;
      final events = await compute(_decodeEvents, data);
      if (_closed) return;
      for (final event in events) {
        coreEventManager.sendEvent(event);
      }
    } on PlatformException {
      // A poll can cross a system-driven disconnect; the status callback owns it.
    } finally {
      _readingEvents = false;
    }
  }
}

Map<String, Object?> _decodeResponse((Uint8List, CoreMethod) request) {
  final (data, method) = request;
  final map = Map<String, Object?>.from(jsonDecode(utf8.decode(data)) as Map);
  return withResultModel(method, map);
}

List<CoreEvent> _decodeEvents(Uint8List data) => [
  for (final String batch in jsonDecode(utf8.decode(data)) as List)
    ...coreEventsFromData((jsonDecode(batch) as Map)['arguments']),
];
