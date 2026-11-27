import 'package:flutter/foundation.dart';

typedef CredentialsProvider = Future<CallCredentials> Function(
    CallContext context);
typedef TokenProvider = Future<String> Function(
    CallContext context, CallIdentity identity);

/// Host metadata for a call. Never forwarded to native SDKs or the H5 bridge.
@immutable
class CallRequest {
  const CallRequest(
      {this.businessId, this.scene, this.mediaOptions, this.localAvatarPath});

  final String? businessId;
  final String? scene;
  final CallMediaOptions? mediaOptions;

  /// Absolute app-local file path resolved by the trusted host.
  final String? localAvatarPath;

  void validate() {
    final path = localAvatarPath;
    if (path != null &&
        (!path.startsWith('/') ||
            path.startsWith('//') ||
            path.contains(String.fromCharCode(0)))) {
      throw ArgumentError('Invalid local avatar file path');
    }
    for (final value in [businessId, scene]) {
      if (value != null && (value.trim().isEmpty || value.runes.length > 128)) {
        throw ArgumentError('Invalid call request');
      }
    }
  }
}

/// Created before fetching credentials and retained for the entire call.
@immutable
class CallContext {
  const CallContext({
    required this.sessionId,
    required this.request,
    required this.startedAt,
  });

  final String sessionId;
  final CallRequest request;
  final DateTime startedAt;
}

/// Acceptance means the SDK accepted the start, not that a remote party answered.
enum CallStartStatus { accepted, cancelled }

@immutable
class CallStartResult {
  const CallStartResult({required this.sessionId, required this.status});

  final String sessionId;
  final CallStartStatus status;
}

@immutable
class CallIdentity {
  const CallIdentity(
      {required this.appId, required this.channel, required this.uid});
  final String appId;
  final String channel;
  final int uid;
}

@immutable
class CallCredentials extends CallIdentity {
  const CallCredentials(
      {required super.appId,
      required super.channel,
      required super.uid,
      required this.token,
      this.expectedPeerUid});

  /// Trusted remote identity supplied with the credentials.
  final int? expectedPeerUid;
  final String token;
  void validate() {
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(appId.trim()) ||
        !RegExp(r'^[a-zA-Z0-9_ -]{1,64}$').hasMatch(channel.trim()) ||
        token.trim().isEmpty ||
        uid < 1 ||
        uid > 4294967295 ||
        (expectedPeerUid != null &&
            (expectedPeerUid! <= 0 ||
                expectedPeerUid! > 4294967295 ||
                expectedPeerUid == uid))) {
      throw ArgumentError('Invalid RTC credentials');
    }
  }

  CallIdentity get identity =>
      CallIdentity(appId: appId.trim(), channel: channel.trim(), uid: uid);
}

enum CallPhase {
  idle,
  probe,
  joining,
  waiting,
  connecting,
  connected,
  reconnecting,
  ending
}

enum CallLifecycleSource { flutter, nativeHost }

enum MediaTrack { localAudio, localVideo, remoteVideo }

enum TrackActivity { stopped, starting, active, frozen, failed }

@immutable
class TrackObservation {
  const TrackObservation(this.activity, this.reason);
  final TrackActivity activity;
  final int reason;
}

enum CameraFacing { front, rear }

enum VideoQuality { sd, hd }

enum VideoRole { local, remote }

enum AudioRoute { speaker, earpiece, wired, bluetooth, other }

@immutable
class CallMediaOptions {
  const CallMediaOptions(
      {this.cameraFacing, this.videoQuality, VideoRole? primaryVideo})
      : _primaryVideo = primaryVideo;
  final CameraFacing? cameraFacing;

  /// Null preserves the SDK's default encoder settings.
  final VideoQuality? videoQuality;
  final VideoRole? _primaryVideo;
  VideoRole get primaryVideo => _primaryVideo ?? VideoRole.remote;

  CallMediaOptions withDefaults(CallMediaOptions defaults) => CallMediaOptions(
      cameraFacing: cameraFacing ?? defaults.cameraFacing,
      videoQuality: videoQuality ?? defaults.videoQuality,
      primaryVideo: _primaryVideo ?? defaults.primaryVideo);
}

