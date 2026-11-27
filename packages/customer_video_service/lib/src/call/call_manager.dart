import 'dart:async';

import 'package:customer_rtc/customer_rtc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'rtc_diagnostics.dart';
import 'session_notifier.dart';
import 'call_failure.dart';
export 'call_failure.dart' show safeErrorCode;
import '../models.dart';

/// App-owned session. Native views and business routes do not own this lifecycle.
class CallManager extends SessionNotifier {
  CallManager(this.transport,
      {this.joinTimeout = const Duration(seconds: 45),
      this.credentialsTimeout = const Duration(seconds: 30),
      this.mediaOptions = const CallMediaOptions(),
      this.nativeHost = false,
      this.mediaOnlyPreview = false}) {
    _subscription = transport.events.listen(_onEvent, onError: (_) {
      if (!_disposed && phase != CallPhase.ending) {
        _failure = const CallException(CallErrorCode.bridgeUnavailable,
            operation: CallOperation.event);
        _notify();
      }
    });
  }
  final RtcTransport transport;
  final CallMediaOptions mediaOptions;
  final bool nativeHost, mediaOnlyPreview;
  CallMediaOptions get _callMedia => _session?.mediaOptions ?? mediaOptions;
  bool get _allowMediaPreview =>
      mediaOnlyPreview && _session?.waitForAdmission == false;
  final _userActions = StreamController<CallUserAction>.broadcast(sync: true);
  Stream<CallUserAction> get userActions => _userActions.stream;
  bool _nativeReady = false;
  bool get controlsReady =>
      _nativeReady && hasWindow && !_probe && _phase != CallPhase.ending;
  bool localWeak = false, remoteWeak = false;
  int? _expectedPeer;
  VideoQuality? quality;
  AudioRoute? audioRoute;
  final trackStates = <MediaTrack, TrackObservation>{};
  final bindingFailures = <VideoRole>{};
  final _diagnostics = StreamController<CallDiagnostic>.broadcast();
  Stream<CallDiagnostic> get diagnostics => _diagnostics.stream;
  void _record(CallStage stage, {int? code, VideoRole? role}) {
    final session = _session;
    if (session != null && _diagnostics.hasListener) {
      _diagnostics.add(CallDiagnostic(
          session.context.sessionId, stage, session.clock.elapsed,
          vendorCode: code, role: role));
    }
  }

  void _resetMedia() {
    _nativeReady = localWeak = remoteWeak = false;
    _tokenRefreshFailed = false;
    quality = _callMedia.videoQuality;
    audioRoute = null;
    _expectedPeer = null;
    bindingFailures.clear();
    trackStates.clear();
  }

  final Duration joinTimeout, credentialsTimeout;
  Timer? _joinTimer;
  bool _nativeJoinRequested = false;
  bool _joined = false;
  CallIdentity? identity;
  CallEndReason? endReason;
  String? lastFinishedSessionId;
  String? get diagnostic => _diagnostic;
  int? get remoteUid => _remoteUid;
  bool get remoteVideo => _remoteVideo;
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  CallPhase _phase = CallPhase.idle;
  String? _sessionId;
  bool _probe = false;
  bool _mini = false;
  bool _muted = false;
  bool _cameraEnabled = true;
  bool _speaker = true;
  bool _needsToken = false;
  bool _tokenRefreshFailed = false;
  Future<void> Function()? onRefreshToken;
  bool get canRefreshToken =>
      _tokenRefreshFailed &&
      onRefreshToken != null &&
      hasWindow &&
      _phase != CallPhase.ending;
  bool _controlBusy = false;
  bool _disposed = false;
  int? _remoteUid;
  bool _remoteVideo = false;
  int _sequence = 0;
  CallException? _failure;
  _CallSession? _session;
  final _ended = StreamController<CallSummary>.broadcast();
  Stream<CallSummary> get ended => _ended.stream;
  CallContext? get context => _session?.context;
  CallSummary? lastSummary;
  RtcConnectionState connectionState = RtcConnectionState.idle;
  CallBusinessState businessState = CallBusinessState.none;
  CallException? get failure => _failure;
  String? _diagnostic;
  Future<void>? _ending;

  CallPhase get phase => _phase;
  String? get sessionId => _sessionId;
  bool get systemCallRinging => _session?.systemCallRinging ?? false;
  bool get hasWindow => _sessionId != null;
  bool get isProbe => _probe;
  bool get isMini => _mini;
  bool get rotated => _session?.rotated ?? false;
  bool get showsCallSurface =>
      _probe ||
      connectedDuration != null ||
      (_allowMediaPreview &&
          businessState == CallBusinessState.requested &&
          queueLabel == null &&
          _session?.firstPeerAt != null);
  bool get awaitingAnswer =>
      (businessState == CallBusinessState.requested ||
          businessState == CallBusinessState.ringing) &&
      !showsCallSurface &&
      _canShowMiniCard;

  bool get answeredMiniCard =>
      _session?.acceptedAt != null && miniElapsedDuration != null;

  bool get previewMiniCard =>
      hasWindow &&
      ((_probe && _phase != CallPhase.ending) ||
          (_session?.acceptedAt == null && miniElapsedDuration != null));

