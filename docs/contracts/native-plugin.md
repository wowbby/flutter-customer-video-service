# Native plugin contract v1

Native implementations own `MethodChannel('customer_rtc')`, `EventChannel('customer_rtc/events')`, two PlatformView types `customer_rtc/web` and `customer_rtc/video`. All map keys strings. UI thread event delivery. No credentials in logs/events. Single active Flutter engine / one active call for this research app.

## Methods
- `getPlatformVersion` -> String (keep scaffold diagnostic).
- `getSystemCallState` takes an optional sessionId and returns idle, ringing, active or unknown. Passing a session ID starts observation for that call. A query without an ID reads the current state. `endSystemCallObservation` releases an observation for a cancelled preflight identified by its session ID. Joining during a confirmed system call returns `system_call_busy`.
- The event `systemCallState` carries sessionId and state. A ringing-to-idle transition preserves an established session and restores audio preferences. An active system call ends the RTC session and produces the business ending reason `systemCall`.
- `join` {sessionId:String, appId:String, channel:String, token:String, uid:int, expectedPeerUid?:int, cameraFacing?:front|rear, videoQuality?:sd|hd} -> null after permission, engine creation and SDK join request accepted, NOT media connected. Validate inputs; only one active/pending call. `uid` 1..4294967295. Each native implementation requests camera/mic at call time. Return PlatformException on permission denied, missing activity, SDK errors.
- `leave` {sessionId:String} -> `{releaseStatus:'released'|'releasedWithWarnings'}` after stopping preview/capture and disposing engine; idempotent and cancels pending permission/start for this session. Warnings mean a stop/unbind/leave step failed but final engine destruction completed. Destruction failure or unconfirmed completion throws `cleanup_failed`, retains ownership and blocks joins. iOS destroy returns void; its synchronous return is the completion boundary, not a fabricated SDK result code. Older session leave MUST NOT affect newer session. Reject new joins until cleanup complete. Invalidate callbacks before cleanup. The pending join must settle when canceled. Dart 0.2.0 `RtcTransport.invoke` returns `Future<Object?>`; a legacy null leave result remains compatible as released, while malformed results are unconfirmed.
- `setMuted` {sessionId, muted:bool}; `setCameraEnabled` {sessionId, enabled:bool}; `switchCamera` {sessionId}; `setSpeaker` {sessionId, enabled:bool}; `renewToken` {sessionId, token:String} -> null, validate active session and SDK return values.
- `webReply` {viewId:int, json:String} -> null; run `window.onNativeMessage(<JSON object>);` in that exact live WebView. json supplied by Dart jsonEncode, validate JSON before interpolation, ignore disposed view. No arbitrary eval exposed to H5.

## Events
Maps with `type:String`. RTC callbacks MUST carry sessionId captured for their own engine/call, never relabel an old callback with current session.
- `joined` {sessionId, uid:int}
- `remoteJoined` {sessionId, uid:int}; select the trusted expectedPeerUid when supplied, otherwise the first peer. Disable automatic subscriptions for both audio and video and subscribe exclusively to the selected peer.
- `remoteLeft` {sessionId, uid:int}; reset selected peer on native side.
- `remoteVideo` {sessionId, uid:int}: first rendered/decoded remote frame (not merely peer joined). Only selected peer.
- `remoteVideoStats` {sessionId, uid:int, rendererOutputFrameRate:int}: native SDK rendering statistics for the selected peer. A positive rendered frame rate can recover the waiting-video state after the peer rejoins without another first-frame callback. Zero, unknown peers, obsolete sessions and samples during reconnecting/ending do not establish video availability. Repeated samples do not notify H5 or rebuild the window.
- `connection` {sessionId, state:String, reason?:int}: connecting/connected/reconnecting/disconnected/failed; reason is the native SDK numeric connection-change reason.
- `tokenRequired` {sessionId}
- `error` {sessionId, code:String, message:String, details?:{sdkCode:int,operation:String,recovery:String}}: sanitize message (no credentials); the structured code is retained for host diagnostics, never raw SDK error text.
- `bridge` {viewId:int, message:String}: raw H5 JSON envelope, only from trusted local main document.
- `webReady` {viewId:int}: trusted page has loaded; Dart pushes snapshot.

## Native WebView
Creation params {html:String}; HTML bundled in host and loaded into local WebView (no arbitrary URL). Expose `window.CustomerBridge.postMessage(string)`.
Android JavascriptInterface / iOS WKScriptMessageHandler / OHOS JS proxy. Block external/top-level navigation and new windows, do not expose bridge to foreign frames. Never grant webpage camera/microphone: native RTC owns capture. Disable file/universal access where available; no mixed content. Dispose bridge and view on PlatformView dispose. Host uses `webReply` for event/callback delivery.