enum CallStage {
  requested,
  credentialsReady,
  joinAccepted,
  joined,
  firstRemoteFrame,
  videoBindingFailed,
  tokenRenewed,
  ending,
  released,
  presentationFailed
}

@immutable
class CallDiagnostic {
  const CallDiagnostic(this.sessionId, this.stage, this.elapsed,
      {this.vendorCode, this.role});
  final String sessionId;
  final CallStage stage;
  final Duration elapsed;
  final int? vendorCode;
  final VideoRole? role;
}

enum CallWindowMode { full, mini }

enum RtcConnectionState {
  idle,
  connecting,
  connected,
  reconnecting,
  disconnected,
  failed
}

/// Business acceptance is supplied by the host, never inferred from media.
enum CallBusinessState { none, requested, ringing, accepted, ended }

enum CallQueueStatus { unknown, none, queued }

@immutable
class CallQueueState {
  const CallQueueState.unknown()
      : status = CallQueueStatus.unknown,
        peopleAhead = null,
        estimatedWait = null;
  const CallQueueState._(this.status, this.peopleAhead, this.estimatedWait);
  factory CallQueueState.fromPosition(
      {int? peopleAhead, Duration? estimatedWait}) {
    if ((peopleAhead != null && peopleAhead < 0) ||
        (estimatedWait?.isNegative ?? false)) {
      throw const CallException(CallErrorCode.invalidArgument);
    }
    if (peopleAhead == 0) {
      return const CallQueueState._(CallQueueStatus.none, 0, Duration.zero);
    }
    if (peopleAhead == null && estimatedWait == null) {
      return const CallQueueState.unknown();
    }
    return CallQueueState._(CallQueueStatus.queued, peopleAhead,
        estimatedWait ?? Duration(minutes: peopleAhead! * 5));
  }
  final CallQueueStatus status;
  final int? peopleAhead;
  final Duration? estimatedWait;
  String? get label {
    if (status != CallQueueStatus.queued) return null;
    final parts = [
      if (peopleAhead != null) '前面还有$peopleAhead人',
      if (estimatedWait != null)
        '预计等待约${(estimatedWait!.inMicroseconds / Duration.microsecondsPerMinute).ceil()}分钟',
    ];
    return '排队中，${parts.join('，')}，请耐心等待…';
  }

  Map<String, Object?> toBridgeMap() => {
        'status': status.name,
        'peopleAhead': peopleAhead,
        'estimatedWaitMs': estimatedWait?.inMilliseconds
      };
}

enum CallUserActionKind { cancel, hangup }

@immutable
class CallUserAction {
  const CallUserAction(this.context, this.kind);
  final CallContext context;
  String get sessionId => context.sessionId;
  final CallUserActionKind kind;
}

enum CallEndReason {
  user,
  systemCall,
  background,
  shutdown,
  joinFailed,
  connectionFailed,
  sdkError,
  remote,
  rejected,
  noAnswer
}

enum ReleaseStatus { released, releasedWithWarnings, releaseUnconfirmed }

enum CallErrorCode {
  busy,
  systemCallBusy,
  permissionDenied,
  invalidArgument,
  invalidConfiguration,
  notInitialized,
  cancelled,
  sdkError,
  missingActivity,
  unsupported,
  cleanupFailed,
  nativeError,
  operationFailed,
  bridgeUnavailable,
  timeout,
  joinTimeout,
  credentialsFailed,
  tokenRefreshFailed,
  connectionFailed,
  disposed
}

enum CallOperation {
  credentials,
  join,
  leave,
  setMuted,
  setCameraEnabled,
  setSpeaker,
  switchCamera,
  renewToken,
  setVideoQuality,
  rebindVideo,
  event
}

enum CallRecovery { none, retryOperation, retryCall, restartRequired }

@immutable
class CallException implements Exception {
  static const systemCallBusyMessage = '当前正在通话，请结束后再试';
  const CallException(
    this.code, {
    this.operation,
    this.vendorCode,
    this.recovery = CallRecovery.none,
  });

  final CallErrorCode code;
  final CallOperation? operation;
  final int? vendorCode;
  final CallRecovery recovery;

