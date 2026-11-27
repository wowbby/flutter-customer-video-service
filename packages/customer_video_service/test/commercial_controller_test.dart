import 'dart:async';
import 'dart:convert';
import 'package:customer_video_service/customer_video_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'call_manager_test.dart' show FakeTransport, settings;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeTransport native;
  late VideoServiceController controller;
  setUp(() {
    native = FakeTransport();
    controller = VideoServiceController(
      transport: native,
      credentialsProvider: (_) async => settings,
    );
  });
  tearDown(() async {
    controller.dispose();
    await native.stream.close();
  });

  test('credentials and renewal receive the same immutable call context',
      () async {
    controller.dispose();
    CallContext? requested, renewed;
    controller = VideoServiceController(
      transport: native,
      credentialsProvider: (context) async {
        requested = context;
        return settings;
      },
      tokenProvider: (context, identity) async {
        renewed = context;
        return 'renewed-token';
      },
    );
    final result = await controller.startCall(
        request: const CallRequest(
            businessId: 'private-order', scene: 'private-scene'));
    await controller.refreshToken();
    expect(result.status, CallStartStatus.accepted);
    expect(requested!.sessionId, result.sessionId);
    expect(identical(requested, renewed), isTrue);
    expect(requested!.request.businessId, 'private-order');
    expect(
        jsonEncode(controller.state.toBridgeMap()), isNot(contains('private')));
    expect(jsonEncode(native.calls.map((e) => e.$2).toList()),
        isNot(contains('private-order')));
    await controller.hangup();
  });

  test(
      'cancelled credentials return the original session after another call starts',
      () async {
    controller.dispose();
    final pending = Completer<CallCredentials>();
    controller = VideoServiceController(
        transport: native,
        allowProbe: true,
        credentialsProvider: (_) => pending.future);
    final starting = controller.startCall();
    final original = controller.state.sessionId;
    await controller.hangup();
    await controller.startProbe();
    pending.complete(settings);
    final result = await starting;
    expect(result.sessionId, original);
    expect(result.status, CallStartStatus.cancelled);
    expect(controller.state.sessionId, isNot(original));
    expect(native.calls, isEmpty);
    await controller.hangup();
  });

  test(
      'media connection does not accept the business call and old signals are rejected',
      () async {
    final start = await controller.startCall();
    native.emit('joined', start.sessionId);
    native.emit('remoteVideo', start.sessionId, {'uid': 23});
    expect(controller.state.phase, CallPhase.connected);
    expect(controller.state.connectionState, RtcConnectionState.connected);
    expect(controller.state.businessState, CallBusinessState.requested);
    expect(
        () => controller.updateBusinessState(
            sessionId: 'old', state: CallBusinessState.accepted),
        throwsA(isA<CallException>()));
    controller.updateBusinessState(
        sessionId: start.sessionId, state: CallBusinessState.accepted);
    expect(controller.state.businessState, CallBusinessState.accepted);
    native.emit('connection', start.sessionId, {'state': 'reconnecting'});
    expect(controller.state.connectionState, RtcConnectionState.reconnecting);
    expect(controller.state.businessState, CallBusinessState.accepted);
    await expectLater(
        controller.endCall(sessionId: 'old', reason: CallEndReason.remote),
        throwsA(isA<CallException>()));
    await controller.endCall(
        sessionId: start.sessionId, reason: CallEndReason.remote);
    expect(controller.state.lastSummary!.reason, CallEndReason.remote);
    expect(controller.state.lastSummary!.acceptedAt, isNotNull);
    expect(controller.state.lastSummary!.duration, isNotNull);
  });

  test(
      'business transitions are monotonic and duplicate acceptance preserves time',
      () async {
    final start = await controller.startCall();
    controller.updateBusinessState(
        sessionId: start.sessionId, state: CallBusinessState.ringing);
    controller.updateBusinessState(
        sessionId: start.sessionId, state: CallBusinessState.accepted);
    controller.updateBusinessState(
        sessionId: start.sessionId, state: CallBusinessState.accepted);
    expect(
        () => controller.updateBusinessState(
            sessionId: start.sessionId, state: CallBusinessState.ringing),
        throwsA(isA<CallException>()));
    await controller.hangup();
    expect(controller.state.lastSummary!.duration!.isNegative, isFalse);
  });

  test('confirmed warning release emits one summary and permits redial',
      () async {
    native.handler = (method, _) async =>
        method == 'leave' ? {'releaseStatus': 'releasedWithWarnings'} : null;
    final summaries = <CallSummary>[];
    final subscription = controller.ended.listen(summaries.add);
    final start = await controller.startCall();
    await Future.wait([controller.hangup(), controller.hangup()]);
    await Future<void>.delayed(Duration.zero);
    expect(summaries, hasLength(1));
    expect(summaries.single.context.sessionId, start.sessionId);
    expect(summaries.single.duration, isNull);
    expect(summaries.single.releaseStatus, ReleaseStatus.releasedWithWarnings);
    final next = await controller.startCall();
    expect(next.sessionId, isNot(start.sessionId));
    expect(controller.state.lastSummary, same(summaries.single));
    await controller.hangup();
    await subscription.cancel();
  });

  test(
      'unconfirmed release retains ownership and emits only after successful retry',
      () async {
    final summaries = <CallSummary>[];
    final subscription = controller.ended.listen(summaries.add);
    await controller.startCall();
    native.handler = (method, _) async =>
        method == 'leave' ? {'releaseStatus': 'unknown'} : null;
    await expectLater(controller.hangup(), throwsA(isA<CallException>()));
    await Future<void>.delayed(Duration.zero);
    expect(summaries, isEmpty);
    expect(controller.state.phase, CallPhase.ending);
    expect(controller.state.error!.operation, CallOperation.leave);
    native.handler = null;
    await controller.hangup();
    await Future<void>.delayed(Duration.zero);
    expect(summaries, hasLength(1));
    expect(summaries.single.error, isNull);
    await subscription.cancel();
  });

  test('SDK operation failures are normalized without ending a healthy call',
      () async {
    await controller.startCall();
    native.handler = (method, _) async {
      if (method == 'setMuted') {
        throw PlatformException(code: 'sdk_-7', message: 'private-token');
      }
      return null;
    };
    await expectLater(
        controller.setMuted(true),
        throwsA(isA<CallException>()
            .having((e) => e.code, 'code', CallErrorCode.sdkError)
            .having((e) => e.operation, 'operation', CallOperation.setMuted)
            .having((e) => e.vendorCode, 'vendorCode', -7)
            .having(
                (e) => e.recovery, 'recovery', CallRecovery.retryOperation)));
    expect(controller.state.hasWindow, isTrue);
    expect(controller.state.media.muted, isFalse);
    expect(
        jsonEncode(controller.state.toBridgeMap()), isNot(contains('private')));
    native.handler = null;
    await controller.hangup();
  });

  test('listener redial cannot relabel the previous ended summary', () async {
    final summaries = <CallSummary>[];
    final subscription = controller.ended.listen(summaries.add);
    final first = await controller.startCall();
    Future<CallStartResult>? next;
    controller.addListener(() {
      if (next == null && controller.state.phase == CallPhase.idle) {
        // Set a sentinel before the synchronous start notification.
        next = Future.value(const CallStartResult(
            sessionId: 'sentinel', status: CallStartStatus.cancelled));
        next = controller.startCall();
      }
    });
    await controller.hangup();
    final second = await next!;
    await Future<void>.delayed(Duration.zero);
    expect(summaries.single.context.sessionId, first.sessionId);
    expect(controller.state.sessionId, second.sessionId);
    await controller.hangup();
    await subscription.cancel();
  });

  test(
      'synchronous cancellation during start notification does not fetch credentials',
      () async {
    controller.dispose();
    var requests = 0;
    controller = VideoServiceController(
        transport: native,
        credentialsProvider: (_) async {
          requests++;
          return settings;
        });
    controller.addListener(() {
      if (controller.state.phase == CallPhase.joining) {
        unawaited(controller.hangup());
      }
    });
    final result = await controller.startCall();
    expect(result.status, CallStartStatus.cancelled);
    expect(requests, 0);
    expect(native.calls, isEmpty);
  });

  test('session-scoped ending can retry cleanup without touching the next call',
      () async {
    final start = await controller.startCall();
    native.handler = (method, _) async =>
        method == 'leave' ? {'releaseStatus': 'unknown'} : null;
    await expectLater(
        controller.endCall(
            sessionId: start.sessionId, reason: CallEndReason.remote),
        throwsA(isA<CallException>()
            .having((e) => e.code, 'code', CallErrorCode.cleanupFailed)));
    native.handler = null;
    await controller.endCall(
        sessionId: start.sessionId, reason: CallEndReason.remote);
    expect(controller.state.lastSummary!.reason, CallEndReason.remote);
    final next = await controller.startCall();
    await expectLater(
        controller.endCall(
            sessionId: start.sessionId, reason: CallEndReason.remote),
        throwsA(isA<CallException>()));
    expect(controller.state.sessionId, next.sessionId);
    await controller.hangup();
  });

  test('native join cancellation keeps the original session result', () async {
    final pending = Completer<Object?>();
    native.handler =
        (method, _) => method == 'join' ? pending.future : Future.value(null);
    final starting = controller.startCall();
    await Future<void>.delayed(Duration.zero);
    final original = controller.state.sessionId;
    await controller.hangup();
    pending.complete(null);
    final result = await starting;
    expect(result.status, CallStartStatus.cancelled);
    expect(result.sessionId, original);
  });

  test('structured native event errors retain numeric SDK cause in the summary',
      () async {
    final start = await controller.startCall();
    native.emit('error', start.sessionId, {
      'code': 'sdkError',
      'message': 'private-error',
      'details': {
        'sdkCode': 109,
        'operation': 'private-operation',
        'recovery': 'retryCall'
      },
    });
    await Future<void>.delayed(Duration.zero);
    final error = controller.state.lastSummary!.error!;
    expect(error.vendorCode, 109);
    expect(error.operation, CallOperation.event);
    expect(error.recovery, CallRecovery.retryCall);
    expect(
        jsonEncode(controller.state.toBridgeMap()), isNot(contains('private')));
  });

  test('token refresh failure reports the same structured recovery as state',
      () async {
    controller.dispose();
    controller = VideoServiceController(
        transport: native,
        credentialsProvider: (_) async => settings,
        tokenProvider: (_, __) async =>
            throw StateError('private-server-error'));
    await controller.startCall();
    await expectLater(
        controller.refreshToken(),
        throwsA(isA<CallException>()
            .having((e) => e.operation, 'operation', CallOperation.renewToken)
            .having(
                (e) => e.recovery, 'recovery', CallRecovery.retryOperation)));
    await controller.hangup();
  });

  test(
      'start failure survives listener redial and summary keeps original cause',
      () async {
    final pending = Completer<Object?>();
    native.handler =
        (method, _) => method == 'join' ? pending.future : Future.value(null);
    final starting = controller.startCall();
    final failure = expectLater(
        starting,
        throwsA(isA<CallException>()
            .having((e) => e.code, 'code', CallErrorCode.sdkError)));
    final original = controller.state.sessionId;
    var redialed = false;
    Future<CallStartResult>? redial;
    controller.addListener(() {
      if (!redialed && controller.state.phase == CallPhase.idle) {
        redialed = true;
        native.handler = null;
        redial = controller.startCall();
      }
    });
    await Future<void>.delayed(Duration.zero);
    pending.completeError(PlatformException(code: 'sdk_-7'));
    await failure;
    await redial!;
    expect(controller.state.sessionId, isNot(original));
    expect(controller.state.error, isNull);
    expect(controller.state.lastSummary!.context.sessionId, original);
    expect(controller.state.lastSummary!.error!.code, CallErrorCode.sdkError);
    await controller.hangup();
  });
}
