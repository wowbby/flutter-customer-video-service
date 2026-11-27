import 'dart:async';

import 'package:customer_video_service/customer_video_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'call_manager_test.dart' show FakeTransport, settings;
import 'system_call_test.dart' show PhoneTransport;
import 'package:customer_rtc/customer_rtc.dart' show SystemCallState;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeTransport native;
  late VideoServiceController controller;
  var credentialsRequested = 0;

  void configure({bool preview = false}) {
    native = FakeTransport();
    credentialsRequested = 0;
    controller = VideoServiceController(
      transport: native,
      lifecycleSource: CallLifecycleSource.nativeHost,
      mediaOnlyPreview: preview,
      mediaOptions: const CallMediaOptions(
          cameraFacing: CameraFacing.rear,
          videoQuality: VideoQuality.sd,
          primaryVideo: VideoRole.local),
      credentialsProvider: (_) async {
        credentialsRequested++;
        return settings;
      },
    );
  }

  tearDown(() async {
    native.handler = null;
    await controller.shutdown();
    controller.dispose();
    await native.stream.close();
  });

  Map<String, Object?> latestPresentation() =>
      native.calls.lastWhere((c) => c.$1 == 'updatePresentation').$2;
  final invalidSession = throwsA(isA<CallException>()
      .having((e) => e.code, 'code', CallErrorCode.invalidArgument));

  test(
      'waiting crosses native pages and releases only the resources acquired before background or a phone call',
      () async {
    final phone = PhoneTransport();
    native = phone;
    controller = VideoServiceController(
        transport: phone, lifecycleSource: CallLifecycleSource.nativeHost);
    final actions = <CallUserAction>[];
    controller.userActions.listen(actions.add);
    final first = await controller.beginWaiting();
    native.emit('presentationAction', first, {'action': 'minimize'});
    expect(latestPresentation()['awaitingAnswer'], true);
    expect(latestPresentation()['mode'], 'mini');
    native.emit('presentationAction', first, {'action': 'restore'});
    expect(latestPresentation()['mode'], 'full');
    native.emit('hostBackground', first);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.lastSummary?.reason, CallEndReason.background);
    expect(phone.stopped, [first]);
    expect(
        native.calls.where((c) => c.$1 == 'leave' || c.$1 == 'join'), isEmpty);

    final second = await controller.beginWaiting();
    phone.change(second, SystemCallState.ringing);
    phone.change(second, SystemCallState.idle);
    expect(controller.state.sessionId, second);
    phone.change(second, SystemCallState.active);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.lastSummary?.reason, CallEndReason.systemCall);
    expect(phone.stopped, [first, second]);
    expect(
        native.calls.where((c) => c.$1 == 'leave' || c.$1 == 'join'), isEmpty);
    phone.phone = SystemCallState.idle;

    final third = await controller.beginWaiting();
    await controller.admit(sessionId: third, credentials: settings);
    native.emit('hostBackground', second);
    native.emit('systemCallState', second, {'state': 'active'});
    expect(controller.state.sessionId, third);
    native.emit('hostBackground', third);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.lastSummary?.reason, CallEndReason.background);
    expect(native.calls.where((c) => c.$1 == 'leave'), hasLength(1));

    final fourth = await controller.beginWaiting();
    await controller.admit(sessionId: fourth, credentials: settings);
    phone.change(fourth, SystemCallState.ringing);
    phone.change(fourth, SystemCallState.idle);
    expect(controller.state.sessionId, fourth);
    phone.change(fourth, SystemCallState.active);
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.lastSummary?.reason, CallEndReason.systemCall);
    expect(native.calls.where((c) => c.$1 == 'leave'), hasLength(2));
    // After admission the native leave operation owns its observer.
    expect(phone.stopped, [first, second]);
    expect(actions, isEmpty);
  });

  test(
      'two clients align to the same host acceptance and settle the same clock they displayed',
      () async {
    configure(preview: true);
    final peerTransport = FakeTransport();
    final peer = VideoServiceController(transport: peerTransport);
    try {
      final first = await controller.startCall();
      native.emit('remoteJoined', first.sessionId, {'uid': 9});
      expect(controller.connectedDuration, isNull);
      expect(controller.miniElapsedDuration!.inSeconds, lessThan(60));
      final second = await peer.beginWaiting();
      // The common event can precede either client's subscription or its RTC join.
      final origin = DateTime.now().subtract(const Duration(seconds: 74));
      controller.updateBusinessState(
          sessionId: first.sessionId,
          state: CallBusinessState.accepted,
          acceptedAt: origin);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await peer.acceptCall(sessionId: second, acceptedAt: origin.toUtc());
      expect(controller.connectedDuration!.inSeconds, greaterThanOrEqualTo(74));
      expect(peer.connectedDuration!.inSeconds, greaterThanOrEqualTo(74));
      expect(
          (peer.connectedDuration! - controller.connectedDuration!)
              .abs()
              .inMilliseconds,
          lessThan(20));
      expect(controller.state.acceptedAt!.isUtc, isTrue);
      expect(controller.state.acceptedAt, origin.toUtc());
      final full = latestPresentation();
      expect(full['connectedDurationMs'], full['miniElapsedMs']);
      expect(full['acceptedAtMs'], origin.millisecondsSinceEpoch);
      final release = Completer<Object?>();
      native.handler =
          (method, _) async => method == 'leave' ? release.future : null;
      final ending = controller.hangup();
      final frozen = controller.connectedDuration;
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(controller.connectedDuration, frozen);
      expect(controller.miniElapsedDuration, frozen);
      release.complete(null);
      await ending;
      expect(controller.state.lastSummary!.duration, frozen);
      expect(controller.state.lastSummary!.acceptedAt, origin.toUtc());
    } finally {
      await peer.shutdown();
      peer.dispose();
      await peerTransport.stream.close();
    }
  });

  test(
      'future input falls back locally, the first valid correction wins, and duplicate acceptance does not reset or republish',
      () async {
    configure();
    final id = await controller.beginWaiting();
    final now = DateTime.now().toUtc();
    expect(
        () => controller.updateBusinessState(
            sessionId: id, state: CallBusinessState.ringing, acceptedAt: now),
        throwsA(isA<CallException>()));
    await controller.acceptCall(
        sessionId: id, acceptedAt: now.add(const Duration(days: 1)));
    final fallback = controller.state.acceptedAt!;
    expect(controller.connectedDuration!.isNegative, isFalse);
    expect(fallback.isBefore(now.add(const Duration(days: 1))), isTrue);
    final anchor = now.subtract(const Duration(seconds: 123));
    await controller.acceptCall(sessionId: id, acceptedAt: anchor);
    expect(controller.state.acceptedAt, anchor);
    expect(controller.connectedDuration!.inSeconds, greaterThanOrEqualTo(123));
    expect(latestPresentation()['acceptedAtMs'], anchor.millisecondsSinceEpoch);
    final projectionCount = native.calls.length;
    await controller.acceptCall(sessionId: id);
    await controller.acceptCall(sessionId: id, acceptedAt: anchor);
    controller.updateBusinessState(
        sessionId: id,
        state: CallBusinessState.accepted,
        acceptedAt: now.subtract(const Duration(hours: 12)));
    expect(controller.state.acceptedAt, anchor);
    expect(native.calls.length, projectionCount);
    await controller.hangup();
    final next = await controller.beginWaiting();
    await expectLater(controller.acceptCall(sessionId: id, acceptedAt: anchor),
        throwsA(isA<CallException>()));
    expect(controller.state.sessionId, next);
    expect(controller.state.acceptedAt, isNull);
  });

  testWidgets(
      'a synchronous user-action listener may dispose while a window notification is active',
      (tester) async {
    configure();
    final actions = <CallUserAction>[], summaries = <CallSummary>[];
    controller.ended.listen(summaries.add);
    controller.userActions.listen((action) {
      actions.add(action);
      // Immediate host acknowledgement and engine/route teardown.
      unawaited(controller.endCall(
          sessionId: action.sessionId, reason: CallEndReason.user));
      controller.dispose();
    });
    controller.addListener(() {
      if (controller.state.businessState == CallBusinessState.requested) {
        unawaited(controller.hangup());
      }
    });
    await expectLater(
        controller.beginWaiting(),
        throwsA(isA<CallException>()
            .having((e) => e.code, 'code', CallErrorCode.cancelled)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(actions, hasLength(1));
    expect(summaries, hasLength(1));
    expect(
        native.calls.where((c) => c.$1 == 'join' || c.$1 == 'leave'), isEmpty);
    expect(latestPresentation()['sessionId'], isNull);
  });

  test('a staged-only host needs no credential provider', () async {
    native = FakeTransport();
    controller = VideoServiceController(transport: native);
    await expectLater(
        controller.startCall(),
        throwsA(isA<CallException>().having(
            (e) => e.code, 'code', CallErrorCode.invalidConfiguration)));
    expect(controller.state.hasWindow, isFalse);
    final id = await controller.beginWaiting();
    await controller.admit(sessionId: id, credentials: settings);
    expect(controller.state.media.controlsReady, isTrue);
  });

  testWidgets('waiting survives two minutes without starting RTC',
      (tester) async {
    configure(preview: true);
    const request = CallRequest(localAvatarPath: '/cache/profile.jpg');
    final id = await controller.beginWaiting(request: request);
    expect(controller.state.queue!.status, CallQueueStatus.unknown);
    controller.updateQueue(sessionId: id, peopleAhead: 2);
    controller.minimize();
    await tester.pump(const Duration(minutes: 2));
    expect(controller.state.businessState, CallBusinessState.requested);
    expect(controller.state.connectionState, RtcConnectionState.idle);
    expect(controller.localAvatarPath, request.localAvatarPath);
    expect(latestPresentation()['localAvatarPath'], request.localAvatarPath);
    expect(credentialsRequested, 0);
    expect(native.calls.where((c) => c.$1 == 'join'), isEmpty);
    native.emit('remoteJoined', id, {'uid': 9});
    expect(controller.state.media.remoteUid, isNull);
    expect(controller.state.windowMode, CallWindowMode.mini);
    expect(controller.state.queue!.peopleAhead, 2);
    expect(controller.state.queue!.estimatedWait, const Duration(minutes: 10));
    controller.updateQueue(sessionId: id, peopleAhead: 0);
    expect(controller.state.queue!.status, CallQueueStatus.none);
    expect(controller.queueLabel, isNull);
    controller.updateQueue(
        sessionId: id,
        peopleAhead: 2,
        estimatedWait: const Duration(minutes: 3));
    expect(controller.state.queue!.estimatedWait, const Duration(minutes: 3));
    await controller.admit(sessionId: id, credentials: settings);
    native.emit('remoteJoined', id, {'uid': 9});
    expect(controller.showsCallSurface, isFalse);
    expect(controller.miniElapsedDuration, isNull);
    controller.updateQueue(sessionId: id, peopleAhead: 3);
    expect(controller.state.queue!.status, CallQueueStatus.none);
    await controller.acceptCall(sessionId: id);
    expect(controller.showsCallSurface, isTrue);
    expect(controller.state.queue, isNull);
    await controller.hangup();
  });

  test(
      'duplicates join once and a cancelled in-flight admission cannot revive or affect the next session',
      () async {
    configure();
    final id = await controller.beginWaiting();
    final pending = Completer<Object?>();
    native.handler =
        (method, _) async => method == 'join' ? pending.future : null;
    final first = controller.admit(sessionId: id, credentials: settings);
    final second = controller.admit(sessionId: id, credentials: settings);
    expect(native.calls.where((c) => c.$1 == 'join'), hasLength(1));
    await controller.hangup();
    final next = await controller.beginWaiting();
    await expectLater(
        controller.admit(sessionId: id, credentials: settings), invalidSession);
    native.emit('remoteJoined', id, {'uid': 9});
    pending.complete(null);
    expect((await first).status, CallStartStatus.cancelled);
    expect((await second).sessionId, id);
    expect(controller.state.sessionId, next);
    expect(controller.state.media.remoteUid, isNull);
    expect(controller.state.queue!.status, CallQueueStatus.unknown);
    expect(credentialsRequested, 0);
  });

  test(
      'early acceptance stays accepted across admission and duplicate host events',
      () async {
    configure();
    final id = await controller.beginWaiting();
    controller.updateBusinessState(
        sessionId: id, state: CallBusinessState.accepted);
    await controller.admit(sessionId: id, credentials: settings);
    await controller.admit(sessionId: id, credentials: settings);
    controller.updateBusinessState(
        sessionId: id, state: CallBusinessState.accepted);
    expect(controller.state.businessState, CallBusinessState.accepted);
    expect(controller.state.queue, isNull);
    expect(native.calls.where((c) => c.$1 == 'join'), hasLength(1));
    expect(controller.connectedDuration, isNotNull);
  });

  test(
      'user cancels immediately; duplicate native action, release retry and host end do not send user intent twice',
      () async {
    configure();
    final actions = <CallUserAction>[], summaries = <CallSummary>[];
    controller.userActions.listen(actions.add);
    controller.ended.listen(summaries.add);
    final id = await controller.beginWaiting();
    await controller.admit(sessionId: id, credentials: settings);
    final release = Completer<Object?>();
    native.handler =
        (method, _) async => method == 'leave' ? release.future : null;
    final ending =
        expectLater(controller.hangup(), throwsA(isA<CallException>()));
    expect(actions.single.kind, CallUserActionKind.cancel);
    expect(controller.state.queue, isNull);
    expect(actions.single.sessionId, id);
    expect(summaries, isEmpty);
    native.emit('presentationAction', id, {'action': 'hangup'});
    release.completeError(StateError('release transiently failed'));
    await ending;
    expect(summaries, isEmpty);
    native.handler = null;
    await controller.hangup();
    await Future<void>.delayed(Duration.zero);
    expect(summaries, hasLength(1));
    expect(actions, hasLength(1));
    final next = await controller.beginWaiting();
    await controller.acceptCall(sessionId: next);
    native.emit('presentationAction', next, {'action': 'hangup'});
    expect(actions.last.kind, CallUserActionKind.hangup);
    final third = await controller.beginWaiting();
    await controller.endCall(sessionId: third, reason: CallEndReason.user);
    expect(actions, hasLength(2));
  });

  test(
      'per-call media and avatar are isolated; explicit remote mute or local camera off changes primary',
      () async {
    configure();
    const request = CallRequest(
        mediaOptions: CallMediaOptions(videoQuality: VideoQuality.hd),
        localAvatarPath: '/cache/local.jpg');
    final id = await controller.beginWaiting(request: request);
    await controller.admit(sessionId: id, credentials: settings);
    final join = native.calls.lastWhere((c) => c.$1 == 'join').$2;
    expect(join['videoQuality'], 'hd');
    expect(join['cameraFacing'], 'rear');
    await controller.acceptCall(sessionId: id);
    expect(controller.primaryVideo, VideoRole.local);
    native.emit('remoteJoined', id, {'uid': 9});
    native.emit('mediaTrackState', id,
        {'uid': 9, 'track': 'remoteVideo', 'state': 0, 'reason': 7});
    expect(controller.primaryVideo, VideoRole.local);
    native.emit('mediaTrackState', id,
        {'uid': 9, 'track': 'remoteVideo', 'state': 0, 'reason': 5});
    expect(controller.primaryVideo, VideoRole.remote);
    native.emit('mediaTrackState', id,
        {'uid': 9, 'track': 'remoteVideo', 'state': 2, 'reason': 6});
    expect(controller.primaryVideo, VideoRole.local);
    await controller.setCameraEnabled(false);
    expect(controller.primaryVideo, VideoRole.remote);
    expect(controller.canSwapVideo, isFalse);
    await controller.setCameraEnabled(true);
    expect(controller.primaryVideo, VideoRole.local);
    await controller.hangup();
    expect(controller.localAvatarPath, isNull);
    await controller.startCall();
    expect(
        native.calls.lastWhere((c) => c.$1 == 'join').$2['videoQuality'], 'sd');
    expect(controller.localAvatarPath, isNull);
  });
}