  // An RTC-only test room has no agent signalling. Start its display clock at
  // the first trusted peer, without affecting the business clock or call summary.
  Duration? get miniElapsedDuration {
    final session = _session;
    if (session == null || _probe) return null;
    if (_phase == CallPhase.ending) {
      return _failure?.code == CallErrorCode.cleanupFailed
          ? null
          : session.finalMiniDuration;
    }
    if (businessState == CallBusinessState.accepted) return connectedDuration;
    final firstPeerAt = session.firstPeerAt;
    if (!_allowMediaPreview ||
        businessState != CallBusinessState.requested ||
        queueLabel != null ||
        firstPeerAt == null) {
      return null;
    }
    return session.clock.elapsed - firstPeerAt;
  }

  bool get miniRemoteVideo =>
      remoteVideo &&
      _phase != CallPhase.reconnecting &&
      connectionState != RtcConnectionState.reconnecting &&
      connectionState != RtcConnectionState.disconnected &&
      !bindingFailures.contains(VideoRole.remote);

  // A closed agent camera is a normal avatar state after the business answer.
  // Recovery actions and diagnostics stay on the regular mini panel.
  bool get _canShowMiniCard =>
      hasWindow &&
      _phase != CallPhase.reconnecting &&
      connectionState != RtcConnectionState.disconnected &&
      connectionState != RtcConnectionState.reconnecting &&
      _failure == null &&
      bindingFailures.isEmpty &&
      !_needsToken &&
      trackStates[MediaTrack.remoteVideo]?.activity != TrackActivity.failed &&
      trackStates[MediaTrack.localVideo]?.activity != TrackActivity.failed &&
      trackStates[MediaTrack.localAudio]?.activity != TrackActivity.failed;
  bool get canToggleOrientation =>
      hasWindow && !_mini && showsCallSurface && _phase != CallPhase.ending;
  bool get _remoteForcedPrimary {
    final track = trackStates[MediaTrack.remoteVideo];
    // Agora REMOTE_VIDEO_STATE_STOPPED / REMOTE_VIDEO_STATE_REASON_REMOTE_MUTED.
    return !_cameraEnabled ||
        (track?.activity == TrackActivity.stopped && track?.reason == 5);
  }

  bool get canSwapVideo =>
      canToggleOrientation && !_probe && !_remoteForcedPrimary;
  VideoRole get primaryVideo => _remoteForcedPrimary
      ? VideoRole.remote
      : (_session?.primaryVideo ?? _callMedia.primaryVideo);

  void swapVideo() {
    if (!canSwapVideo) return;
    _session!.primaryVideo =
        primaryVideo == VideoRole.local ? VideoRole.remote : VideoRole.local;
    _notify();
  }

  DateTime? get acceptedAt => _session?.acceptedAt;
  Duration? get connectedDuration => _session?.businessDuration;

  CallQueueState? get queue => _session?.queue;
  String? get queueLabel => queue?.label;

  void toggleOrientation() {
    if (!canToggleOrientation) return;
    _session!.rotated = !rotated;
    _notify();
  }

  void updateQueue(
      {required String sessionId, int? peopleAhead, Duration? estimatedWait}) {
    _requireSession(sessionId);
    if (_probe || businessState == CallBusinessState.accepted) {
      throw const CallException(CallErrorCode.invalidArgument);
    }
    // An already-running poll may arrive after the host has admitted this session.
    if (_session!.admission != null) return;
    final next = CallQueueState.fromPosition(
        peopleAhead: peopleAhead, estimatedWait: estimatedWait);
    if (next.status == queue?.status &&
        next.peopleAhead == queue?.peopleAhead &&
        next.estimatedWait == queue?.estimatedWait) {
      return;
    }
    _session!.queue = next;
    _notify();
  }

  bool get muted => _muted;
  bool get cameraEnabled => _cameraEnabled;
  bool get speaker => _speaker;
  bool get needsToken => _needsToken;
  bool get controlBusy => _controlBusy;
  String? get errorCode => _failure?.code.name;

