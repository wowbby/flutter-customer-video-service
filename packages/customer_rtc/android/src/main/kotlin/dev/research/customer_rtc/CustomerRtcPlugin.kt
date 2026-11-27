package dev.research.customer_rtc

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.content.pm.ApplicationInfo
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.util.Log
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.Window
import android.widget.FrameLayout
import io.agora.rtc2.ChannelMediaOptions
import io.agora.rtc2.Constants
import io.agora.rtc2.IRtcEngineEventHandler
import io.agora.rtc2.RtcEngine
import io.agora.rtc2.RtcEngineConfig
import io.agora.rtc2.video.VideoCanvas
import io.agora.rtc2.video.CameraCapturerConfiguration
import io.agora.rtc2.video.VideoEncoderConfiguration
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/** One engine per call; platform views never own the engine's lifetime. */
class CustomerRtcPlugin() : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val main = Handler(Looper.getMainLooper())
    private var cleanup = Executors.newSingleThreadExecutor()
    private val gate = SessionGate()
    private var session: Session? = null
    private var engine: RtcEngine? = null
    private var permissionSession: Session? = null
    private var permissionCode = 4100
    private lateinit var audioVisibility: PhoneAudioVisibility
    private lateinit var phone: PhoneCallMonitor
    internal constructor(phone: PhoneCallMonitor) : this() { this.phone = phone }
    private var phonePermissionRequested = false
    private var phonePermissionRequest: Int? = null
    private val phonePermissionWaiters = mutableListOf<Pair<String, () -> Unit>>()
    private var preflightId: String? = null
    private var preflightState = PhoneCallState.UNKNOWN
    private var preflightRingDismissedAt = -1L
    private val pendingPhoneEnds = linkedSetOf<String>()
    private var hostStopped = false
    private var phoneBackgroundId: String? = null
    private var backgroundCheck: Runnable? = null
    private var cleaningId: String? = null
    private var lastReleasedId: String? = null
    private var lastReleaseStatus = "released"
    private val leaveWaiters = mutableListOf<MethodChannel.Result>()
    private val systemBars = CallSystemBars()
    private var flutterFullscreen = false
    private fun updateSystemBars() {
        val active = visiblePresentation()
        val full = flutterFullscreen || (active["sessionId"] is String && active["mode"] == "full")
        val window = if (hostRoot != null) nativeHostWindow else activityBinding?.activity?.window
        systemBars.showIn(if (full) window else null)
    }
    private var nativeHostWindow: Window? = null
    private var hostRoot: FrameLayout? = null
    private var hostWindow: NativeCallWindow? = null
    private var presentation: Map<*, *> = emptyMap<Any, Any>()
    private var presentationReceivedAtMs = 0L
    private val visibility = HostVisibility({ id ->
        val target = sink
        if (target != null) target.success(mapOf("type" to "hostBackground", "sessionId" to id))
        target != null
    }, { id ->
        if (session?.id == id) leave(id, null, background = true)
    })
    private fun visiblePresentation(): Map<*, *> =
        if (visibility.isInterrupted(presentation["sessionId"] as? String) && presentation["phase"] != "ending")
            emptyMap<Any, Any>() else presentation
    private var boundLocal: View? = null
    private var boundRemote: View? = null
    private var boundUid: Int? = null
    private val videos = linkedSetOf<NativeVideoView>()
    private val webs = mutableMapOf<Int, NativeWebView>()
    private data class Session(val id: String, val ticket: Any, val appId: String,
        val channel: String, var token: String, val uid: Int, var result: MethodChannel.Result?,
        val peer: PeerSubscription, val facing: String?, val quality: String?, val hostEpoch: Long, var requestCode: Int = 0, var ownsProcessEngine: Boolean = false) {
        var phoneState = PhoneCallState.UNKNOWN
        var lastDismissedRingAt = -1L
        val phoneAudio = PhoneAudioSettings()
        var captureRecoveryGeneration = 0
        var audioRestoreDeferred = false
        var route: String? = null
        val remote: Int? get() = peer.selected
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (cleanup.isShutdown) cleanup = Executors.newSingleThreadExecutor()
        context = binding.applicationContext
        phone = SystemPhoneCalls(context)
        audioVisibility = PhoneAudioVisibility(::resumeDeferredPhoneAudio)
        (context as? Application)?.registerActivityLifecycleCallbacks(audioVisibility)
        channel = MethodChannel(binding.binaryMessenger, "customer_rtc")
        channel.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "customer_rtc/events")
        events.setStreamHandler(this)
        binding.platformViewRegistry.registerViewFactory("customer_rtc/web", NativeWebFactory(this))
        binding.platformViewRegistry.registerViewFactory("customer_rtc/video", NativeVideoFactory(this))
    }
    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
        sink = eventSink
        pendingPhoneEnds.forEach { id ->
            emit(mapOf("type" to "systemCallState", "sessionId" to id, "state" to "active"))
        }
        pendingPhoneEnds.clear()
        visibility.replay()
    }
    override fun onCancel(arguments: Any?) { sink = null }
    internal fun emit(event: Map<String, Any>) { sink?.success(event) }
    private fun emit(s: Session, type: String, fields: Map<String, Any> = emptyMap()) {
        if (gate.isCurrent(s.ticket)) emit(mapOf("type" to type, "sessionId" to s.id) + fields)
    }
    private fun current(call: MethodCall): Session {
        val s = session
        require(s != null && s.id == call.argument<String>("sessionId") && gate.isCurrent(s.ticket)) { "No active session" }
        return s
    }
    private fun checked(code: Int) { if (code != 0) throw RtcOperationException(code) }
    private fun errorDetails(operation: String, recovery: String, sdkCode: Int? = null): Map<String, Any> {
        val safeOperation = if (operation in setOf("join", "leave", "setMuted", "setCameraEnabled",
                "switchCamera", "setSpeaker", "renewToken", "setVideoQuality", "rebindVideo", "event")) operation else "event"
        val details = mutableMapOf<String, Any>("operation" to safeOperation, "recovery" to recovery)
        if (sdkCode != null) details["sdkCode"] = sdkCode
        return details
    }
    private fun releaseResult(status: String) = mapOf("releaseStatus" to status)
    private fun string(call: MethodCall, name: String): String =
        requireNotNull(call.argument<String>(name)) { "Missing $name" }
    private fun bool(call: MethodCall, name: String): Boolean =
        requireNotNull(call.argument<Boolean>(name)) { "Missing $name" }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")
                "getSystemCallState" -> {
                    checkPhone(call.argument<String>("sessionId"), result)
                }
                "endSystemCallObservation" -> {
                    endPreflight(string(call, "sessionId"))
                    result.success(null)
                }
                "join" -> join(call, result)
                "leave" -> leave(string(call, "sessionId"), result)
                "setFlutterCallFullscreen" -> {
                    flutterFullscreen = bool(call, "fullscreen")
                    updateSystemBars()
                    result.success(null)
                }
                "updatePresentation" -> {
                    presentation = call.arguments as? Map<*, *> ?: throw IllegalArgumentException()
                    presentationReceivedAtMs = SystemClock.elapsedRealtime()
                    visibility.updatePresentation(presentation["sessionId"] as? String)
                    updateSystemBars()
                    hostWindow?.update(visiblePresentation(), presentationReceivedAtMs)
                    // Only a change in the selected output actually rebinds the SDK.
                    bindVideos()
                    result.success(null)
                }
                "rebindVideo" -> {
                    current(call)
                    bindVideos(force = true)?.let { throw it }
                    result.success(null)
                }
                "webReply" -> {
                    val id = requireNotNull(call.argument<Number>("viewId")).toInt()
                    webs[id]?.reply(string(call, "json"))
                    result.success(null)
                }
                "setMuted", "setCameraEnabled", "switchCamera", "setSpeaker", "setVideoQuality", "renewToken" -> {
                    val s = current(call)
                    val rtc = checkNotNull(engine) { "RTC is not ready" }
                    checked(when (call.method) {
                        "setMuted" -> s.phoneAudio.setMuted(bool(call, "muted"),
                            s.phoneState == PhoneCallState.RINGING || s.audioRestoreDeferred,
                            { rtc.enableLocalAudio(true) }, rtc::muteLocalAudioStream)
                        "setCameraEnabled" -> rtc.enableLocalVideo(bool(call, "enabled"))
                        "switchCamera" -> rtc.switchCamera()
                        "setVideoQuality" -> rtc.setVideoEncoderConfiguration(encoder(string(call, "quality")))
                        "setSpeaker" -> s.phoneAudio.setSpeaker(bool(call, "enabled"),
                            s.phoneState == PhoneCallState.RINGING, rtc::setEnableSpeakerphone)
                        else -> rtc.renewToken(string(call, "token").also { require(it.isNotBlank()) })
                    })
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            result.error("invalid_arguments", "Invalid or inactive call arguments", null)
        } catch (error: RtcOperationException) {
            result.error("sdkError", "Native RTC operation failed",
                errorDetails(call.method, "retryOperation", error.code))
        } catch (_: Exception) {
            result.error("rtc_error", "Native RTC operation failed", errorDetails(call.method, "retryOperation"))
        }
    }
    private fun join(call: MethodCall, result: MethodChannel.Result) {
        val id = string(call, "sessionId")
        val appId = string(call, "appId")
        val channelName = string(call, "channel")
        val token = string(call, "token")
        val uid = requireNotNull(call.argument<Number>("uid")).toLong()
        require(id.isNotBlank() && id.length <= 128 && appId.matches(Regex("[a-fA-F0-9]{32}")))
        require(channelName.isNotBlank() && channelName.toByteArray(Charsets.UTF_8).size <= 64)
        require(uid in 1..4294967295L)
        val expected = call.argument<Number>("expectedPeerUid")?.toLong()
        require(expected == null || expected in 1..4294967295L && expected != uid)
        val facing = call.argument<String>("cameraFacing")
        require(facing == null || facing == "front" || facing == "rear")
        val quality = call.argument<String>("videoQuality")
        require(quality == null || quality == "sd" || quality == "hd")
        if (preflightId != null && preflightId != id) {
            result.error("cancelled", "Call observation belongs to another session", null)
            return
        }
        if (phone.read().busy || preflightState.busy) {
            result.error("system_call_busy", "A system phone call is in progress", null)
            return
        }
        (if (hostStopped) "host_background" else visibility.joinBlockReason(id))?.let {
            result.error(it, "Call is no longer active in the foreground", null)
            return
        }
        val activity = activityBinding?.activity
        if (activity == null) { result.error("no_activity", "Activity unavailable", null); return }
        if (permissionSession != null) { result.error("busy", "Permission request still pending", null); return }
        val ticket = gate.begin(id)
        if (ticket == null) { result.error("busy", "Another call or cleanup is active", null); return }
        if (lastReleasedId == id) lastReleasedId = null
        val s = Session(id, ticket, appId, channelName, token, uid.toInt(), result, PeerSubscription(expected?.toInt()), facing, quality, visibility.epoch)
        session = s
        endPreflight(id)
        withPhonePermission(id) {
            if (!gate.isCurrent(ticket)) return@withPhonePermission
            phone.observe { state -> onPhoneState(s, state) }
            if (rejectBusyPhone(s)) return@withPhonePermission
            val currentActivity = activityBinding?.activity
            if (currentActivity == null) {
                s.result?.error("no_activity", "Activity unavailable", null)
                s.result = null
                leave(s.id, null)
            } else requestMediaPermissions(s, currentActivity)
        }
    }

    private fun checkPhone(id: String?, result: MethodChannel.Result) {
        val state = phone.read()
        if (id == null || session != null || state.busy) {
            result.success(state.wire)
            return
        }
        if (preflightId != id) {
            preflightId?.let(::endPreflight)
            preflightId = id
        }
        withPhonePermission(id) {
            if (preflightId != id || session != null) {
                result.success(PhoneCallState.UNKNOWN.wire)
                return@withPhonePermission
            }
            phone.observe { changed -> observePreflightState(id, changed) }
            preflightState = phone.read()
            result.success(preflightState.wire)
        }
    }

    private fun observePreflightState(id: String, changed: PhoneCallState) {
        if (preflightId != id || changed == PhoneCallState.UNKNOWN || preflightState == changed ||
            preflightState == PhoneCallState.ACTIVE) return
        if (changed.busy) {
            if (hostStopped) phoneBackgroundId = id
            clearBackgroundCheck()
        } else if (preflightState == PhoneCallState.RINGING) {
            preflightRingDismissedAt = SystemClock.elapsedRealtime()
        }
        preflightState = changed
        if (changed == PhoneCallState.ACTIVE && sink == null) pendingPhoneEnds.add(id)
        emit(mapOf("type" to "systemCallState", "sessionId" to id, "state" to changed.wire))
    }

    private fun endPreflight(id: String) {
        if (preflightId != id) return
        preflightId = null
        preflightRingDismissedAt = -1L
        if (phoneBackgroundId == id) phoneBackgroundId = null
        // Admission hands this same ID to the SDK. A pending ordinary-background check
        // must survive that handoff if the host briefly returned before the timer fired.
        if (session?.id != id) clearBackgroundCheck()
        preflightState = PhoneCallState.UNKNOWN
        phone.stop()
        finishPhoneWaiters(id)
    }

    private fun withPhonePermission(id: String, ready: () -> Unit) {
        if (phonePermissionRequest != null) {
            phonePermissionWaiters.add(id to ready)
            return
        }
        val activity = activityBinding?.activity
        if (phonePermissionRequested || !phone.needsPermission() || activity == null || hostStopped ||
            !activity.hasWindowFocus()) {
            ready()
            return
        }
        phonePermissionRequested = true
        phonePermissionWaiters.add(id to ready)
        val code = ++permissionCode
        phonePermissionRequest = code
        try {
            activity.requestPermissions(arrayOf(Manifest.permission.READ_PHONE_STATE), code)
        } catch (_: RuntimeException) {
            finishPhonePermission()
        }
    }

    private fun finishPhonePermission() {
        phonePermissionRequest = null
        finishPhoneWaiters()
    }

    private fun finishPhoneWaiters(id: String? = null) {
        val waiters = phonePermissionWaiters.filter { id == null || it.first == id }
        phonePermissionWaiters.removeAll(waiters.toSet())
        waiters.forEach { it.second() }
    }

    private fun rejectBusyPhone(s: Session): Boolean {
        val state = phone.read()
        if (!state.busy && !s.phoneState.busy) return false
        s.result?.error("system_call_busy", "A system phone call is in progress", null)
        s.result = null
        leave(s.id, null)
        return true
    }

    private fun requestMediaPermissions(s: Session, activity: Activity) {
        if (hasPermissions(activity)) start(s) else {
            permissionSession = s
            s.requestCode = ++permissionCode
            try {
                activity.requestPermissions(arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO), s.requestCode)
            } catch (_: Exception) {
                permissionSession = null
                s.result?.error("permission_failed", "Unable to request camera and microphone access", null)
                s.result = null
                leave(s.id, null)
            }
        }
    }
    private fun hasPermissions(activity: Activity) = Build.VERSION.SDK_INT < 23 ||
        arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO).all {
            activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray): Boolean {
        if (code == phonePermissionRequest) {
            finishPhonePermission()
            return true
        }
        val s = permissionSession ?: return false
        if (code != s.requestCode) return false
        permissionSession = null
        if (!gate.isCurrent(s.ticket)) return true
        val activity = activityBinding?.activity
        if (activity != null && hasPermissions(activity)) start(s) else {
            s.result?.error("permission_denied", "Camera and microphone permissions are required", null)
            s.result = null
            leave(s.id, null)
        }
        return true
    }
    private fun encoder(quality: String): VideoEncoderConfiguration {
        val size = when (quality) {
            "sd" -> VideoEncoderConfiguration.VD_640x360
            "hd" -> VideoEncoderConfiguration.VD_1280x720
            else -> throw IllegalArgumentException("Unknown video quality")
        }
        return VideoEncoderConfiguration(size, VideoEncoderConfiguration.FRAME_RATE.FRAME_RATE_FPS_15,
            VideoEncoderConfiguration.STANDARD_BITRATE, VideoEncoderConfiguration.ORIENTATION_MODE.ORIENTATION_MODE_ADAPTIVE)
    }
    private fun start(s: Session) {
        if (!gate.isCurrent(s.ticket)) return
        if (rejectBusyPhone(s)) return
        visibility.joinBlockReason(s.id, s.hostEpoch)?.let {
            s.result?.error(it, "Call is no longer active in the foreground", null)
            s.result = null
            leave(s.id, null)
            return
        }
        when (ProcessEngineGate.INSTANCE.acquire(s.ticket)) {
            ProcessEngineGate.Acquisition.BUSY -> {
                s.result?.error("busy", "Previous RTC engine still owns the SDK", null)
                s.result = null
                leave(s.id, null)
                return
            }
            ProcessEngineGate.Acquisition.RESTART_REQUIRED -> {
                s.result?.error("cleanup_failed", "Restart required to use the RTC engine",
                    errorDetails("join", "restartRequired"))
                s.result = null
                leave(s.id, null)
                return
            }
            ProcessEngineGate.Acquisition.GRANTED -> s.ownsProcessEngine = true
        }
        try {
            val config = RtcEngineConfig().apply {
                // RtcEngineConfig.getContext() otherwise shadows the plugin context in apply.
                mContext = this@CustomerRtcPlugin.context
                mAppId = s.appId
                mEventHandler = handler(s)
                mChannelProfile = Constants.CHANNEL_PROFILE_COMMUNICATION
                mLogConfig = RtcEngineConfig.LogConfig().apply { level = 0 }
            }
            val rtc = RtcEngine.create(config)
                ?: throw IllegalStateException("RTC engine creation failed")
            engine = rtc
            if (rejectBusyPhone(s)) return
            s.facing?.let {
                val direction = if (it == "rear") CameraCapturerConfiguration.CAMERA_DIRECTION.CAMERA_REAR
                    else CameraCapturerConfiguration.CAMERA_DIRECTION.CAMERA_FRONT
                checked(rtc.setCameraCapturerConfiguration(CameraCapturerConfiguration(direction)))
            }
            checked(rtc.enableVideo())
            s.quality?.let { checked(rtc.setVideoEncoderConfiguration(encoder(it))) }
            checked(rtc.enableAudio())
            checked(rtc.setDefaultAudioRoutetoSpeakerphone(true))
            bindVideos()
            if (rejectBusyPhone(s)) return
            checked(rtc.startPreview())
            val options = ChannelMediaOptions().apply {
                channelProfile = Constants.CHANNEL_PROFILE_COMMUNICATION
                clientRoleType = Constants.CLIENT_ROLE_BROADCASTER
                publishCameraTrack = true
                publishMicrophoneTrack = true
                autoSubscribeVideo = false
                autoSubscribeAudio = false
            }
            checked(rtc.joinChannel(s.token, s.channel, s.uid, options))
            s.token = ""
            s.result?.success(null)
            s.result = null
        } catch (error: Exception) {
            s.result?.error(if (error is RtcOperationException) "sdkError" else "rtc_join_failed",
                "Unable to initialize or join native RTC",
                errorDetails("join", "retryCall", (error as? RtcOperationException)?.code))
            s.result = null
            leave(s.id, null)
        }
    }
    private fun callback(s: Session, action: () -> Unit) { main.post { if (gate.isCurrent(s.ticket)) action() } }
    private fun unsigned(uid: Int) = uid.toLong() and 0xffffffffL
    // Debug-only numeric media telemetry; never log SDK objects, identities or credentials.
    private fun mediaDiagnostic(s: Session, message: String) {
        if (gate.isCurrent(s.ticket) && context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            Log.i("CustomerRtcDiag", message)
        }
    }
    private fun handler(s: Session) = object : IRtcEngineEventHandler() {
        override fun onRemoteVideoStateChanged(uid: Int, state: Int, reason: Int, elapsed: Int) = callback(s) {
            if (s.remote == uid) {
                mediaDiagnostic(s, "remoteState state=$state reason=$reason")
                emit(s, "mediaTrackState", mapOf("track" to "remoteVideo", "state" to state, "reason" to reason, "uid" to unsigned(uid)))
            }
        }
        override fun onLocalVideoStateChanged(source: Constants.VideoSourceType, state: Int, reason: Int) = callback(s) {
            if (source == Constants.VideoSourceType.VIDEO_SOURCE_CAMERA_PRIMARY)
                emit(s, "mediaTrackState", mapOf("track" to "localVideo", "state" to state, "reason" to reason))
        }
        override fun onLocalAudioStateChanged(state: Int, reason: Int) = callback(s) {
            s.phoneAudio.observeCapture(
                failed = state == Constants.LOCAL_AUDIO_STREAM_STATE_FAILED ||
                    reason == Constants.LOCAL_AUDIO_STREAM_REASON_DEVICE_BUSY ||
                    reason == Constants.LOCAL_AUDIO_STREAM_REASON_INTERRUPTED,
                recording = state == Constants.LOCAL_AUDIO_STREAM_STATE_RECORDING ||
                    state == Constants.LOCAL_AUDIO_STREAM_STATE_ENCODING)
            emit(s, "mediaTrackState", mapOf("track" to "localAudio", "state" to state, "reason" to reason))
        }
        override fun onLocalVideoStats(source: Constants.VideoSourceType, stats: LocalVideoStats) = callback(s) {
            mediaDiagnostic(s, "localStats capture=${stats.captureFrameRate} encode=${stats.encoderOutputFrameRate} send=${stats.sentFrameRate} kbps=${stats.sentBitrate} loss=${stats.txPacketLossRate}")
        }
        override fun onRemoteVideoStats(stats: RemoteVideoStats) = callback(s) {
            if (s.remote == stats.uid) {
                mediaDiagnostic(s, "remoteStats kbps=${stats.receivedBitrate} decode=${stats.decoderOutputFrameRate} render=${stats.rendererOutputFrameRate} loss=${stats.packetLossRate}")
                emit(s, "remoteVideoStats", mapOf("uid" to unsigned(stats.uid), "rendererOutputFrameRate" to stats.rendererOutputFrameRate))
            }
        }
        override fun onJoinChannelSuccess(channel: String?, uid: Int, elapsed: Int) = callback(s) {
            emit(s, "joined", mapOf("uid" to unsigned(uid)))
        }
        override fun onUserJoined(uid: Int, elapsed: Int) = callback(s) {
            val rtc = engine ?: return@callback
            val code = try {
                s.peer.join(uid, rtc::muteRemoteAudioStream, rtc::muteRemoteVideoStream) ?: return@callback
            } catch (_: RuntimeException) {
                null
            }
            if (code != 0) {
                emit(s, "error", mapOf("code" to "sdkError", "details" to errorDetails("event", "retryCall", code)))
                leave(s.id, null)
                return@callback
            }
            bindVideos()
            emit(s, "remoteJoined", mapOf("uid" to unsigned(uid)))
        }
        override fun onUserOffline(uid: Int, reason: Int) = callback(s) {
            if (s.remote == uid) {
                s.peer.left(uid)
                bindVideos()
                emit(s, "remoteLeft", mapOf("uid" to unsigned(uid)))
            }
        }
        override fun onFirstRemoteVideoFrame(uid: Int, width: Int, height: Int, elapsed: Int) = callback(s) {
            if (s.remote == uid) emit(s, "remoteVideo", mapOf("uid" to unsigned(uid)))
        }
        override fun onConnectionStateChanged(state: Int, reason: Int) = callback(s) {
            val name = when (state) {
                Constants.CONNECTION_STATE_CONNECTING -> "connecting"
                Constants.CONNECTION_STATE_CONNECTED -> "connected"
                Constants.CONNECTION_STATE_RECONNECTING -> "reconnecting"
                Constants.CONNECTION_STATE_FAILED -> "failed"
                else -> "disconnected"
            }
            emit(s, "connection", mapOf("state" to name, "reason" to reason))
        }
        override fun onNetworkQuality(uid: Int, txQuality: Int, rxQuality: Int) = callback(s) {
            if (uid == 0 || s.remote == uid) emit(s, "networkQuality", mapOf(
                "uid" to unsigned(uid), "txQuality" to txQuality, "rxQuality" to rxQuality))
        }
        override fun onAudioRouteChanged(routing: Int) = callback(s) {
            val route = when (routing) {
                Constants.AUDIO_ROUTE_HEADSET, Constants.AUDIO_ROUTE_HEADSETNOMIC,
                Constants.AUDIO_ROUTE_USB_HEADSET -> "wired"
                Constants.AUDIO_ROUTE_EARPIECE -> "earpiece"
                Constants.AUDIO_ROUTE_LOUDSPEAKER, Constants.AUDIO_ROUTE_SPEAKERPHONE -> "speaker"
                Constants.AUDIO_ROUTE_BLUETOOTH_DEVICE_HFP, Constants.AUDIO_ROUTE_BLUETOOTH_DEVICE_A2DP -> "bluetooth"
                else -> "other"
            }
            s.route = route
            emit(s, "audioRoute", mapOf("route" to route))
        }
        override fun onTokenPrivilegeWillExpire(token: String?) = callback(s) { emit(s, "tokenRequired") }
        override fun onRequestToken() = callback(s) { emit(s, "tokenRequired") }
        override fun onError(err: Int) = callback(s) {
            emit(s, "error", mapOf("code" to "sdkError", "message" to "Native RTC reported an error",
                "details" to errorDetails("event", "retryCall", err)))
        }
    }
    private fun leave(id: String, result: MethodChannel.Result?, background: Boolean = false) {
        endPreflight(id)
        if (gate.cleanupFailed(id)) {
            result?.error("cleanup_failed", "RTC cleanup failed; restart the app before calling again",
                errorDetails("leave", "restartRequired"))
            return
        }
        if (cleaningId == id) {
            if (result != null) leaveWaiters.add(result)
            return
        }
        val s = session
        if (s == null || !gate.close(id)) {
            result?.success(releaseResult(if (lastReleasedId == id) lastReleaseStatus else "released"))
            return
        }
        cleaningId = id
        if (result != null) leaveWaiters.add(result)
        phone.stop()
        phoneBackgroundId = null
        clearBackgroundCheck()
        session = null // Invalidate before native teardown or callbacks.
        finishPhoneWaiters(id)
        if (permissionSession === s) permissionSession = null
        s.token = ""
        s.result?.error(if (background) "host_background" else "cancelled", "Call was cancelled", null)
        s.result = null
        val rtc = engine
        engine = null
        boundLocal = null
        boundRemote = null
        boundUid = null
        cleanup.execute {
            val policy = CleanupPolicy()
            if (rtc != null) {
                policy.stop { rtc.stopPreview() }
                policy.stop { rtc.enableLocalVideo(false) }
                policy.stop { rtc.enableLocalAudio(false) }
                policy.stop { rtc.setupLocalVideo(VideoCanvas(null, VideoCanvas.RENDER_MODE_HIDDEN, 0)) }
                s.remote?.let { uid -> policy.stop { rtc.setupRemoteVideo(VideoCanvas(null, VideoCanvas.RENDER_MODE_HIDDEN, uid)) } }
                policy.stop { rtc.leaveChannel() }
            }
            if (s.ownsProcessEngine) {
                // Also clean up a partially failed create() before another plugin can take ownership.
                policy.destroy { RtcEngine.destroy() }
                ProcessEngineGate.INSTANCE.finish(s.ticket, policy.released())
            } else {
                policy.destroy {} // No process lease (e.g. permission or acquisition failure).
            }
            main.post {
                gate.cleaned(policy.released())
                cleaningId = null
                if (policy.released()) {
                    lastReleasedId = id
                    lastReleaseStatus = checkNotNull(policy.releaseStatus())
                }
                val waiters = leaveWaiters.toList()
                leaveWaiters.clear()
                waiters.forEach {
                    if (!policy.released()) it.error("cleanup_failed", "RTC cleanup remains unconfirmed",
                        errorDetails("leave", "restartRequired"))
                    else it.success(releaseResult(checkNotNull(policy.releaseStatus())))
                }
            }
        }
    }
    internal fun addVideo(view: NativeVideoView) { videos.add(view); bindVideos() }
    internal fun removeVideo(view: NativeVideoView) { videos.remove(view); bindVideos() }

    /** Mount into the foreground native page's topmost app-owned content FrameLayout. Main thread. */
    @JvmOverloads
    fun attachNativeHost(container: FrameLayout, window: Window? = container.context.hostActivity()?.window) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (hostRoot === container && nativeHostWindow === window) return
        hostWindow?.close()
        hostRoot = container
        nativeHostWindow = window
        updateSystemBars()
        // The app's content root may have consumed insets for its business UI. Mount the call
        // above that content, so its background and interactive controls can use different bounds.
        val surface = if (container === window?.findViewById<FrameLayout>(android.R.id.content))
            window.decorView as? FrameLayout ?: container else container
        hostWindow = NativeCallWindow(surface) { id, action ->
            if (id == presentation["sessionId"]) emit(mapOf("type" to "presentationAction", "sessionId" to id, "action" to action))
        }.also { it.update(visiblePresentation(), presentationReceivedAtMs, announceWeak = false) }
        bindVideos()
    }
    /** A late detach from the old Activity cannot remove the new Activity's panel. */
    fun detachNativeHost(container: FrameLayout) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (container !== hostRoot) return
        hostWindow?.close()
        hostWindow = null
        hostRoot = null
        nativeHostWindow = null
        updateSystemBars()
        bindVideos()
    }
    fun handleHostBack(): Boolean = hostWindow?.handlesBack() == true

    fun notifyHostForeground() {
        check(Looper.myLooper() == Looper.getMainLooper())
        val coveredSession = phoneBackgroundId
        hostStopped = false
        phoneBackgroundId = null
        visibility.foreground()
        preflightId?.let { id ->
            if (id == coveredSession) preflightRingDismissedAt = -1L
            observePreflightState(id, phone.read())
        }
        session?.let { s ->
            if (s.id == coveredSession) s.lastDismissedRingAt = -1L
            onPhoneState(s, phone.read())
        }
        resumeDeferredPhoneAudio()
    }

    private fun resumeDeferredPhoneAudio() {
        val s = session ?: return
        if (!s.audioRestoreDeferred || hostStopped || audioVisibility.stopped) return
        onPhoneState(s, phone.read())
        if (gate.isCurrent(s.ticket) && s.phoneState == PhoneCallState.IDLE && s.audioRestoreDeferred) {
            restoreAfterRing(s)
        }
    }
    /** Invoke for the whole application's transition to background, not an individual Activity pause. */
    fun notifyHostBackground() {
        check(Looper.myLooper() == Looper.getMainLooper())
        hostStopped = true
        val s = session
        val staged = preflightId?.takeIf {
            s == null && presentation["sessionId"] == it && presentation["phase"] == "waiting"
        }
        val id = s?.takeIf { it.result == null }?.id ?: staged
        if (id == null) {
            ordinaryBackground(s?.id)
            return
        }
        fun covered(): Boolean {
            if (phoneBackgroundId == id) return true
            session?.takeIf { it.id == id }?.let { return coveredByPhone(it) }
            val wasBusy = preflightState.busy
            observePreflightState(id, phone.read())
            val justDismissed = preflightRingDismissedAt >= 0 &&
                SystemClock.elapsedRealtime() - preflightRingDismissedAt < 400L
            val protected = wasBusy || preflightState.busy || justDismissed
            if (protected && hostStopped) phoneBackgroundId = id
            return protected
        }
        if (covered() || backgroundCheck != null) return
        // A full-screen dialer's onStop may beat its ringing broadcast, even before RTC admission.
        backgroundCheck = Runnable {
            backgroundCheck = null
            if ((session?.id == id || preflightId == id) && !covered()) ordinaryBackground(id)
        }.also { main.postDelayed(it, 400L) }
    }

    private fun coveredByPhone(s: Session): Boolean {
        val sampled = phone.read()
        val justDismissed = s.lastDismissedRingAt >= 0 &&
            SystemClock.elapsedRealtime() - s.lastDismissedRingAt < 400L
        if (!sampled.busy && s.phoneState != PhoneCallState.RINGING && !justDismissed) return false
        if (hostStopped) phoneBackgroundId = s.id
        onPhoneState(s, sampled)
        clearBackgroundCheck()
        return true
    }

    private fun ordinaryBackground(id: String?) {
        visibility.background(id)
        if (!hostStopped) visibility.foreground()
        updateSystemBars()
        hostWindow?.update(visiblePresentation(), presentationReceivedAtMs)
    }

    private fun clearBackgroundCheck() {
        backgroundCheck?.let(main::removeCallbacks)
        backgroundCheck = null
    }

    private fun onPhoneState(s: Session, state: PhoneCallState) {
        if (!gate.isCurrent(s.ticket) || state == PhoneCallState.UNKNOWN || state == s.phoneState) return
        val wasRinging = s.phoneState == PhoneCallState.RINGING
        s.phoneState = state
        if (s.result != null) {
            if (state.busy) rejectBusyPhone(s)
            return
        }
        if (state == PhoneCallState.ACTIVE) {
            if (sink == null) pendingPhoneEnds.add(s.id)
            emit(s, "systemCallState", mapOf("state" to state.wire))
            leave(s.id, null)
            return
        }
        if (state == PhoneCallState.RINGING) {
            s.captureRecoveryGeneration++
            s.phoneAudio.beginRing()
            s.audioRestoreDeferred = false
            if (backgroundCheck != null && hostStopped) phoneBackgroundId = s.id
            clearBackgroundCheck()
        } else if (wasRinging) {
            s.lastDismissedRingAt = SystemClock.elapsedRealtime()
        }
        if (state == PhoneCallState.RINGING || wasRinging) {
            emit(s, "systemCallState", mapOf("state" to state.wire))
            // A confirmed full-screen ring can leave us stopped after a missed call
            // (for example on the lock screen). Restore when the covered Activity returns.
            if (state == PhoneCallState.RINGING) applyPhoneAudio(s, state)
            else restoreAfterRing(s)
        }
    }

    private fun deferPhoneAudio(s: Session): Boolean {
        s.audioRestoreDeferred = hostStopped || audioVisibility.stopped
        return s.audioRestoreDeferred
    }

    private fun restoreAfterRing(s: Session) {
        if (deferPhoneAudio(s)) return
        val generation = ++s.captureRecoveryGeneration
        val rtc = engine ?: return
        fun recoverCapture() {
            if (!gate.isCurrent(s.ticket) || generation != s.captureRecoveryGeneration ||
                s.phoneState != PhoneCallState.IDLE || hostStopped || audioVisibility.stopped || phone.read().busy) return
            val recovered = s.phoneAudio.restoreCapture {
                rtc.enableLocalAudio(true).also { mediaDiagnostic(s, "phoneCaptureRecovery code=$it") }
            }
            if (!recovered) Log.w("CustomerRtc", "System phone microphone recovery pending")
        }
        recoverCapture()
        applyPhoneAudio(s, PhoneCallState.IDLE)
        // The vendor can report a capture failure after Android has announced IDLE;
        // device-busy capture can take about five seconds to become available again.
        main.postDelayed({ recoverCapture() }, 500L)
        main.postDelayed({
            recoverCapture()
            if (gate.isCurrent(s.ticket) && generation == s.captureRecoveryGeneration) {
                s.phoneAudio.endRecoveryWindow()
            }
        }, 5200L)
    }

    private fun applyPhoneAudio(s: Session, state: PhoneCallState, retry: Boolean = true) {
        val rtc = engine ?: return
        val ringing = state == PhoneCallState.RINGING
        if (!ringing && (deferPhoneAudio(s) || phone.read().busy)) return
        // Audio focus may still be moving to/from the system dialer. A transient SDK
        // failure here must not convert a declined phone call into an RTC hangup.
        val applied = s.phoneAudio.adjust(ringing, rtc::muteLocalAudioStream, rtc::adjustPlaybackSignalVolume,
            { speaker -> hasExternalAudioOutput(s) || rtc.isSpeakerphoneEnabled == speaker }, rtc::setEnableSpeakerphone)
        if (!applied) {
            if (retry) main.postDelayed({
                if (gate.isCurrent(s.ticket) && s.phoneState == state) applyPhoneAudio(s, state, retry = false)
            }, 400L) else Log.w("CustomerRtc", "System phone audio adjustment incomplete")
        }
    }

    private fun hasExternalAudioOutput(s: Session): Boolean {
        if (s.route == "wired" || s.route == "bluetooth") return true
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return true
        if (Build.VERSION.SDK_INT < 23) {
            @Suppress("DEPRECATION")
            return audio.isBluetoothScoOn || audio.isWiredHeadsetOn || audio.isBluetoothA2dpOn
        }
        return audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
            it.type in setOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE,
                AudioDeviceInfo.TYPE_HEARING_AID, AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_BLE_SPEAKER)
        }
    }

    private fun bindVideos(force: Boolean = false): Exception? {
        val rtc = engine ?: return if (force) IllegalStateException("RTC is not ready") else null
        val s = session ?: return null
        val bindings = CanvasBindings { role, success, code ->
            if (success) emit(s, "videoBound", mapOf("role" to role))
            else emit(s, "videoBindingError", mapOf("role" to role, "details" to errorDetails("rebindVideo", "retryOperation", code)))
        }
        val window = hostWindow?.takeIf { presentation["sessionId"] == s.id && presentation["probe"] != true }
        fun target(role: String): View? = if (window != null) {
            if (role == "local") window.local else window.remote
        } else videos.lastOrNull { !it.probe && it.role == role }?.view
        val local = target("local")
        if (force || boundLocal !== local) {
            boundLocal = local
            bindings.apply("local", local != null) { rtc.setupLocalVideo(VideoCanvas(local, VideoCanvas.RENDER_MODE_HIDDEN, 0)) }
        }
        val uid = s.remote
        val remote = if (uid == null) null else target("remote")
        if (boundUid != uid && boundUid != null) {
            val previousUid = boundUid!!
            bindings.apply("remote", false) { rtc.setupRemoteVideo(VideoCanvas(null, VideoCanvas.RENDER_MODE_HIDDEN, previousUid)) }
        }
        if (uid != null && (force || boundUid != uid || boundRemote !== remote)) {
            // Save the attempted target before reporting: Dart can immediately publish a new snapshot.
            boundUid = uid
            boundRemote = remote
            bindings.apply("remote", remote != null) { rtc.setupRemoteVideo(VideoCanvas(remote, VideoCanvas.RENDER_MODE_HIDDEN, uid)) }
        }
        if (uid == null) { boundUid = null; boundRemote = null }
        return bindings.failure
    }
    internal fun addWeb(id: Int, view: NativeWebView) { webs[id] = view }
    internal fun removeWeb(id: Int) { webs.remove(id) }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        if (binding.activity.hasWindowFocus()) audioVisibility.onActivityStarted(binding.activity)
        updateSystemBars()
        binding.addRequestPermissionsResultListener(this)
    }
    private fun detachActivity(changingConfiguration: Boolean = false) {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        if (!changingConfiguration && hostRoot == null) flutterFullscreen = false
        updateSystemBars()
        // The RTC engine uses Application context. Only a permission dialog is tied to the old Activity.
        if (!changingConfiguration) {
            finishPhonePermission()
            val pending = permissionSession
            permissionSession = null
            if (pending != null && gate.isCurrent(pending.ticket)) {
                pending.result?.error("no_activity", "Activity changed during authorization", null)
                pending.result = null
                leave(pending.id, null)
            }
        }
    }
    override fun onDetachedFromActivityForConfigChanges() = detachActivity(changingConfiguration = true)
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
        if (phonePermissionRequest != null && !phone.needsPermission()) finishPhonePermission()
        val s = permissionSession ?: return
        if (gate.isCurrent(s.ticket) && hasPermissions(binding.activity)) {
            permissionSession = null
            start(s)
        }
    }
    override fun onDetachedFromActivity() = detachActivity()
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        flutterFullscreen = false
        presentation = emptyMap<Any, Any>()
        detachActivity()
        session?.let { leave(it.id, null) }
        hostRoot?.let { detachNativeHost(it) }
        videos.clear()
        webs.values.toList().forEach { it.dispose() }
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        preflightId?.let(::endPreflight)
        phone.stop()
        (context as? Application)?.unregisterActivityLifecycleCallbacks(audioVisibility)
        pendingPhoneEnds.clear()
        phoneBackgroundId = null
        clearBackgroundCheck()
        cleanup.shutdown()
    }
}
