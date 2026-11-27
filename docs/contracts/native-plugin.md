# Native plugin contract v1

Native implementations own `MethodChannel('customer_rtc')`, `EventChannel('customer_rtc/events')`, the video PlatformView `customer_rtc/video`. All map keys strings. UI thread event delivery. No credentials in logs/events. Single active Flutter engine / one active call for this research app.

## Methods
- `getPlatformVersion` -> String (keep scaffold diagnostic).
- `getSystemCallState` takes an optional sessionId and returns idle, ringing, active or unknown. Passing a session ID starts observation for that call. A query without an ID reads the current state. `endSystemCallObservation` releases an observation for a cancelled preflight identified by its session ID. Joining during a confirmed system call returns `system_call_busy`.
- The event `systemCallState` carries sessionId and state. A ringing-to-idle transition preserves an established session and restores audio preferences. An active system call ends the RTC session and produces the business ending reason `systemCall`.
- `join` {sessionId:String, appId:String, channel:String, token:String, uid:int, expectedPeerUid?:int, cameraFacing?:front|rear, videoQuality?:sd|hd} -> null after permission, engine creation and SDK join request accepted, NOT media connected. Validate inputs; only one active/pending call. `uid` 1..4294967295. Each native implementation requests camera/mic at call time. Return PlatformException on permission denied, missing activity, SDK errors.
- `leave` {sessionId:String} -> `{releaseStatus:'released'|'releasedWithWarnings'}` after stopping preview/capture and disposing engine; idempotent and cancels pending permission/start for this session. Warnings mean a stop/unbind/leave step failed but final engine destruction completed. Destruction failure or unconfirmed completion throws `cleanup_failed`, retains ownership and blocks joins. iOS destroy returns void; its synchronous return is the completion boundary, not a fabricated SDK result code. Older session leave MUST NOT affect newer session. Reject new joins until cleanup complete. Invalidate callbacks before cleanup. The pending join must settle when canceled. Dart 0.2.0 `RtcTransport.invoke` returns `Future<Object?>`; a legacy null leave result remains compatible as released, while malformed results are unconfirmed.
- `setMuted` {sessionId, muted:bool}; `setCameraEnabled` {sessionId, enabled:bool}; `switchCamera` {sessionId}; `setSpeaker` {sessionId, enabled:bool}; `renewToken` {sessionId, token:String} -> null, validate active session and SDK return values.

## Events
Maps with `type:String`. RTC callbacks MUST carry sessionId captured for their own engine/call, never relabel an old callback with current session.
- `joined` {sessionId, uid:int}
- `remoteJoined` {sessionId, uid:int}; select the trusted expectedPeerUid when supplied, otherwise the first peer. Disable automatic subscriptions for both audio and video and subscribe exclusively to the selected peer.
- `remoteLeft` {sessionId, uid:int}; reset selected peer on native side.
- `remoteVideo` {sessionId, uid:int}: first rendered/decoded remote frame (not merely peer joined). Only selected peer.
- `remoteVideoStats` {sessionId, uid:int, rendererOutputFrameRate:int}: native SDK rendering statistics for the selected peer. A positive rendered frame rate can recover the waiting-video state after the peer rejoins without another first-frame callback. Zero, unknown peers, obsolete sessions and samples during reconnecting/ending do not establish video availability. Repeated samples leave the displayed state unchanged.
- `connection` {sessionId, state:String, reason?:int}: connecting/connected/reconnecting/disconnected/failed; reason is the native SDK numeric connection-change reason.
- `tokenRequired` {sessionId}
- `error` {sessionId, code:String, message:String, details?:{sdkCode:int,operation:String,recovery:String}}: sanitize message (no credentials); the structured code is retained for host diagnostics, never raw SDK error text.

## Native Video PlatformView
Creation params {role:'local'|'remote', probe:bool}. `probe=true` displays a clearly labelled NATIVE placeholder without initializing Agora or asking camera permissions. `probe=false` creates actual SDK-compatible native render view.
Persist video view identity through resize/fullscreen changes. Register local/remote view objects in native engine owner; bind when engine or remote peer becomes available and when the view becomes available (either ordering). Unbind/cleanup on view dispose without leaving channel. The native engine tracks the remote UID. No raw video frame transfer through Dart.

## Business waiting and presentation

The host can create a waiting session before obtaining RTC credentials. No native join or media acquisition occurs until admission for that session ID. Camera/encoder options are resolved per call. The presentation payload can carry `localAvatarPath`, a host-resolved local image path. Native overlays render a personal fallback for a missing or unreadable image. The host reads typed queue state from the controller. For host-facing APIs and user-action/cleanup ordering see the [component guide](../../packages/customer_video_service/README.md).