  Future<CallStartResult> start(
      {required bool probe,
      bool waitForAdmission = false,
      CallRequest request = const CallRequest(),
      CallCredentials? settings,
      CredentialsProvider? credentialsProvider}) async {
    if (_disposed) throw const CallException(CallErrorCode.disposed);
    if (hasWindow) throw StateError('busy');
    request.validate();
    if (!probe) {
      if (!waitForAdmission &&
          settings == null &&
          credentialsProvider == null) {
        throw ArgumentError('missingConfiguration');
      }
      settings?.validate();
    }
    final id = '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
    final session = _CallSession(
        CallContext(
            sessionId: id, request: request, startedAt: DateTime.now().toUtc()),
        request.mediaOptions?.withDefaults(mediaOptions) ?? mediaOptions,
        waitForAdmission);
    if (!probe) session.queue = const CallQueueState.unknown();
    _session = session;
    _resetMedia();
    _record(CallStage.requested);
    _sessionId = id;
    _probe = probe;
    _mini = false;
    _muted = false;
    _cameraEnabled = true;
    _speaker = true;
    _remoteUid = null;
    _remoteVideo = false;
    _needsToken = false;
    _failure = null;
    _diagnostic = null;
    identity = null;
    endReason = null;
    _nativeJoinRequested = false;
    _joined = false;
    _joinTimer?.cancel();
    _phase = probe
        ? CallPhase.probe
        : (waitForAdmission ? CallPhase.waiting : CallPhase.joining);
    connectionState = probe || waitForAdmission
        ? RtcConnectionState.idle
        : RtcConnectionState.connecting;
    businessState =
        probe ? CallBusinessState.none : CallBusinessState.requested;
    final monitor = transport;
    if (probe || monitor is! SystemCallMonitor) {
      session.canAdmit = waitForAdmission;
      _notify();
    }
    if (probe) {
      return CallStartResult(sessionId: id, status: CallStartStatus.accepted);
    }
    try {
      if (!_isCurrent(session)) return _startResult(session, cancelled: true);
      if (monitor is SystemCallMonitor) {
        await checkSystemCallAvailable(observeSessionId: id);
        if (!_isCurrent(session)) return _startResult(session, cancelled: true);
        session.canAdmit = waitForAdmission;
        _notify();
        if (!_isCurrent(session)) return _startResult(session, cancelled: true);
      }
      if (waitForAdmission) return _startResult(session);
      if (settings == null) {
        try {
          settings = await credentialsProvider!(session.context)
              .timeout(credentialsTimeout);
        } catch (_) {
          throw const CallException(CallErrorCode.credentialsFailed,
              operation: CallOperation.credentials,
              recovery: CallRecovery.retryCall);
        }
      }
      if (!_isCurrent(session)) return _startResult(session, cancelled: true);
      return await _join(session, settings);
    } catch (error) {
      return _startFailure(session, error);
    }
  }

  Future<CallStartResult> admit(String id, CallCredentials credentials) async {
    _requireSession(id);
    final session = _session!;
    if (!session.canAdmit) {
      throw const CallException(CallErrorCode.invalidArgument);
    }
    final pending = session.admission;
    if (pending != null) return pending;
    try {
      credentials.validate();
    } on ArgumentError {
      throw const CallException(CallErrorCode.invalidConfiguration);
    }
    final result = Completer<CallStartResult>();
    session.admission = result.future;
    result.complete(_admit(session, credentials));
    return result.future;
  }

  Future<CallStartResult> _admit(
      _CallSession session, CallCredentials credentials) async {
    try {
      if (transport is SystemCallMonitor) await checkSystemCallAvailable();
      if (!_isCurrent(session)) return _startResult(session, cancelled: true);
      _phase = CallPhase.joining;
      connectionState = RtcConnectionState.connecting;
      if (businessState != CallBusinessState.accepted) {
        session.queue = CallQueueState.fromPosition(peopleAhead: 0);
      }
      _notify();
      if (!_isCurrent(session)) return _startResult(session, cancelled: true);
      return await _join(session, credentials);
    } catch (error) {
      return _startFailure(session, error);
    }
  }

  Future<CallStartResult> _join(
      _CallSession session, CallCredentials settings) async {
    final id = session.context.sessionId;
    settings.validate();
    identity = settings.identity;
    _expectedPeer = settings.expectedPeerUid;
    _record(CallStage.credentialsReady);
    _nativeJoinRequested = true;
    await transport.invoke('join', {
      'sessionId': id,
      'appId': settings.appId.trim(),
      'channel': settings.channel.trim(),
      'token': settings.token.trim(),
      'uid': settings.uid,
      if (_expectedPeer != null) 'expectedPeerUid': _expectedPeer,
      if (_callMedia.cameraFacing != null)
        'cameraFacing': _callMedia.cameraFacing!.name,
      if (quality != null) 'videoQuality': quality!.name,
    }).timeout(const Duration(seconds: 45));
    if (!_isCurrent(session)) return _startResult(session, cancelled: true);
    if (!_joined) {
      _joinTimer = Timer(joinTimeout, () {
        if (!_isCurrent(session) || _joined) return;
        _failure = session.terminalError = const CallException(
            CallErrorCode.joinTimeout,
            operation: CallOperation.join,
            recovery: CallRecovery.retryCall);
        unawaited(hangup(reason: CallEndReason.joinFailed));
      });
    }
    _nativeReady = true;
    _record(CallStage.joinAccepted);
    _notify();
    return _startResult(session, cancelled: !_isCurrent(session));
  }

  Future<CallStartResult> _startFailure(
      _CallSession session, Object error) async {
    if (!_isCurrent(session)) return _startResult(session, cancelled: true);
    // The method reply can arrive before the host lifecycle event.
    if (error is PlatformException && error.code == 'host_background') {
      await hangup(reason: CallEndReason.background);
      if (identical(_session, session)) {
        throw _failure ?? const CallException(CallErrorCode.cleanupFailed);
      }
      return _startResult(session, cancelled: true);
    }
    final failure = callFailure(error, operation: CallOperation.join);
    _failure = session.terminalError = failure;
    if (kDebugMode && error is PlatformException) {
      final details = error.details;
      final code = details is Map ? details['sdkCode'] : null;
      _diagnostic = code is int ? 'RTC join code=$code' : 'RTC join failed';
      final stage = details is Map ? details['stage'] : null;
      if (const {'create', 'enableMedia', 'bindVideos', 'preview', 'join'}
          .contains(stage)) {
        _diagnostic = '$_diagnostic stage=$stage';
      }
      final kind = details is Map ? details['exceptionType'] : null;
      if (const {
        'SecurityException',
        'IllegalArgumentException',
        'IllegalStateException',
        'RuntimeException',
        'NullPointerException',
        'RtcOperationException'
      }.contains(kind)) {
        _diagnostic = '$_diagnostic type=$kind';
      }
    }
    await hangup(
        reason: failure.code == CallErrorCode.systemCallBusy
            ? CallEndReason.systemCall
            : CallEndReason.joinFailed);
    if (identical(_session, session) && _phase == CallPhase.ending) {
      throw _failure ?? failure;
    }
    throw failure;
  }