  @override
  String toString() => 'CallException(${code.name})';
}

@immutable
class CallSummary {
  const CallSummary({
    required this.context,
    this.acceptedAt,
    required this.endedAt,
    this.duration,
    required this.reason,
    required this.releaseStatus,
    this.error,
  });

  final CallContext context;
  final DateTime? acceptedAt;
  final DateTime endedAt;

  /// Business duration seeded from the shared acceptance timestamp when supplied,
  /// then measured monotonically and frozen when ending starts.
  final Duration? duration;
  final CallEndReason reason;
  final ReleaseStatus releaseStatus;
  final CallException? error;

  /// Only public lifecycle fields cross the H5 boundary.
  Map<String, Object?> toBridgeMap() => {
        'sessionId': context.sessionId,
        'startedAt': context.startedAt.toUtc().toIso8601String(),
        'acceptedAt': acceptedAt?.toUtc().toIso8601String(),
        'endedAt': endedAt.toUtc().toIso8601String(),
        'durationMs': duration?.inMilliseconds,
        'reason': reason.name,
        'releaseStatus': releaseStatus.name,
        'errorCode': error?.code.name,
      };
}

@immutable
class CallMediaState {
  const CallMediaState(
      {required this.muted,
      required this.cameraEnabled,
      required this.speaker,
      required this.remoteUid,
      required this.remoteVideo,
      this.controlsReady = false,
      this.quality,
      this.audioRoute,
      this.localWeak = false,
      this.remoteWeak = false,
      this.trackStates = const {},
      this.bindingFailures = const {}});
  final bool muted, cameraEnabled, speaker, remoteVideo;
  final int? remoteUid;
  final bool controlsReady, localWeak, remoteWeak;
  final VideoQuality? quality;

  /// Observed by the SDK. Null until a route is reported.
  final AudioRoute? audioRoute;
  final Set<VideoRole> bindingFailures;
  final Map<MediaTrack, TrackObservation> trackStates;
}

@immutable
class CallState {
  const CallState(
      {required this.sessionId,
      required this.phase,
      required this.windowMode,
      required this.probe,
      required this.media,
      required this.needsToken,
      required this.controlBusy,
      this.error,
      this.endReason,
      this.diagnostic,
      this.context,
      this.connectionState = RtcConnectionState.idle,
      this.businessState = CallBusinessState.none,
      this.acceptedAt,
      this.systemCallRinging = false,
      this.queue,
      this.lastSummary});
  final String? sessionId;
  final CallPhase phase;
  final CallWindowMode windowMode;
  final bool probe, needsToken, controlBusy;
  final CallMediaState media;
  final CallException? error;
  final CallEndReason? endReason;
  final String? diagnostic;
  final CallContext? context;
  final RtcConnectionState connectionState;
  final CallBusinessState businessState;
  final DateTime? acceptedAt;
  final bool systemCallRinging;
  final CallQueueState? queue;
  final CallSummary? lastSummary;
  bool get hasWindow => sessionId != null;

  /// v1 H5 state is intentionally independent of credentials and native view IDs.
  Map<String, Object?> toBridgeMap() => {
        'sessionId': sessionId,
        'phase': phase.name,
        'mode': windowMode.name,
        'probe': probe,
        'muted': media.muted,
        'cameraEnabled': media.cameraEnabled,
        'speaker': media.speaker,
        'remoteUid': media.remoteUid,
        'remoteVideo': media.remoteVideo,
        'localWeak': media.localWeak,
        'remoteWeak': media.remoteWeak,
        'mediaReady': media.controlsReady,
        'videoQuality': media.quality?.name,
        'needsToken': needsToken,
        'errorCode': error?.code.name,
        'endReason': endReason?.name,
        'connectionState': connectionState.name,
        'businessState': businessState.name,
        'acceptedAt': acceptedAt?.toUtc().toIso8601String(),
        'systemCallRinging': systemCallRinging,
        'queue': queue?.toBridgeMap(),
        'lastSummary': lastSummary?.toBridgeMap(),
        if (kDebugMode) 'diagnostic': diagnostic,
      };
}