## Host policy
Flutter owns CallManager and the full/mini window state. The host owns its WebView, JSBridge and business routing. A visible native container can take over presentation in mixed-host mode. The host supplies short-lived call credentials. Probe mode never claims real RTC connection. Entering background ends session; no background/PiP capability. App inactive alone (permission popup) does not end call.

Communication profile, default speaker enabled, local camera enabled and microphone unmuted. Unconfirmed native cleanup keeps the call blocked; persistent SDK destruction failures require an app restart. Native snake_case errors are mapped to an allowlist of shared safe codes in Dart.

Debug snapshots optionally include `diagnostic`: only allowlisted event/state labels and numeric SDK codes. Never expose raw native messages, credentials or arbitrary error details. Release snapshots omit this field. Current native errors carry numeric sdkCode and safe operation/recovery fields; legacy initialization stage/exception-type fields remain allowlist-filtered when supplied by older adapters.

## Mixed host and media contract (0.3.0)

The active FlutterEngine owns one session. In mixed mode the visible host renders that session. An attachment change moves the canvas to the visible container. Early permission cancellation, late callbacks and release completion retain their original session identity. A subsequent engine must wait for a previous asynchronous SDK destruction to finish. An unconfirmed destruction blocks new engine creation in that process.

| Direction | Method or event | Contract |
| --- | --- | --- |
| Dart → native | `updatePresentation` | App-local snapshot with sessionId (null clears), phase, mode, probe, primaryVideo, control availability, media settings, token renewal (needsToken and canRefreshToken), binding/restart/error and weak-network flags. Accept presentation while credentials are pending, before join. |
| Native → Dart | `presentationAction` | sessionId and action: restore, minimize, hangup, toggleMuted, toggleCamera, switchCamera, toggleSpeaker, toggleQuality, rebindVideo or refreshToken. Offer refreshToken when canRefreshToken is true. Media controls require native join acknowledgement. |
| Native → Dart | `hostBackground` | End this session when the owning App goes to background. Preserve the interrupted session across late snapshot or event subscription and a quick return to foreground. A native join interrupted by background returns host_background, so an earlier method reply still yields a cancelled start and background end reason. |
| Dart → native | `setVideoQuality`, `rebindVideo` | Same active sessionId, quality sd/hd for the encoder change. Rebind uses existing SDK and live views. |
| Native → Dart | `videoBindingError`, `videoBound` | Role local/remote, sessionId and optional numeric sdkCode in details on failure. An isolated binding failure allows retry with the call still active. |
| Native → Dart | `networkQuality` | sessionId, uid (0 for local), txQuality and rxQuality. Only local and selected peer samples apply. |
| Native → Dart | `audioRoute` | sessionId and observed route speaker, earpiece, wired, bluetooth or other. State starts unknown. |
| Native → Dart | `mediaTrackState` | sessionId, track localAudio/localVideo/remoteVideo, numeric SDK state/reason, peer uid for remoteVideo. Stopped or failed remote video invalidates displayed readiness until the track resumes and a frame/rendering sample arrives. |

Call diagnostics are an opt-in Dart stream of typed stages and elapsed times.

## Dart session contract

Pass a CallRequest when starting or staging a call. Its CallContext is shared by the credentials and token providers. A CallStartResult acknowledges the original SDK join request. The host signals business acceptance and remote termination through `updateBusinessState` and `endCall` with the correct session ID.

The controller exposes typed business and connection state, queue information and the latest CallSummary. Duration is null until business acceptance. Confirmed release emits one ended event and retains the final summary. Unconfirmed cleanup keeps ownership so the host can retry.

When the host supplies a valid optional `acceptedAt`, the component normalizes it to UTC and accounts for elapsed time before receipt. A missing or future timestamp uses local receipt time. The first valid shared timestamp can correct a local fallback. The native presentation snapshot carries `acceptedAtMs` and the sampled `connectedDurationMs`. Both windows advance the sample with a monotonic clock until termination. `miniElapsedMs` also supports media-only previews before a business answer.

CallException exposes safe code, operation, numeric vendorCode and recovery to the host. Both `sdk_<number>` and `agora_<number>` normalize to sdkError. The existing conservative policy of ending on an asynchronous SDK error event remains in this batch; fatal/recoverable classification requires a later SDK-specific error-table review. These additive contracts do not change the one-active-FlutterEngine restriction or the pinned native SDK versions.