  bool _isCurrent(_CallSession session) =>
      !_disposed && identical(_session, session) && _phase != CallPhase.ending;

  Future<SystemCallState> _readSystemCall({String? observeSessionId}) async {
    final source = transport;
    if (source is! SystemCallMonitor) return SystemCallState.unknown;
    try {
      return await (source as SystemCallMonitor)
          .getSystemCallState(sessionId: observeSessionId);
    } on MissingPluginException {
      return SystemCallState.unknown;
    } on PlatformException catch (error) {
      if (error.code == 'system_call_busy') return SystemCallState.active;
      return SystemCallState.unknown;
    }
  }

  Future<void> checkSystemCallAvailable({String? observeSessionId}) async {
    final state = await _readSystemCall(observeSessionId: observeSessionId);
    if (state == SystemCallState.active ||
        state == SystemCallState.ringing ||
        (observeSessionId != null &&
            observeSessionId == _sessionId &&
            systemCallRinging)) {
      throw const CallException(CallErrorCode.systemCallBusy);
    }
  }

  /// A fullscreen system ringtone can temporarily put the Flutter host behind
  /// the phone UI. Keep the call until the native answer/decline is known.
  Future<void> handleFlutterBackground({required bool detached}) async {
    final session = _session;
    if (session == null || !_isCurrent(session)) return;
    if (!detached && !_probe && transport is SystemCallMonitor) {
      if (session.flutterPaused) return;
      session.flutterPaused = true;
      if (systemCallRinging) return;
      final ringGeneration = session.ringGeneration;
      // The full-screen phone UI can pause Flutter just before telephony reports
      // the incoming call. Observe the pending native events before classifying it.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!_isCurrent(session)) return;
      final state = await _readSystemCall().timeout(const Duration(seconds: 2),
          onTimeout: () => SystemCallState.unknown);
      if (!_isCurrent(session)) return;
      if (state == SystemCallState.active) {
        _systemCallAnswered(session);
        return;
      }
      if (state == SystemCallState.ringing ||
          systemCallRinging ||
          ringGeneration != session.ringGeneration) {
        return;
      }
    }
    await hangup(reason: CallEndReason.background);
  }

  void flutterResumed() {
    _session?.flutterPaused = false;
  }

  Future<void> acceptCall(String id, {DateTime? acceptedAt}) async {
    _requireSession(id);
    final session = _session!;
    if (businessState == CallBusinessState.accepted) {
      updateBusinessState(
          sessionId: id,
          state: CallBusinessState.accepted,
          acceptedAt: acceptedAt);
      return;
    }
    try {
      await checkSystemCallAvailable();
      updateBusinessState(
          sessionId: id,
          state: CallBusinessState.accepted,
          acceptedAt: acceptedAt);
    } on CallException catch (error) {
      if (error.code == CallErrorCode.systemCallBusy && _isCurrent(session)) {
        _failure = session.terminalError = error;
        await hangup(reason: CallEndReason.systemCall);
      }
      rethrow;
    }
  }

  void _systemCallAnswered(_CallSession session) {
    if (!_nativeReady && businessState != CallBusinessState.accepted) {
      _failure = session.terminalError =
          const CallException(CallErrorCode.systemCallBusy);
    }
    unawaited(hangup(reason: CallEndReason.systemCall));
  }

  CallStartResult _startResult(_CallSession session, {bool cancelled = false}) {
    final error = session.terminalError;
    if (error != null) throw error;
    return CallStartResult(
        sessionId: session.context.sessionId,
        status:
            cancelled ? CallStartStatus.cancelled : CallStartStatus.accepted);
  }

  void updateBusinessState(
      {required String sessionId,
      required CallBusinessState state,
      DateTime? acceptedAt}) {
    _requireSession(sessionId);
    if (_probe ||
        (acceptedAt != null && state != CallBusinessState.accepted) ||
        (state != CallBusinessState.ringing &&
            state != CallBusinessState.accepted) ||
        (businessState == CallBusinessState.accepted &&
            state != CallBusinessState.accepted)) {
      throw const CallException(CallErrorCode.invalidArgument);
    }
    if (businessState == state) {
      if (state == CallBusinessState.accepted &&
          _session!.recordAcceptance(acceptedAt)) {
        _notify();
      }
      return;
    }
    if (state == CallBusinessState.accepted && systemCallRinging) {
      _failure = _session!.terminalError =
          const CallException(CallErrorCode.systemCallBusy);
      unawaited(hangup(reason: CallEndReason.systemCall));
      throw const CallException(CallErrorCode.systemCallBusy);
    }
    businessState = state;
    if (state == CallBusinessState.accepted) {
      _session!.recordAcceptance(acceptedAt);
      _session!.queue = null;
    }
    _notify();
  }

