import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppLifecycleState;
import 'package:customer_video_service/customer_video_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'call_manager_test.dart' show FakeTransport, settings;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeTransport transport;
  late VideoServiceController controller;
  setUp(() {
    transport = FakeTransport();
  });
  tearDown(() async {
    transport.handler = null;
    await controller.shutdown();
    controller.dispose();
    await transport.stream.close();
  });

  test('native and Flutter speaker toggles follow the observed output',
      () async {
    controller = VideoServiceController(
        transport: transport,
        lifecycleSource: CallLifecycleSource.nativeHost,
        credentialsProvider: (_) async => settings);
    final id = (await controller.startCall()).sessionId;
    transport.emit('audioRoute', id, {'route': 'earpiece'});
    expect(controller.state.media.speaker, true);
    expect(controller.speakerActive, false);
    transport.emit('presentationAction', id, {'action': 'toggleSpeaker'});
    await Future<void>.delayed(Duration.zero);
    expect(transport.calls.lastWhere((c) => c.$1 == 'setSpeaker').$2['enabled'],
        true);
    transport.emit('audioRoute', id, {'route': 'speaker'});
    await controller.toggleSpeaker();
    expect(transport.calls.lastWhere((c) => c.$1 == 'setSpeaker').$2['enabled'],
        false);
    transport.emit('audioRoute', id, {'route': 'bluetooth'});
    expect(controller.speakerActive, false);
    await controller.setSpeaker(true);
    transport.emit('audioRoute', id, {'route': 'other'});
    expect(controller.speakerActive, true);
    final snapshot =
        transport.calls.lastWhere((c) => c.$1 == 'updatePresentation').$2;
    expect(snapshot['speaker'], true);
    await controller.toggleSpeaker();
    expect(transport.calls.lastWhere((c) => c.$1 == 'setSpeaker').$2['enabled'],
        false);
  });

  test('native token retry handles stale taps, repeated taps and success',
      () async {
    final renewed = Completer<String>();
    var attempts = 0;
    controller = VideoServiceController(
        transport: transport,
        lifecycleSource: CallLifecycleSource.nativeHost,
        credentialsProvider: (_) async => settings,
        tokenProvider: (_, __) async {
          if (++attempts == 1) throw StateError('offline');
          return renewed.future;
        });
    final id = (await controller.startCall()).sessionId;
    Map<String, Object?> view() =>
        transport.calls.lastWhere((c) => c.$1 == 'updatePresentation').$2;
    transport.emit('tokenRequired', id);
    await Future<void>.delayed(Duration.zero);
    expect(view()['needsToken'], true);
    expect(view()['canRefreshToken'], true);
    transport.emit('presentationAction', 'stale', {'action': 'refreshToken'});
    expect(attempts, 1);
    transport.emit('presentationAction', id, {'action': 'refreshToken'});
    expect(view()['canRefreshToken'], false);
    transport.emit('presentationAction', id, {'action': 'refreshToken'});
    expect(attempts, 2);
    renewed.complete('renewed');
    await Future<void>.delayed(Duration.zero);
    expect(view()['needsToken'], false);
    expect(view()['canRefreshToken'], false);
    expect(view()['errorCode'], isNull);
  });

  test('native presentation follows queue, answer and window rotation',
      () async {
    controller = VideoServiceController(
        transport: transport,
        lifecycleSource: CallLifecycleSource.nativeHost,
        mediaOnlyPreview: false,
        credentialsProvider: (_) async => settings);
    final id = (await controller.startCall()).sessionId;
    Map<String, Object?> view() =>
        transport.calls.lastWhere((c) => c.$1 == 'updatePresentation').$2;
    transport.emit('remoteJoined', id, {'uid': 8});
    expect(view()['showsCallSurface'], false);
    expect(view()['awaitingAnswer'], true);
    expect(view()['answeredMiniCard'], false);
    expect(view()['previewMiniCard'], false);
    transport.emit('connection', id, {'state': 'reconnecting'});
    expect(view()['awaitingAnswer'], false);
    transport.emit('connection', id, {'state': 'connected'});
    expect(view()['awaitingAnswer'], true);
    transport.emit('videoBindingError', id, {'role': 'remote'});
    expect(view()['awaitingAnswer'], false);
    transport.emit('videoBound', id, {'role': 'remote'});
    expect(view()['awaitingAnswer'], true);
    expect(view()['connectedDurationMs'], isNull);
    expect(() => controller.updateQueue(sessionId: 'stale', peopleAhead: 9),
        throwsA(isA<CallException>()));
    controller.updateQueue(
        sessionId: id,
        peopleAhead: 1,
        estimatedWait: const Duration(minutes: 5));
    expect(view()['queueLabel'], contains('前面还有1人'));
    controller.updateBusinessState(
        sessionId: id, state: CallBusinessState.accepted);
    expect(view()['showsCallSurface'], true);
    expect(view()['awaitingAnswer'], false);
    expect(view()['answeredMiniCard'], true);
    transport.emit('connection', id, {'state': 'reconnecting'});
    expect(view()['answeredMiniCard'], true);
    expect(view()['miniRemoteVideo'], false);
    expect(view()['miniElapsedMs'], isA<int>());
    transport.emit('connection', id, {'state': 'connected'});
    expect(view()['answeredMiniCard'], true);
    expect(view()['queueLabel'], isNull);
    expect(view()['connectedDurationMs'], isA<int>());
    transport.emit('presentationAction', id, {'action': 'toggleOrientation'});
    expect(controller.callViewRotated, true);
    controller.minimize();
    expect(view()['rotated'], false);
    transport.emit('presentationAction', id, {'action': 'toggleOrientation'});
    expect(view()['rotated'], false);
    controller.restore();
    transport.emit('presentationAction', id, {'action': 'setQualityHd'});
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.media.quality, VideoQuality.hd);
    expect(view()['canToggleOrientation'], true);
    await controller.hangup();
    expect(view()['connectedDurationMs'], isNull);
  });

  test(
      'an RTC-only client can still view media without starting a business clock',
      () async {
    controller = VideoServiceController(
        transport: transport,
        mediaOnlyPreview: true,
        lifecycleSource: CallLifecycleSource.nativeHost,
        credentialsProvider: (_) async => settings);
    final id = (await controller.startCall()).sessionId;
    transport.emit('remoteJoined', id, {'uid': 9});
    expect(controller.showsCallSurface, true);
    expect(controller.connectedDuration, isNull);
    expect(controller.miniElapsedDuration, isNotNull);
    expect(controller.awaitingAnswer, false);
    expect(controller.previewMiniCard, true);
    expect(controller.answeredMiniCard, false);
    controller.updateBusinessState(
        sessionId: id, state: CallBusinessState.accepted);
    final accepted =
        transport.calls.lastWhere((c) => c.$1 == 'updatePresentation').$2;
    expect(accepted['connectedDurationMs'], isA<int>());
    expect(accepted['answeredMiniCard'], true);
    expect(accepted['previewMiniCard'], false);
    transport.emit('remoteLeft', id, {'uid': 9});
    expect(controller.showsCallSurface, true);
    await controller.hangup();
    await controller.startCall();
    expect(controller.showsCallSurface, false);
  });

  test('native swap changes only the layout of the current full call',
      () async {
    controller = VideoServiceController(
        transport: transport,
        allowProbe: true,
        lifecycleSource: CallLifecycleSource.nativeHost,
        mediaOnlyPreview: false,
        credentialsProvider: (_) async => settings);
    Map<String, Object?> view() =>
        transport.calls.lastWhere((c) => c.$1 == 'updatePresentation').$2;
    void swap(String id) =>
        transport.emit('presentationAction', id, {'action': 'swapVideo'});
    final id = (await controller.startCall()).sessionId;
    expect(view()['canSwapVideo'], false);
    swap(id);
    expect(controller.primaryVideo, VideoRole.remote);
    controller.updateBusinessState(
        sessionId: id, state: CallBusinessState.accepted);
    expect(view()['canSwapVideo'], true);
    swap('stale');
    expect(controller.primaryVideo, VideoRole.remote);
    final before = transport.calls.length;
    swap(id);
    expect(view()['primaryVideo'], 'local');
    expect(
        transport.calls.skip(before).map((e) => e.$1), ['updatePresentation']);
    controller.minimize();
    expect(view()['canSwapVideo'], false);
    swap(id);
    controller.restore();
    expect(view()['primaryVideo'], 'local');
    swap(id);
    expect(view()['primaryVideo'], 'remote');
    swap(id);
    await controller.hangup();
    await controller.startProbe();
    expect(view()['primaryVideo'], 'remote');
    expect(view()['canSwapVideo'], false);
  });

  for (final businessAnswered in [false, true]) {
    test(
        'timed mini stays visible until leave completes (business answer: $businessAnswered)',
        () async {
      controller = VideoServiceController(
          transport: transport,
          mediaOnlyPreview: !businessAnswered,
          lifecycleSource: CallLifecycleSource.nativeHost,
          credentialsProvider: (_) async => settings);
      final id = (await controller.startCall()).sessionId;
      transport.emit('remoteJoined', id, {'uid': 9});
      if (businessAnswered) {
        controller.updateBusinessState(
            sessionId: id, state: CallBusinessState.accepted);
      }
      controller.minimize();
      final release = Completer<Object?>();
      transport.handler = (method, _) async {
        if (method == 'leave') return release.future;
        return null;
      };
      final ending = controller.hangup();
      final snapshot =
          transport.calls.lastWhere((c) => c.$1 == 'updatePresentation').$2;
      expect(snapshot['phase'], 'ending');
      expect(snapshot['miniElapsedMs'], isA<int>());
      expect(snapshot['answeredMiniCard'], businessAnswered);
      expect(snapshot['previewMiniCard'], !businessAnswered);
      release.complete({'releaseStatus': 'released'});
      await ending;
      expect(controller.miniElapsedDuration, isNull);
    });
  }

  test(
      'controls wait for credentials and for native permission/join completion',
      () async {
    final credentials = Completer<CallCredentials>(),
        join = Completer<Object?>();
    controller = VideoServiceController(
        transport: transport, credentialsProvider: (_) => credentials.future);
    transport.handler = (m, _) => m == 'join' ? join.future : Future.value();
    final start = controller.startCall();
    Future<void> verifyBlocked() async {
      expect(controller.state.media.controlsReady, false);
      await expectLater(
          controller.setMuted(true),
          throwsA(isA<CallException>()
              .having((e) => e.code, 'code', CallErrorCode.notInitialized)));
      expect(transport.calls.where((c) => c.$1 == 'setMuted'), isEmpty);
    }

    await verifyBlocked();
    credentials.complete(settings);
    await Future<void>.delayed(Duration.zero);
    await verifyBlocked();
    join.complete();
    await start;
    await controller.setMuted(true);
    expect(controller.state.media.muted, true);
  });

  test('a late control error cannot replace the required release recovery',
      () async {
    controller = VideoServiceController(
        transport: transport, credentialsProvider: (_) async => settings);
    await controller.startCall();
    final mute = Completer<Object?>();
    transport.handler = (m, _) async {
      if (m == 'setMuted') return mute.future;
      if (m == 'leave') {
        throw PlatformException(
            code: 'cleanup_failed', details: {'recovery': 'restartRequired'});
      }
      return null;
    };
    final control =
        expectLater(controller.setMuted(true), throwsA(isA<CallException>()));
    await expectLater(controller.hangup(), throwsA(isA<CallException>()));
    mute.completeError(PlatformException(code: 'sdk_-7'));
    await control;
    expect(controller.state.error!.operation, CallOperation.leave);
    expect(controller.state.error!.recovery, CallRecovery.restartRequired);
  });

  test(
      'native pages control the original pending session; only app background ends it',
      () async {
    final credentials = Completer<CallCredentials>();
    controller = VideoServiceController(
        transport: transport,
        lifecycleSource: CallLifecycleSource.nativeHost,
        credentialsProvider: (_) => credentials.future);
    final start = controller.startCall();
    final id = controller.state.sessionId!;
    expect(transport.calls.first.$2['sessionId'], id);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    transport.emit('presentationAction', 'old', {'action': 'hangup'});
    transport.emit('presentationAction', id, {'action': 'minimize'});
    expect(controller.state.windowMode, CallWindowMode.mini);
    transport.emit('presentationAction', id, {'action': 'restore'});
    expect(controller.state.windowMode, CallWindowMode.full);
    transport.emit('hostBackground', id);
    credentials.complete(settings);
    expect((await start).status, CallStartStatus.cancelled);
    expect(controller.state.lastSummary!.reason, CallEndReason.background);
    expect(transport.calls.where((c) => c.$1 == 'join'), isEmpty);
    expect(transport.calls.last.$2['sessionId'], isNull);
  });

  test(
      'trusted peer selection, weak network, observed audio route and canvas recovery',
      () async {
    controller = VideoServiceController(
        transport: transport,
        mediaOptions: const CallMediaOptions(
            cameraFacing: CameraFacing.rear, videoQuality: VideoQuality.sd),
        credentialsProvider: (_) async => CallCredentials(
            appId: settings.appId,
            channel: settings.channel,
            uid: settings.uid,
            expectedPeerUid: 91,
            token: settings.token));
    final diagnostics = <CallDiagnostic>[];
    final sub = controller.diagnostics.listen(diagnostics.add);
    final id = (await controller.startCall()).sessionId;
    expect(transport.calls.first.$2, containsPair('expectedPeerUid', 91));
    expect(transport.calls.first.$2, containsPair('cameraFacing', 'rear'));
    transport.emit('remoteVideo', id, {'uid': 12});
    expect(controller.state.media.remoteUid, isNull);
    transport.emit('remoteJoined', id, {'uid': 91});
    transport.emit(
        'networkQuality', id, {'uid': 12, 'txQuality': 5, 'rxQuality': 5});
    expect(controller.state.media.remoteWeak, false);
    transport
        .emit('networkQuality', id, {'uid': 0, 'txQuality': 4, 'rxQuality': 1});
    transport.emit(
        'networkQuality', id, {'uid': 91, 'txQuality': 1, 'rxQuality': 3});
    expect(controller.state.media.localWeak, true);
    expect(controller.state.media.remoteWeak, true);
    transport
        .emit('networkQuality', id, {'uid': 0, 'txQuality': 1, 'rxQuality': 1});
    expect(controller.state.media.localWeak, false);
    transport.emit('audioRoute', id, {'route': 'bluetooth'});
    expect(controller.state.media.audioRoute, AudioRoute.bluetooth);
    transport.emit('videoBindingError', id, {
      'role': 'remote',
      'details': {'sdkCode': -7}
    });
    transport.emit('videoBound', id, {'role': 'local'});
    expect(controller.state.media.bindingFailures, {VideoRole.remote});
    await controller.retryVideoBinding();
    transport.emit('videoBound', id, {'role': 'remote'});
    expect(controller.state.media.bindingFailures, isEmpty);
    await controller.setVideoQuality(VideoQuality.hd);
    expect(controller.state.media.quality, VideoQuality.hd);
    transport.emit('remoteLeft', id, {'uid': 91});
    transport.emit(
        'networkQuality', id, {'uid': 91, 'txQuality': 5, 'rxQuality': 5});
    expect(controller.state.media.remoteWeak, false);
    await controller.hangup();
    await Future<void>.delayed(Duration.zero);
    expect(
        diagnostics.map((d) => d.stage),
        containsAllInOrder([
          CallStage.requested,
          CallStage.joinAccepted,
          CallStage.videoBindingFailed,
          CallStage.released
        ]));
    await sub.cancel();
  });

  test('paused video rejects stale frame and render statistics until restart',
      () async {
    controller = VideoServiceController(
        transport: transport, credentialsProvider: (_) async => settings);
    final id = (await controller.startCall()).sessionId;
    void track(int state, int uid) => transport.emit('mediaTrackState', id,
        {'uid': uid, 'track': 'remoteVideo', 'state': state, 'reason': 5});
    void stats() => transport.emit(
        'remoteVideoStats', id, {'uid': 81, 'rendererOutputFrameRate': 15});
    transport.emit('remoteJoined', id, {'uid': 81});
    transport.emit('remoteVideo', id, {'uid': 81});
    track(0, 82);
    expect(controller.state.media.remoteVideo, true);
    track(0, 81);
    stats();
    transport.emit('remoteVideo', id, {'uid': 81});
    expect(controller.state.media.remoteVideo, false);
    track(2, 81);
    expect(controller.state.media.remoteVideo, false);
    stats();
    expect(controller.state.media.remoteVideo, true);
    transport.emit('remoteLeft', id, {'uid': 81});
    expect(controller.state.media.trackStates[MediaTrack.remoteVideo], isNull);
  });

  test('native media commands target only the active, ready session', () async {
    controller = VideoServiceController(
        transport: transport,
        credentialsProvider: (_) async => settings,
        lifecycleSource: CallLifecycleSource.nativeHost);
    final old = (await controller.startCall()).sessionId;
    await controller.hangup();
    final id = (await controller.startCall()).sessionId;
    transport.emit('presentationAction', old, {'action': 'toggleMuted'});
    expect(transport.calls.where((c) => c.$1 == 'setMuted'), isEmpty);
    for (final entry in {
      'toggleMuted': 'setMuted',
      'toggleCamera': 'setCameraEnabled',
      'toggleSpeaker': 'setSpeaker',
      'toggleQuality': 'setVideoQuality',
      'switchCamera': 'switchCamera',
      'rebindVideo': 'rebindVideo',
    }.entries) {
      transport.emit('presentationAction', id, {'action': entry.key});
      await Future<void>.delayed(Duration.zero);
      expect(transport.calls.where((c) => c.$1 == entry.value).single.$2,
          containsPair('sessionId', id));
    }
    final snapshot =
        transport.calls.lastWhere((c) => c.$1 == 'updatePresentation').$2;
    expect(snapshot, containsPair('cameraEnabled', false));
    expect(snapshot, containsPair('muted', true));
    expect(snapshot.containsKey('token'), false);
    expect(snapshot.containsKey('channel'), false);
  });

  test('failed explicit canvas retry propagates without ending the live call',
      () async {
    controller = VideoServiceController(
        transport: transport, credentialsProvider: (_) async => settings);
    final id = (await controller.startCall()).sessionId;
    transport.emit('videoBindingError', id, {'role': 'remote'});
    transport.handler = (method, _) async {
      if (method == 'rebindVideo') {
        throw PlatformException(code: 'sdkError', details: {'sdkCode': -17});
      }
      return null;
    };
    await expectLater(
        controller.retryVideoBinding(),
        throwsA(isA<CallException>()
            .having((e) => e.operation, 'operation', CallOperation.rebindVideo)
            .having((e) => e.vendorCode, 'vendorCode', -17)));
    expect(controller.state.sessionId, id);
    expect(controller.state.media.controlsReady, true);
    transport.emit('videoBound', id, {'role': 'remote'});
    expect(controller.state.media.bindingFailures, isEmpty);
    expect(controller.state.error, isNull);
  });

  test(
      'native background cancellation wins when join reply precedes host event',
      () async {
    controller = VideoServiceController(
        transport: transport,
        lifecycleSource: CallLifecycleSource.nativeHost,
        credentialsProvider: (_) async => settings);
    transport.handler = (method, _) async {
      if (method == 'join') throw PlatformException(code: 'host_background');
      return null;
    };
    final result = await controller.startCall();
    expect(result.status, CallStartStatus.cancelled);
    expect(controller.state.lastSummary!.context.sessionId, result.sessionId);
    expect(controller.state.lastSummary!.reason, CallEndReason.background);
    expect(controller.state.lastSummary!.error, isNull);
    transport.handler = null;
    final next = await controller.startCall();
    transport.emit('hostBackground', result.sessionId);
    expect(controller.state.sessionId, next.sessionId);
  });

  test('H5 request metadata belongs to the native document binding', () async {
    CallRequest? request;
    controller = VideoServiceController(
        transport: transport,
        credentialsProvider: (ctx) async {
          request = ctx.request;
          return settings;
        });
    final bridge = CustomerH5Bridge(controller: controller),
        sent = <Map<String, Object?>>[];
    final page = bridge.attach(
        send: sent.add,
        requestForCall: () => const CallRequest(businessId: 'trusted-order'));
    await page.ready();
    await page.receive(jsonEncode({
      'version': 1,
      'requestId': 'one',
      'action': 'startRtc',
      'params': {'businessId': 'untrusted-order'}
    }));
    expect(request!.businessId, 'trusted-order');
    expect(jsonEncode(sent), isNot(contains('trusted-order')));
    bridge.dispose();
  });
}