## Native Video PlatformView
Creation params {role:'local'|'remote', probe:bool}. `probe=true` displays a clearly labelled NATIVE placeholder without initializing Agora or asking camera permissions. `probe=false` creates actual SDK-compatible native render view.
Persist video view identity through resize/fullscreen changes. Register local/remote view objects in native engine owner; bind when engine or remote peer becomes available and when the view becomes available (either ordering). Unbind/cleanup on view dispose without leaving channel. Remote UID is tracked by native engine, not H5 or creation params. No raw video frame transfer through Dart.

## Business waiting and presentation

The host can create a waiting session before obtaining RTC credentials. No native join or media acquisition occurs until admission for that session ID. Camera/encoder options are resolved per call. The presentation payload can carry `localAvatarPath`, a host-resolved local image path. Native overlays render a personal fallback for a missing or unreadable image. H5 receives structured queue state and never receives the local path or credentials. For host-facing APIs and user-action/cleanup ordering see the [component guide](../../packages/customer_video_service/README.md).

## Host policy
Flutter owns CallManager, full/mini state, request deduplication and H5 replies. A visible native container can take over presentation in mixed-host mode. Credentials entered only on host config screen, memory only. Probe mode never claims real RTC connection. Entering background ends session; no background/PiP capability. App inactive alone (permission popup) does not end call.

Communication profile, default speaker enabled, local camera enabled and microphone unmuted. H5 enables actions after the first native state snapshot; it must not query before native document readiness. Unconfirmed native cleanup keeps the call blocked; persistent SDK destruction failures require an app restart. Native snake_case errors are mapped to an allowlist of shared safe codes in Dart.

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

Call diagnostics are an opt-in Dart stream of typed stages and elapsed times. The host can provide business context per trusted document via requestForCall. H5 v1 adds localWeak, remoteWeak, videoQuality and mediaReady; mediaReady means commands are available after join acknowledgement.

## Dart 0.2.0 and H5 v1 additions

`credentialsProvider(CallContext)` and `tokenProvider(CallContext, CallIdentity)` receive the same request context created before credential lookup. Context contains sessionId, startedAt and optional host-only CallRequest businessId/scene. These request fields never cross the native or H5 boundary. `startCall` returns CallStartResult with the original sessionId and accepted/cancelled status; acceptance only acknowledges the SDK request. Business acceptance is supplied by host signaling through guarded updateBusinessState/endCall calls, never by media callbacks or H5.

H5 v1 preserves startRtc/startProbe/getState/hangup/minimize/restore/openBusiness and existing response/snapshot fields. Successful startRtc adds a top-level `startResult:{sessionId,status}` next to the existing `result` snapshot, so a late cancelled request remains associated with its original session even when result describes a newer call. startProbe retains its response shape. H5 parameters cannot set business metadata or business acceptance, and no new remote URL permission is granted.

Snapshots add connectionState, businessState and lastSummary. The retained H5 summary includes only sessionId, startedAt, acceptedAt, endedAt, reason, durationMs, releaseStatus and errorCode. It excludes context, businessId, scene, RTC credentials and raw exceptions. Duration is null until business acceptance; accepted duration uses a monotonic clock. Confirmed release emits one ended event to Dart subscribers and retains lastSummary for reload/query; unconfirmed cleanup emits no successful ending and retains ownership.

The host may pass the same business acceptance instant to both clients through `acceptedAt`. The component normalizes it to UTC, accounts for elapsed time before receipt, then advances a monotonic clock. A missing or future timestamp falls back to local receipt time. The first valid shared timestamp can correct that fallback once. H5 exposes the active `acceptedAt` as an ISO timestamp. Native presentation snapshots carry `acceptedAtMs` as UTC epoch milliseconds and `connectedDurationMs` as the sampled business duration. Full and compact native windows use that duration and account for elapsed monotonic time since snapshot receipt. `miniElapsedMs` also supports RTC-only previews before a business answer.

CallException exposes safe code, operation, numeric vendorCode and recovery to the host. Both `sdk_<number>` and `agora_<number>` normalize to sdkError. The existing conservative policy of ending on an asynchronous SDK error event remains in this batch; fatal/recoverable classification requires a later SDK-specific error-table review. These additive contracts do not change the one-active-FlutterEngine restriction or the pinned native SDK versions.