  void _requireSession(String id, {bool allowEnding = false}) {
    if (_disposed ||
        _sessionId != id ||
        (!allowEnding && _phase == CallPhase.ending)) {
      throw const CallException(CallErrorCode.invalidArgument);
    }
  }

  Future<void> endCall(
      {required String sessionId, required CallEndReason reason}) {
    _requireSession(sessionId, allowEnding: true);
    return hangup(reason: reason);
  }

  Future<void> hangup(
      {CallEndReason reason = CallEndReason.user, bool userInitiated = false}) {
    if (_ending != null) return _ending!;
    final session = _session;
    if (session == null) return Future.value();
    final id = session.context.sessionId;
    _joinTimer?.cancel();
    endReason ??= reason;
    final action = userInitiated && !_probe && session.endedAt == null
        ? CallUserAction(
            session.context,
            session.acceptedAt == null
                ? CallUserActionKind.cancel
                : CallUserActionKind.hangup)
        : null;
    if (session.endedAt == null) {
      session.finishTiming();
      session.finalMiniDuration = miniElapsedDuration;
      _record(CallStage.ending);
    }
    session.queue = null;
    _phase = CallPhase.ending;
    businessState = CallBusinessState.ended;
    // Reserve the ending future before notifying reentrant host listeners.
    final completion = Completer<void>();
    _ending = completion.future;
    if (action != null) _userActions.add(action);
    _notify();
    () async {
      try {
        var release = ReleaseStatus.released;
        final monitor = transport;
        if (!_probe && !_nativeJoinRequested && monitor is SystemCallMonitor) {
          try {
            await (monitor as SystemCallMonitor)
                .endSystemCallObservation(id)
                .timeout(const Duration(seconds: 2));
          } on MissingPluginException {
            // Old native binaries have no observation to remove.
          }
        }
        if (!_probe && _nativeJoinRequested) {
          final result = await transport.invoke(
              'leave', {'sessionId': id}).timeout(const Duration(seconds: 15));
          if (result != null) {
            final status = result is Map ? result['releaseStatus'] : null;
            if (status == 'releasedWithWarnings') {
              release = ReleaseStatus.releasedWithWarnings;
            } else if (status != 'released') {
              throw const CallException(CallErrorCode.cleanupFailed,
                  operation: CallOperation.leave,
                  recovery: CallRecovery.retryOperation);
            }
          }
        }
        if (identical(_session, session)) {
          final summary = CallSummary(
              context: session.context,
              acceptedAt: session.acceptedAt,
              endedAt: session.endedAt!,
              duration: session.businessDuration,
              reason: endReason!,
              releaseStatus: release,
              error: session.terminalError);
          lastSummary = summary;
          lastFinishedSessionId = id;
          _record(CallStage.released);
          _sessionId = null;
          _session = null;
          _resetMedia();
          identity = null;
          _nativeJoinRequested = false;
          _phase = CallPhase.idle;
          connectionState = RtcConnectionState.idle;
          _remoteUid = null;
          _remoteVideo = false;
          _needsToken = false;
          _controlBusy = false;
          _failure = session.terminalError;
          if (!_ended.isClosed) _ended.add(summary);
        }
      } catch (error) {
        if (identical(_session, session)) {
          final mapped = callFailure(error, operation: CallOperation.leave);
          _failure = CallException(CallErrorCode.cleanupFailed,
              operation: CallOperation.leave,
              vendorCode: mapped.vendorCode,
              recovery: mapped.recovery);
        }
      } finally {
        _ending = null;
        _notify();
        completion.complete();
      }
    }();
    return completion.future;
  }

  void minimize() {
    if (hasWindow) {
      _session!.rotated = false;
      _mini = true;
      _notify();
    }
  }

  void restore() {
    if (hasWindow) {
      _mini = false;
      _notify();
    }
  }

  Future<void> setMuted(bool value) =>
      _control('setMuted', {'muted': value}, () => _muted = value);
  Future<void> setCameraEnabled(bool value) => _control(
      'setCameraEnabled', {'enabled': value}, () => _cameraEnabled = value);
  bool get speakerActive => switch (audioRoute) {
        AudioRoute.speaker => true,
        AudioRoute.earpiece ||
        AudioRoute.wired ||
        AudioRoute.bluetooth =>
          false,
        _ => speaker,
      };
  Future<void> toggleSpeaker() => setSpeaker(!speakerActive);
  Future<void> setSpeaker(bool value) =>
      _control('setSpeaker', {'enabled': value}, () => _speaker = value);
  Future<void> setVideoQuality(VideoQuality value) => _control(
      'setVideoQuality', {'quality': value.name}, () => quality = value);
  Future<void> rebindVideo() => _control('rebindVideo', {}, () {});
  Future<void> switchCamera() => _control('switchCamera', {}, () {});
  Future<void> renewToken(String token) async {
    if (token.trim().isEmpty) throw ArgumentError('emptyToken');
    final id = _sessionId;
    if (id == null || _probe || _phase == CallPhase.ending) {
      throw StateError('unavailable');
    }
    await transport
        .invoke('renewToken', {'sessionId': id, 'token': token.trim()}).timeout(
            const Duration(seconds: 10));
    if (_sessionId == id && _phase != CallPhase.ending) {
      _needsToken = false;
      _record(CallStage.tokenRenewed);
      if (errorCode == 'tokenRefreshFailed') _failure = null;
      _notify();
    }
  }

