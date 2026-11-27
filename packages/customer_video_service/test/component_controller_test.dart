import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:customer_video_service/customer_video_service.dart';
import 'call_manager_test.dart' show FakeTransport;

const credentials = CallCredentials(
    appId: '0123456789abcdef0123456789abcdef',
    channel: 'room',
    uid: 7,
    token: 'private-token');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeTransport native;
  late VideoServiceController controller;
  setUp(() {
    native = FakeTransport();
  });
  tearDown(() async {
    controller.dispose();
    await native.stream.close();
  });
  test('cancel while credentials pending prevents a late native join',
      () async {
    final pending = Completer<CallCredentials>();
    controller = VideoServiceController(
        transport: native, credentialsProvider: (_) => pending.future);
    final start = controller.startCall();
    expect(controller.state.sessionId, isNotNull);
    await expectLater(controller.startCall(), throwsA(isA<CallException>()));
    await controller.hangup();
    pending.complete(credentials);
    await start;
    expect(native.calls, isEmpty);
    expect(controller.state.endReason, CallEndReason.user);
  });
  testWidgets('SDK acceptance without joined callback times out and releases',
      (tester) async {
    controller = VideoServiceController(
        transport: native,
        credentialsProvider: (_) async => credentials,
        joinTimeout: const Duration(seconds: 2));
    final started = controller.startCall();
    await tester.pump();
    await started;
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(controller.state.phase, CallPhase.idle);
    expect(controller.state.error?.code, CallErrorCode.joinTimeout);
    expect(controller.state.endReason, CallEndReason.joinFailed);
    expect(native.calls.where((c) => c.$1 == 'leave'), hasLength(1));
  });
  test('refresh is deduplicated and cannot renew a different session',
      () async {
    var count = 0;
    final token = Completer<String>();
    controller = VideoServiceController(
        transport: native,
        credentialsProvider: (_) async => credentials,
        tokenProvider: (_, identity) {
          count++;
          return token.future;
        });
    await controller.startCall();
    final first = controller.refreshToken();
    final second = controller.refreshToken();
    expect(count, 1);
    await controller.hangup();
    await controller.startCall();
    token.complete('private-new-token');
    await Future.wait([first, second]);
    expect(native.calls.where((c) => c.$1 == 'renewToken'), isEmpty);
    expect('${controller.state.error} ${controller.state.diagnostic}',
        isNot(contains('private')));
    await controller.hangup();
  });
  test('shutdown reports cleanup failure and blocks further starts until retry',
      () async {
    controller = VideoServiceController(
        transport: native, credentialsProvider: (_) async => credentials);
    await controller.startCall();
    native.handler = (method, _) async {
      if (method == 'leave') throw PlatformException(code: 'cleanup_failed');
      return null;
    };
    await expectLater(controller.shutdown(), throwsA(isA<CallException>()));
    expect(controller.state.phase, CallPhase.ending);
    await expectLater(controller.startCall(), throwsA(isA<CallException>()));
    native.handler = null;
    await controller.shutdown();
    expect(controller.state.phase, CallPhase.idle);
    expect(controller.state.endReason, CallEndReason.shutdown);
  });
  test('shutdown cancels pending credentials without entering native SDK',
      () async {
    final pending = Completer<CallCredentials>();
    controller = VideoServiceController(
        transport: native, credentialsProvider: (_) => pending.future);
    final start = controller.startCall();
    await controller.shutdown();
    pending.complete(credentials);
    await start;
    expect(native.calls, isEmpty);
    expect(controller.state.endReason, CallEndReason.shutdown);
  });
  test(
      'ending one session does not report a newly started session as cleanup failure',
      () async {
    controller = VideoServiceController(
        allowProbe: true,
        transport: native,
        credentialsProvider: (_) async => credentials);
    await controller.startProbe();
    final previous = controller.state.sessionId;
    var restarted = false;
    controller.addListener(() {
      if (!restarted && controller.state.phase == CallPhase.idle) {
        restarted = true;
        unawaited(controller.startProbe());
      }
    });
    await controller.hangup();
    expect(controller.state.sessionId, isNot(previous));
    expect(controller.state.phase, CallPhase.probe);
    await controller.shutdown();
  });
  testWidgets('joined callback cancels actual join deadline', (tester) async {
    controller = VideoServiceController(
        transport: native,
        credentialsProvider: (_) async => credentials,
        joinTimeout: const Duration(seconds: 1));
    final start = controller.startCall();
    await tester.pump();
    await start;
    native.emit('joined', controller.state.sessionId);
    await tester.pump(const Duration(seconds: 2));
    expect(controller.state.phase, CallPhase.waiting);
    expect(native.calls.where((c) => c.$1 == 'leave'), isEmpty);
    await controller.hangup();
  });
  test(
      'automatic token failure is safe, avoids retry loop and allows manual retry',
      () async {
    var attempts = 0;
    controller = VideoServiceController(
        transport: native,
        credentialsProvider: (_) async => credentials,
        tokenProvider: (_, __) async {
          if (++attempts == 1) throw Exception('private-server-details');
          return 'new-token';
        });
    await controller.startCall();
    native.emit('tokenRequired', controller.state.sessionId);
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 1);
    expect(controller.state.error?.code, CallErrorCode.tokenRefreshFailed);
    expect('${controller.state.error} ${controller.state.diagnostic}',
        isNot(contains('private')));
    native.emit('tokenRequired', controller.state.sessionId);
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 1);
    await controller.refreshToken();
    expect(attempts, 2);
    expect(controller.state.needsToken, false);
    expect(controller.state.error, isNull);
    expect(native.calls.where((c) => c.$1 == 'renewToken'), hasLength(1));
    await controller.hangup();
  });
  test('probe is disabled by default and background end reason is explicit',
      () async {
    controller = VideoServiceController(
        transport: native, credentialsProvider: (_) async => credentials);
    await expectLater(controller.startProbe(), throwsA(isA<CallException>()));
    await controller.startCall();
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.endReason, CallEndReason.background);
    expect(controller.state.phase, CallPhase.idle);
  });
}
