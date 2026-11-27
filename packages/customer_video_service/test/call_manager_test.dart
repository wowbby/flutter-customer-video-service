import 'dart:async';
import 'package:customer_video_service/customer_video_service.dart';
import 'package:customer_rtc/customer_rtc.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:customer_video_service/src/call/call_manager.dart';

class FakeTransport implements RtcTransport {
  final stream = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final calls = <(String, Map<String, Object?>)>[];
  Future<Object?> Function(String, Map<String, Object?>)? handler;
  @override
  Stream<Map<String, dynamic>> get events => stream.stream;
  @override
  Future<Object?> invoke(String method, Map<String, Object?> arguments) async {
    calls.add((method, arguments));
    return await handler?.call(method, arguments);
  }

  void emit(String type, String? session,
          [Map<String, dynamic> values = const {}]) =>
      stream.add({'type': type, 'sessionId': session, ...values});
}

const settings = CallCredentials(
    appId: '0123456789abcdef0123456789abcdef',
    channel: 'probe',
    token: 'private-token',
    uid: 42);

void main() {
  late FakeTransport native;
  late CallManager manager;
  setUp(() {
    native = FakeTransport();
    manager = CallManager(native);
  });
  tearDown(() async {
    manager.dispose();
    await native.stream.close();
  });

  test(
      'join diagnostics expose numeric SDK failure without native private data',
      () async {
    native.handler = (method, _) async {
      if (method == 'join') {
        throw PlatformException(
            code: 'rtc_join_failed',
            message: 'private-token',
            details: {
              'sdkCode': -7,
              'stage': 'private-token',
              'exceptionType': settings.appId,
            });
      }
      return null;
    };
    await expectLater(manager.start(probe: false, settings: settings),
        throwsA(isA<CallException>()));
    expect(manager.diagnostic, 'RTC join code=-7');
    expect('${manager.diagnostic} ${manager.failure}',
        isNot(contains('private-token')));
    expect('${manager.diagnostic} ${manager.failure}',
        isNot(contains(settings.appId)));
    expect(manager.phase, CallPhase.idle);
  });

  test('probe creates a window without requesting media or claiming connected',
      () async {
    await manager.start(probe: true);
    expect(manager.hasWindow, isTrue);
    expect(manager.phase, CallPhase.probe);
    expect(native.calls, isEmpty);
    manager.minimize();
    expect(manager.isMini, isTrue);
    manager.restore();
    expect(manager.isMini, isFalse);
    await manager.hangup();
    expect(manager.hasWindow, isFalse);
    expect(native.calls, isEmpty);
  });

  test('duplicate start is rejected while native join is pending', () async {
    final pending = Completer<void>();
    native.handler = (method, _) async {
      if (method == 'join') await pending.future;
      return null;
    };
    final first = manager.start(probe: false, settings: settings);
    expect(manager.phase, CallPhase.joining);
    await expectLater(manager.start(probe: false, settings: settings),
        throwsA(isA<StateError>()));
    expect(native.calls.where((c) => c.$1 == 'join').length, 1);
    pending.complete();
    await first;
  });

  test(
      'peer presence does not claim rendered video and view switches never rejoin',
      () async {
    await manager.start(probe: false, settings: settings);
    final session = manager.sessionId;
    native.emit('joined', session, {'uid': 42});
    expect(manager.phase, CallPhase.waiting);
    native.emit('remoteJoined', session, {'uid': 23});
    expect(manager.phase, CallPhase.connecting);
    native.emit('remoteVideo', session, {'uid': 23});
    expect(manager.phase, CallPhase.connected);
    manager.minimize();
    manager.restore();
    manager.minimize();
    expect(native.calls.where((c) => c.$1 == 'join').length, 1);
    expect(manager.sessionId, session);
    expect('${manager.diagnostic} ${manager.failure}',
        isNot(contains('private-token')));
    expect('${manager.diagnostic} ${manager.failure}',
        isNot(contains(settings.appId)));
  });

  test(
      'cancel during permission/join ignores old callbacks and late join completion',
      () async {
    final pending = Completer<void>();
    native.handler = (method, _) async {
      if (method == 'join') await pending.future;
      return null;
    };
    final starting = manager.start(probe: false, settings: settings);
    final old = manager.sessionId;
    await manager.hangup();
    expect(manager.hasWindow, isFalse);
    await manager.start(probe: true);
    native.emit('remoteVideo', old, {'uid': 23});
    pending.complete();
    await starting;
    expect(manager.phase, CallPhase.probe);
    expect(manager.sessionId, isNot(old));
    expect(
        native.calls.where((c) => c.$1 == 'leave').single.$2['sessionId'], old);
  });

  test(
      'rendered statistics recover a rejoined peer without another first frame',
      () async {
    await manager.start(probe: false, settings: settings);
    final session = manager.sessionId;
    native.emit('joined', session, {'uid': 42});
    native.emit('remoteJoined', session, {'uid': 23});
    native.emit('remoteVideo', session, {'uid': 23});
    native.emit('remoteLeft', session, {'uid': 23});
    native.emit('remoteJoined', session, {'uid': 23});
    expect(manager.remoteVideo, isFalse);
    for (final sample in [
      {'uid': 24, 'rendererOutputFrameRate': 15},
      {'uid': 23, 'rendererOutputFrameRate': 0},
      {'uid': 23, 'rendererOutputFrameRate': '15'},
    ]) {
      native.emit('remoteVideoStats', session, sample);
      expect(manager.phase, CallPhase.connecting);
    }
    native.emit('remoteVideoStats', 'old-session',
        {'uid': 23, 'rendererOutputFrameRate': 15});
    expect(manager.remoteVideo, isFalse);
    native.emit(
        'remoteVideoStats', session, {'uid': 23, 'rendererOutputFrameRate': 3});
    expect(manager.phase, CallPhase.connected);
    expect(manager.remoteVideo, isTrue);
    expect(manager.sessionId, session);
    var notifications = 0;
    manager.addListener(() => notifications++);
    native.emit('remoteVideoStats', session,
        {'uid': 23, 'rendererOutputFrameRate': 15});
    expect(notifications, 0);
    native.emit('connection', session, {'state': 'reconnecting'});
    native.emit('remoteVideoStats', session,
        {'uid': 23, 'rendererOutputFrameRate': 15});
    expect(manager.phase, CallPhase.reconnecting);
    await manager.hangup();
    native.emit('remoteVideoStats', session,
        {'uid': 23, 'rendererOutputFrameRate': 15});
    expect(manager.phase, CallPhase.idle);
  });

  test(
      'failed cleanup keeps window and prevents a new call until retry succeeds',
      () async {
    await manager.start(probe: false, settings: settings);
    native.handler = (method, _) async {
      if (method == 'leave') throw PlatformException(code: 'releaseFailed');
      return null;
    };
    await manager.hangup();
    expect(manager.phase, CallPhase.ending);
    expect(manager.errorCode, 'cleanupFailed');
    await expectLater(manager.start(probe: true), throwsA(isA<StateError>()));
    native.handler = null;
    await manager.hangup();
    expect(manager.phase, CallPhase.idle);
  });

  test('failed media command does not change muted state', () async {
    await manager.start(probe: false, settings: settings);
    native.handler = (method, _) async {
      if (method == 'setMuted') {
        throw PlatformException(code: 'sdkError', message: 'private-token');
      }
      return null;
    };
    await expectLater(manager.setMuted(true), throwsA(isA<CallException>()));
    expect(manager.muted, isFalse);
    expect('${manager.diagnostic} ${manager.failure}',
        isNot(contains('private-token')));
  });

  test('missing credentials rejected before opening window or invoking native',
      () async {
    await expectLater(
        manager.start(probe: false), throwsA(isA<ArgumentError>()));
    expect(native.calls, isEmpty);
    expect(manager.hasWindow, isFalse);
  });

  test('native join failure cleans native resources and reports sanitized code',
      () async {
    native.handler = (method, _) async {
      if (method == 'join') {
        throw PlatformException(
            code: 'permissionDenied', message: 'private-token');
      }
      return null;
    };
    await expectLater(manager.start(probe: false, settings: settings),
        throwsA(isA<CallException>()));
    expect(manager.hasWindow, isFalse);
    expect(manager.errorCode, 'permissionDenied');
    expect(native.calls.last.$1, 'leave');
    expect('${manager.diagnostic} ${manager.failure}',
        isNot(contains('private-token')));
  });

  test('only selected peer can advance or end media state', () async {
    await manager.start(probe: false, settings: settings);
    final session = manager.sessionId;
    native.emit('joined', session);
    native.emit('remoteJoined', session, {'uid': 23});
    native.emit('remoteJoined', session, {'uid': 24});
    native.emit('remoteVideo', session, {'uid': 24});
    expect(manager.phase, CallPhase.connecting);
    native.emit('remoteVideo', session, {'uid': 23});
    native.emit('remoteLeft', session, {'uid': 24});
    expect(manager.phase, CallPhase.connected);
    native.emit('tokenRequired', session);
    expect(manager.needsToken, isTrue);
  });

  test('native platform error names become safe shared codes', () {
    for (final entry in {
      'permission_denied': 'permissionDenied',
      'no_activity': 'missingActivity',
      'missing_activity': 'missingActivity',
      'invalid_arguments': 'invalidArgument',
      'rtc_join_failed': 'sdkError',
      'cleanup_failed': 'cleanupFailed',
    }.entries) {
      expect(safeErrorCode(PlatformException(code: entry.key)), entry.value);
    }
    expect(
        safeErrorCode(PlatformException(code: 'private-token')), 'nativeError');
  });
}