  void tokenRefreshStarted() {
    if (!_tokenRefreshFailed) return;
    _tokenRefreshFailed = false;
    if (_failure?.code == CallErrorCode.tokenRefreshFailed) _failure = null;
    _notify();
  }

  void tokenRefreshFailed(String id) {
    if (_sessionId != id || _phase == CallPhase.ending || _disposed) return;
    _tokenRefreshFailed = true;
    _failure = const CallException(CallErrorCode.tokenRefreshFailed,
        operation: CallOperation.renewToken,
        recovery: CallRecovery.retryOperation);
    _notify();
  }

  Future<void> _control(
      String method, Map<String, Object?> values, VoidCallback apply) async {
    final id = _sessionId;
    final operation = CallOperation.values.byName(method);
    if (!controlsReady || id == null || _controlBusy) {
      throw CallException(
          _controlBusy ? CallErrorCode.busy : CallErrorCode.notInitialized,
          operation: operation,
          recovery: CallRecovery.retryOperation);
    }
    _controlBusy = true;
    _notify();
    try {
      await transport.invoke(method, {'sessionId': id, ...values}).timeout(
          const Duration(seconds: 10));
      if (_sessionId == id && _phase != CallPhase.ending) {
        apply();
        if (_failure?.operation?.name == method) _failure = null;
      }
    } catch (error) {
      final failure =
          callFailure(error, operation: CallOperation.values.byName(method));
      if (_sessionId == id && _phase != CallPhase.ending) _failure = failure;
      throw failure;
    } finally {
      if (_sessionId == id) {
        _controlBusy = false;
        _notify();
      }
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    if (_disposed || _sessionId == null || event['sessionId'] != _sessionId) {
      return;
    }
    final type = event['type'];
    if (type == 'systemCallState' && !_probe && _phase != CallPhase.ending) {
      final session = _session!;
      final state = event['state'];
      if (state == 'active') {
        _systemCallAnswered(session);
      } else if (state == 'ringing' || state == 'idle') {
        final ringing = state == 'ringing';
        if (ringing != session.systemCallRinging) {
          session.systemCallRinging = ringing;
          if (ringing) session.ringGeneration++;
          _notify();
        }
      }
      return;
    }
    if (nativeHost && type == 'hostBackground') {
      unawaited(hangup(reason: CallEndReason.background));
      return;
    }
    if (nativeHost && type == 'presentationAction') {
      final action = event['action'];
      if (action is String && controlsReady && !_controlBusy) {
        final operation = switch (action) {
          'toggleMuted' => () => setMuted(!muted),
          'toggleCamera' => () => setCameraEnabled(!cameraEnabled),
          'toggleSpeaker' => toggleSpeaker,
          'switchCamera' => switchCamera,
          'toggleQuality' => () => setVideoQuality(
              quality == VideoQuality.hd ? VideoQuality.sd : VideoQuality.hd),
          'setQualitySd' => () => setVideoQuality(VideoQuality.sd),
          'setQualityHd' => () => setVideoQuality(VideoQuality.hd),
          'rebindVideo' => rebindVideo,
          _ => null,
        };
        if (operation != null) {
          // The public state reports sanitized failures from these operations.
          unawaited(operation().catchError((Object _) {}));
          return;
        }
      }
      switch (action) {
        case 'refreshToken':
          if (canRefreshToken) {
            unawaited(onRefreshToken!().catchError((Object _) {}));
          }
        case 'swapVideo':
          swapVideo();
        case 'toggleOrientation':
          toggleOrientation();
        case 'restore':
          restore();
        case 'minimize':
          minimize();
        case 'hangup':
          if (failure?.recovery != CallRecovery.restartRequired) {
            unawaited(hangup(userInitiated: true));
          }
      }
      return;
    }
    if (_probe || !_nativeJoinRequested || _phase == CallPhase.ending) return;
    final uid = event['uid'];
    if (_expectedPeer != null &&
        const {'remoteJoined', 'remoteLeft', 'remoteVideo', 'remoteVideoStats'}
            .contains(type) &&
        uid != _expectedPeer) {
      return;
    }
    if (type == 'networkQuality') {
      final local = uid == 0;
      if (!local && (uid == null || uid != _remoteUid)) {
        return;
      }
      final tx = event['txQuality'], rx = event['rxQuality'];
      if (tx is! int || rx is! int) return;
      final weak = (tx >= 3 && tx <= 6) || (rx >= 3 && rx <= 6);
      if (local ? localWeak == weak : remoteWeak == weak) return;
      if (local) {
        localWeak = weak;
      } else {
        remoteWeak = weak;
      }
      _notify();
      return;
    }
    if (type == 'mediaTrackState') {
      final track =
          MediaTrack.values.where((t) => t.name == event['track']).firstOrNull;
      final value = event['state'], reason = event['reason'];
      if (track == null || value is! int || reason is! int) return;
      final remote = track == MediaTrack.remoteVideo;
      if (remote && (uid == null || uid != _remoteUid)) return;
      final activity = switch (value) {
        0 => TrackActivity.stopped,
        1 => TrackActivity.starting,
        2 => TrackActivity.active,
        3 => remote ? TrackActivity.frozen : TrackActivity.failed,
        4 when remote => TrackActivity.failed,
        _ => null,
      };
      if (activity == null) return;
      final last = trackStates[track];
      if (last?.activity == activity && last?.reason == reason) return;
      trackStates[track] = TrackObservation(activity, reason);
      if (remote &&
          (activity == TrackActivity.stopped ||
              activity == TrackActivity.failed)) {
        _remoteVideo = false;
        if (_phase == CallPhase.connected) _phase = CallPhase.connecting;
      }
      _notify();
      return;
    }
    if (type == 'audioRoute') {
      final route =
          AudioRoute.values.where((r) => r.name == event['route']).firstOrNull;
      if (route == null || route == audioRoute) return;
      audioRoute = route;
      _notify();
      return;
    }
    if (type == 'videoBindingError' || type == 'videoBound') {
      final role =
          VideoRole.values.where((r) => r.name == event['role']).firstOrNull;
      if (role == null) return;
      if (type == 'videoBindingError') {
        final details = event['details'];
        final code = details is Map ? details['sdkCode'] : null;
        _record(CallStage.videoBindingFailed,
            code: code is int ? code : null, role: role);
        if (!bindingFailures.add(role)) return;
      } else {
        if (!bindingFailures.remove(role)) return;
        if (bindingFailures.isEmpty &&
            _failure?.operation == CallOperation.rebindVideo) {
          _failure = null;
        }
      }
      _notify();
      return;
    }
    // Some native SDKs render again after a peer rejoins without repeating the
    // first-frame callback. Require actual rendering from the selected peer;
    // packet receipt/decoding alone must not claim a visible video window.
    final activity = trackStates[MediaTrack.remoteVideo]?.activity;
    if ((type == 'remoteVideoStats' || type == 'remoteVideo') &&
        (activity == TrackActivity.stopped ||
            activity == TrackActivity.failed)) {
      return;
    }
    if (type == 'remoteVideoStats') {
      final rendered = event['rendererOutputFrameRate'];
      if (_phase != CallPhase.connecting ||
          _remoteUid == null ||
          uid != _remoteUid ||
          rendered is! int ||
          rendered <= 0) {
        return;
      }
      _record(CallStage.firstRemoteFrame);
      _remoteVideo = true;
      _phase = CallPhase.connected;
      if (kDebugMode) {
        _diagnostic = 'RTC remoteVideo recoveredByRenderStats';
        debugPrint(_diagnostic);
      }
      _notify();
      return;
    }
    if (kDebugMode) {
      final diagnostic = rtcDiagnostic(event);
      if (diagnostic != null) {
        _diagnostic = diagnostic;
        debugPrint(diagnostic);
      }
    }
    switch (event['type']) {
      case 'joined':
        _record(CallStage.joined);
        connectionState = RtcConnectionState.connected;
        _joined = true;
        _joinTimer?.cancel();
        if (_remoteUid == null) _phase = CallPhase.waiting;
      case 'remoteJoined':
        if (uid is int &&
            uid > 0 &&
            (_remoteUid == null || _remoteUid == uid)) {
          _remoteUid = uid;
          _session!.firstPeerAt ??= _session!.clock.elapsed;
          if (!_remoteVideo) _phase = CallPhase.connecting;
        }
      case 'remoteVideo':
        if (uid is int &&
            uid > 0 &&
            (_remoteUid == null || _remoteUid == uid)) {
          if (!_remoteVideo) _record(CallStage.firstRemoteFrame);
          _remoteUid = uid;
          _remoteVideo = true;
          _session!.firstPeerAt ??= _session!.clock.elapsed;
          _phase = CallPhase.connected;
        }
      case 'remoteLeft':
        if (uid is int && uid == _remoteUid) {
          _remoteUid = null;
          remoteWeak = false;
          trackStates.remove(MediaTrack.remoteVideo);
          bindingFailures.remove(VideoRole.remote);
          _remoteVideo = false;
          _phase = CallPhase.waiting;
        }
      case 'connection':
        switch (event['state']) {
          case 'connecting':
            connectionState = RtcConnectionState.connecting;
          case 'reconnecting':
            connectionState = RtcConnectionState.reconnecting;
            _phase = CallPhase.reconnecting;
          case 'connected':
            connectionState = RtcConnectionState.connected;
            _joined = true;
            _joinTimer?.cancel();
            _phase = _remoteVideo
                ? CallPhase.connected
                : (_remoteUid == null
                    ? CallPhase.waiting
                    : CallPhase.connecting);
          case 'failed':
            connectionState = RtcConnectionState.failed;
            _failure = _session!.terminalError = const CallException(
                CallErrorCode.connectionFailed,
                operation: CallOperation.event,
                recovery: CallRecovery.retryCall);
            unawaited(hangup(reason: CallEndReason.connectionFailed));
          case 'disconnected':
            connectionState = RtcConnectionState.disconnected;
            _phase = CallPhase.reconnecting;
        }
      case 'tokenRequired':
        _needsToken = true;
      case 'error':
        _failure = _session!.terminalError = callFailure(
            PlatformException(
                code: event['code'] is String
                    ? event['code'] as String
                    : 'sdkError',
                details: event['details'] is Map ? event['details'] : null),
            operation: CallOperation.event);
        unawaited(hangup(reason: CallEndReason.sdkError));
    }
    _notify();
  }

  Map<String, Object?>? _lastPresentation;
  void setFlutterCallFullscreen(bool fullscreen) {
    unawaited(transport.invoke('setFlutterCallFullscreen', {
      'fullscreen': fullscreen,
    }).then<void>((_) {}, onError: (Object _, StackTrace __) {
      _record(CallStage.presentationFailed);
    }));
  }

  void _syncPresentation() {
    final snapshot = <String, Object?>{
      'sessionId': sessionId,
      'mode': _mini ? 'mini' : 'full',
      'phase': _phase.name,
      'probe': _probe,
      'primaryVideo': primaryVideo.name,
      'canSwapVideo': canSwapVideo,
      'showsCallSurface': showsCallSurface,
      'awaitingAnswer': awaitingAnswer,
      'answeredMiniCard': answeredMiniCard,
      'previewMiniCard': previewMiniCard,
      'miniRemoteVideo': miniRemoteVideo,
      'businessState': businessState.name,
      'acceptedAtMs': acceptedAt?.millisecondsSinceEpoch,
      'queueLabel': queueLabel,
      'localAvatarPath': context?.request.localAvatarPath,
      'rotated': rotated,
      'canToggleOrientation': canToggleOrientation,
      'remoteVideo': remoteVideo,
      'audioRoute': audioRoute?.name,
      'localWeak': localWeak,
      'remoteWeak': remoteWeak,
      'restartRequired': failure?.recovery == CallRecovery.restartRequired,
      'canControl': controlsReady && !_controlBusy,
      'muted': muted,
      'cameraEnabled': cameraEnabled,
      'speaker': speakerActive,
      'needsToken': needsToken,
      'canRefreshToken': canRefreshToken,
      'quality': quality?.name,
      'bindingFailed': bindingFailures.isNotEmpty,
      'errorCode': failure?.code.name,
    };
    if (mapEquals(_lastPresentation, snapshot)) return;
    _lastPresentation = snapshot;
    // Sample the business clock once so the full and mini views start on the same tick.
    final durationMs = connectedDuration?.inMilliseconds;
    final miniDuration = miniElapsedDuration;
    final miniMs =
        miniDuration == null ? null : durationMs ?? miniDuration.inMilliseconds;
    // MethodChannel preserves send order; do not defer the initial waiting snapshot.
    unawaited(transport.invoke('updatePresentation', {
      ...snapshot,
      'connectedDurationMs': durationMs,
      'miniElapsedMs': miniMs,
    }).then<void>((_) {}, onError: (Object _, StackTrace __) {
      if (identical(_lastPresentation, snapshot)) {
        _lastPresentation = null;
        _record(CallStage.presentationFailed);
      }
    }));
  }

  void _notify() {
    if (nativeHost) _syncPresentation();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _joinTimer?.cancel();
    unawaited(_subscription.cancel());
    // App owner normally awaits hangup; this also covers engine/UI teardown.
    unawaited(hangup().whenComplete(() {
      _userActions.close();
      _ended.close();
      _diagnostics.close();
    }));
    super.dispose();
  }
}

class _CallSession {
  _CallSession(this.context, this.mediaOptions, this.waitForAdmission);
  final CallMediaOptions mediaOptions;
  final bool waitForAdmission;
  bool canAdmit = false;
  Future<CallStartResult>? admission;
  final CallContext context;
  final clock = Stopwatch()..start();
  final Stopwatch _businessClock = Stopwatch();
  DateTime? acceptedAt, endedAt;
  bool _hasSharedAcceptance = false;
  Duration _durationOffset = Duration.zero;
  Duration? get businessDuration =>
      acceptedAt == null ? null : _durationOffset + _businessClock.elapsed;

  // Only the first valid host timestamp can correct a local receipt-time fallback.
  // Subsequent time advances and the final summary use the same monotonic clock.
  bool recordAcceptance(DateTime? shared) {
    if (_hasSharedAcceptance || (acceptedAt != null && shared == null)) {
      return false;
    }
    final now = DateTime.now().toUtc();
    final anchor = shared?.toUtc();
    final valid = anchor != null && !anchor.isAfter(now);
    if (acceptedAt != null && !valid) return false;
    acceptedAt = valid ? anchor : now;
    _hasSharedAcceptance = valid;
    _durationOffset = now.difference(acceptedAt!) - _businessClock.elapsed;
    _businessClock.start();
    return true;
  }

  CallQueueState? queue;
  bool rotated = false;
  bool systemCallRinging = false;
  int ringGeneration = 0;
  bool flutterPaused = false;
  VideoRole? primaryVideo;
  Duration? firstPeerAt;
  Duration? finalMiniDuration;
  CallException? terminalError;
  void finishTiming() {
    endedAt ??= DateTime.now().toUtc();
    _businessClock.stop();
  }
}
