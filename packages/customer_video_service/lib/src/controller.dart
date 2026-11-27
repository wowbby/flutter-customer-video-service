import 'dart:async';
import 'package:customer_rtc/customer_rtc.dart';
import 'package:flutter/widgets.dart';
import 'call/call_manager.dart';
import 'call/session_notifier.dart';
import 'call/call_failure.dart';
import 'models.dart';

/// One controller belongs to one App/FlutterEngine, independently of its routes.
class VideoServiceController extends SessionNotifier
    with WidgetsBindingObserver {
  VideoServiceController(
      {CredentialsProvider? credentialsProvider,
      this.tokenProvider,
      this.allowProbe = false,
      bool mediaOnlyPreview = false,
      this.lifecycleSource = CallLifecycleSource.flutter,
      this.mediaOptions = const CallMediaOptions(),
      RtcTransport? transport,
      Duration joinTimeout = const Duration(seconds: 45),
      Duration credentialsTimeout = const Duration(seconds: 30)})
      : _credentialsProvider = credentialsProvider,
        _manager = CallManager(transport ?? NativeRtcClient(),
            joinTimeout: joinTimeout,
            credentialsTimeout: credentialsTimeout,
            mediaOptions: mediaOptions,
            mediaOnlyPreview: mediaOnlyPreview,
            nativeHost: lifecycleSource == CallLifecycleSource.nativeHost) {
    if (joinTimeout <= Duration.zero || credentialsTimeout <= Duration.zero) {
      _manager.dispose();
      throw ArgumentError('Timeouts must be positive');
    }
    if (tokenProvider != null) _manager.onRefreshToken = refreshToken;
    _manager.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }
  final CredentialsProvider? _credentialsProvider;

  /// Existing direct-call hosts can continue to use the configured provider.
  CredentialsProvider get credentialsProvider =>
      _credentialsProvider ??
      (_) async =>
          throw const CallException(CallErrorCode.invalidConfiguration);
  final TokenProvider? tokenProvider;
  final bool allowProbe;
  final CallLifecycleSource lifecycleSource;

  /// Used by the Flutter call host while its full-screen surface is mounted.
  /// Mixed hosts already receive the same transition in updatePresentation.
  void setFlutterCallFullscreen(bool fullscreen) {
    if (lifecycleSource == CallLifecycleSource.flutter) {
      _manager.setFlutterCallFullscreen(fullscreen);
    }
  }

  final CallMediaOptions mediaOptions;
  Stream<CallDiagnostic> get diagnostics => _manager.diagnostics;
  final CallManager _manager;
  bool _closing = false, _disposed = false;
  Future<void>? _shutdownFuture;
  Future<void>? _refreshFuture;
  String? _refreshSession, _autoRefreshSession;

  CallState get state => CallState(
        sessionId: _manager.sessionId,
        phase: _manager.phase,
        windowMode: _manager.isMini ? CallWindowMode.mini : CallWindowMode.full,
        probe: _manager.isProbe,
        media: CallMediaState(
            muted: _manager.muted,
            cameraEnabled: _manager.cameraEnabled,
            speaker: _manager.speaker,
            remoteUid: _manager.remoteUid,
            remoteVideo: _manager.remoteVideo,
            controlsReady: _manager.controlsReady,
            localWeak: _manager.localWeak,
            remoteWeak: _manager.remoteWeak,
            quality: _manager.quality,
            bindingFailures: Set.unmodifiable(_manager.bindingFailures),
            trackStates: Map.unmodifiable(_manager.trackStates),
            audioRoute: _manager.audioRoute),
        needsToken: _manager.needsToken,
        controlBusy: _manager.controlBusy,
        error: _manager.failure,
        context: _manager.context,
        connectionState: _manager.connectionState,
        businessState: _manager.businessState,
        acceptedAt: _manager.acceptedAt,
        queue: _manager.queue,
        systemCallRinging: _manager.systemCallRinging,
        lastSummary: _manager.lastSummary,
        endReason: _manager.endReason,
        diagnostic: _manager.diagnostic,
      );
  String? get localAvatarPath => _manager.context?.request.localAvatarPath;
  Stream<CallUserAction> get userActions => _manager.userActions;
  Stream<CallSummary> get ended => _manager.ended;

  /// Active business call time, measured from the host's acceptance signal.
  Duration? get connectedDuration => _manager.connectedDuration;
  bool get showsCallSurface => _manager.showsCallSurface;

  /// An unanswered service call that can display the compact waiting card.
  bool get awaitingAnswer => _manager.awaitingAnswer;
  bool get answeredMiniCard => _manager.answeredMiniCard;
  bool get previewMiniCard => _manager.previewMiniCard;
  Duration? get miniElapsedDuration => _manager.miniElapsedDuration;
  bool get miniRemoteVideo => _manager.miniRemoteVideo;
  String? get queueLabel => _manager.queueLabel;
  bool get callViewRotated => _manager.rotated;
  bool get canToggleOrientation => _manager.canToggleOrientation;
  VideoRole get primaryVideo => _manager.primaryVideo;
  bool get canSwapVideo => _manager.canSwapVideo;
  void swapVideo() {
    _checkOpen();
    _manager.swapVideo();
  }

  Future<void> toggleCallOrientation() async {
    _checkOpen();
    _manager.toggleOrientation();
  }

  /// Either field may be omitted. Pass neither to clear the queue display.
  void updateQueue(
      {required String sessionId, int? peopleAhead, Duration? estimatedWait}) {
    _checkOpen();
    _manager.updateQueue(
        sessionId: sessionId,
        peopleAhead: peopleAhead,
        estimatedWait: estimatedWait);
  }

  void updateBusinessState(
      {required String sessionId,
      required CallBusinessState state,
      DateTime? acceptedAt}) {
    _checkOpen();
    _manager.updateBusinessState(
        sessionId: sessionId, state: state, acceptedAt: acceptedAt);
  }

  /// Use before acknowledging an incoming invitation to the host service.
  /// A platform without a readable call state still checks again at native join.
  Future<void> checkSystemCallAvailable() {
    _checkOpen();
    return _manager.checkSystemCallAvailable();
  }

  /// Accept an existing invitation after checking the system phone state.
  Future<void> acceptCall(
      {required String sessionId, DateTime? acceptedAt}) async {
    _checkOpen();
    await _manager.acceptCall(sessionId, acceptedAt: acceptedAt);
  }

  Future<void> endCall(
      {required String sessionId, required CallEndReason reason}) async {
    _checkOpen();
    await _manager.endCall(sessionId: sessionId, reason: reason);
    if (_manager.sessionId == sessionId) {
      throw _manager.failure ??
          const CallException(CallErrorCode.cleanupFailed);
    }
  }

  void _checkOpen() {
    if (_closing || _disposed) {
      throw const CallException(CallErrorCode.disposed);
    }
  }

  /// Creates the cancellable business window without starting RTC or a credential timer.
  Future<String> beginWaiting(
      {CallRequest request = const CallRequest()}) async {
    final result = await _start(false, request, waitForAdmission: true);
    if (result.status == CallStartStatus.cancelled) {
      throw const CallException(CallErrorCode.cancelled);
    }
    return result.sessionId;
  }

  /// Admit only the currently waiting call. Repeated admission shares its result.
  Future<CallStartResult> admit(
      {required String sessionId, required CallCredentials credentials}) {
    _checkOpen();
    return _manager.admit(sessionId, credentials);
  }

  /// Accepted means SDK request acceptance, never business acceptance or media.
  Future<CallStartResult> startCall(
          {CallRequest request = const CallRequest()}) =>
      _start(false, request);
  Future<void> startProbe() async {
    await _start(true, const CallRequest());
  }

  Future<CallStartResult> _start(bool probe, CallRequest request,
      {bool waitForAdmission = false}) async {
    _checkOpen();
    if (probe && !allowProbe) {
      throw const CallException(CallErrorCode.unsupported);
    }
    if (_manager.hasWindow) throw const CallException(CallErrorCode.busy);
    try {
      return await _manager.start(
          probe: probe,
          waitForAdmission: waitForAdmission,
          request: request,
          credentialsProvider: _credentialsProvider);
    } catch (error) {
      throw callFailure(error, operation: CallOperation.join);
    }
  }

  Future<void> hangup({CallEndReason reason = CallEndReason.user}) async {
    if (_disposed) return;
    final endingSession = _manager.sessionId;
    await _manager.hangup(
        reason: reason, userInitiated: reason == CallEndReason.user);
    if (endingSession != null && _manager.sessionId == endingSession) {
      throw _manager.failure ??
          const CallException(CallErrorCode.cleanupFailed);
    }
  }

  void minimize() {
    _checkOpen();
    _manager.minimize();
  }

  void restore() {
    _checkOpen();
    _manager.restore();
  }

  Future<void> _control(Future<void> Function() action) async {
    _checkOpen();
    try {
      await action();
    } on CallException {
      rethrow;
    } catch (error) {
      throw callFailure(error, operation: CallOperation.event);
    }
  }

  Future<void> setMuted(bool value) => _control(() => _manager.setMuted(value));
  Future<void> setCameraEnabled(bool value) =>
      _control(() => _manager.setCameraEnabled(value));
  Future<void> setSpeaker(bool value) =>
      _control(() => _manager.setSpeaker(value));

  /// Uses the observed audio route when the OS changes the output device.
  bool get speakerActive => _manager.speakerActive;
  Future<void> toggleSpeaker() => _control(_manager.toggleSpeaker);
  bool get canRefreshToken => _manager.canRefreshToken;
  Future<void> switchCamera() => _control(_manager.switchCamera);

  Future<void> setVideoQuality(VideoQuality quality) =>
      _control(() => _manager.setVideoQuality(quality));
  Future<void> retryVideoBinding() => _control(_manager.rebindVideo);

  Future<void> refreshToken() {
    _checkOpen();
    final session = _manager.sessionId;
    final identity = _manager.identity;
    final context = _manager.context;
    final provider = tokenProvider;
    if (session == null ||
        identity == null ||
        context == null ||
        _manager.phase == CallPhase.ending) {
      return Future.error(const CallException(CallErrorCode.notInitialized));
    }
    if (provider == null) {
      return Future.error(const CallException(CallErrorCode.unsupported));
    }
    if (_refreshSession == session && _refreshFuture != null) {
      return _refreshFuture!;
    }
    _refreshSession = session;
    final completer = Completer<void>();
    _refreshFuture = completer.future;
    _manager.tokenRefreshStarted();
    () async {
      try {
        final token = await provider(context, identity)
            .timeout(const Duration(seconds: 30));
        if (_disposed ||
            _closing ||
            _manager.sessionId != session ||
            _manager.phase == CallPhase.ending) {
          completer.complete();
          return;
        }
        await _manager.renewToken(token);
        completer.complete();
      } catch (_) {
        if (!_disposed &&
            !_closing &&
            _manager.sessionId == session &&
            _manager.phase != CallPhase.ending) {
          _manager.tokenRefreshFailed(session);
          completer.completeError(const CallException(
              CallErrorCode.tokenRefreshFailed,
              operation: CallOperation.renewToken,
              recovery: CallRecovery.retryOperation));
        } else {
          completer.complete();
        }
      } finally {
        if (_refreshSession == session) {
          _refreshSession = null;
          _refreshFuture = null;
        }
      }
    }();
    return completer.future;
  }

  void _changed() {
    if (_disposed) return;
    final id = _manager.sessionId;
    if (!_manager.needsToken) _autoRefreshSession = null;
    if (!_closing &&
        _manager.needsToken &&
        tokenProvider != null &&
        id != null &&
        _autoRefreshSession != id) {
      _autoRefreshSession = id;
      scheduleMicrotask(() {
        if (_disposed ||
            _closing ||
            _manager.sessionId != id ||
            _manager.phase == CallPhase.ending) {
          return;
        }
        unawaited(refreshToken().catchError((Object _) {}));
      });
    }
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_disposed && lifecycleSource == CallLifecycleSource.flutter) {
      if (state == AppLifecycleState.resumed) _manager.flutterResumed();
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        unawaited(_manager
            .handleFlutterBackground(
                detached: state == AppLifecycleState.detached)
            .catchError((Object _) {}));
      }
    }
  }

  /// Await before destroying the FlutterEngine/logging out. Retry on cleanup failure.
  Future<void> shutdown() {
    if (_disposed) return Future.value();
    if (_shutdownFuture != null) return _shutdownFuture!;
    _closing = true;
    final completer = Completer<void>();
    _shutdownFuture = completer.future;
    () async {
      try {
        await hangup(reason: CallEndReason.shutdown);
        WidgetsBinding.instance.removeObserver(this);
        completer.complete();
      } catch (error) {
        completer.completeError(error);
      } finally {
        _shutdownFuture = null;
      }
    }();
    return completer.future;
  }

  /// Best-effort fallback only. Owners should await shutdown before dispose.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    _manager.removeListener(_changed);
    _manager.dispose();
    super.dispose();
  }
}
