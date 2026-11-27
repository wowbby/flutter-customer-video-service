import Flutter
import UIKit
import CallKit
import AVFoundation
import AgoraRtcKit

struct SystemPhoneCall {
  let uuid: UUID
  let ended, connected, outgoing, held: Bool

  init(uuid: UUID, ended: Bool, connected: Bool, outgoing: Bool, held: Bool) {
    self.uuid = uuid; self.ended = ended; self.connected = connected; self.outgoing = outgoing; self.held = held
  }

  init(_ call: CXCall) {
    self.init(uuid: call.uuid, ended: call.hasEnded, connected: call.hasConnected, outgoing: call.isOutgoing, held: call.isOnHold)
  }

  var active: Bool { connected || outgoing || held }
}

enum SystemPhoneState: String { case idle, ringing, active }

public final class CustomerRtcPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CXCallObserverDelegate {
  typealias PermissionRequest = (AVMediaType, @escaping (Bool) -> Void) -> Void
  private let requestPermission: PermissionRequest
  private var sink: FlutterEventSink?
  private let gate = SessionGate()
  private static let retirement = EngineRetirement()
  private static weak var sdkOwner: CustomerRtcPlugin?
  private var engine: AgoraRtcEngineKit?
  private var delegate: CallDelegate?
  private var pendingJoin: FlutterResult?
  private var lastReleasedId: String?
  private var lastReleaseStatus = "released"
  private var remoteUid: UInt?
  private var hasRemoteFrame = false
  private var expectedPeer: UInt?
  private var presentation: [String: Any] = [:]
  private var presentationReceivedAt = ProcessInfo.processInfo.systemUptime
  private var hostInBackground = false
  private var interruptedSessionIds = Set<String>()
  private var pendingBackgroundEvents = [String]()
  private let callObserver = CXCallObserver()
  private let readCalls: (() -> [SystemPhoneCall])?
  private var observingSession: String?
  private var phoneState = SystemPhoneState.idle
  private var ringingCalls = Set<UUID>()
  private var pendingPhoneEvent: [String: Any]?
  private var phoneBackgroundSession: String?
  private var stagedBackgroundDeadline: TimeInterval?
  private var pendingPhoneBackgroundCheck: DispatchWorkItem?
  private var ringDismissedAt: TimeInterval?
  private var ringDismissedWhileInactive = false
  private var captureInterrupted = false
  private var audioNeedsRestore = false
  private var restoreRetry: DispatchWorkItem?
  private var desiredMute = false
  private var desiredSpeaker = true
  private var observers = [NSObjectProtocol]()
  private var overlay: HostCallOverlay?
  private weak var boundLocal: UIView?
  private weak var boundRemote: UIView?
  private var localBound = false
  private var boundUid: UInt?
  private let videos = NSMapTable<NSNumber, NativeVideoView>(keyOptions: .strongMemory, valueOptions: .weakMemory)

  public override convenience init() { self.init(requestPermission: CustomerRtcPlugin.requestMediaPermission) }

  init(readCalls: (() -> [SystemPhoneCall])? = nil, requestPermission: @escaping PermissionRequest) {
    self.readCalls = readCalls
    self.requestPermission = requestPermission
    super.init()
    callObserver.setDelegate(self, queue: .main)
    for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification,
                 AVAudioSession.routeChangeNotification, UIApplication.didBecomeActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        if name == UIApplication.didBecomeActiveNotification { self?.ringDismissedWhileInactive = false }
        self?.refreshPhoneState()
      })
    }
  }

  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

  public func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
    refreshPhoneState(changed: SystemPhoneCall(call))
  }

  private func calls(changed: SystemPhoneCall? = nil) -> [SystemPhoneCall] {
    var list = readCalls?() ?? callObserver.calls.map(SystemPhoneCall.init)
    if let changed {
      list.removeAll { $0.uuid == changed.uuid }
      list.append(changed)
    }
    return list.filter { !$0.ended }
  }

  private func state(of calls: [SystemPhoneCall]) -> SystemPhoneState {
    if calls.contains(where: { $0.active }) { return .active }
    return calls.isEmpty ? .idle : .ringing
  }

  private func beginPhoneObservation(_ id: String) {
    guard observingSession == nil else { return }
    observingSession = id
    phoneState = .idle
    desiredMute = false
    desiredSpeaker = true
  }

  private func endPhoneObservation(_ id: String) {
    guard observingSession == id else { return }
    observingSession = nil
    phoneState = .idle
    ringingCalls.removeAll()
    restoreRetry?.cancel()
    restoreRetry = nil
    audioNeedsRestore = false
    phoneBackgroundSession = nil
    ringDismissedAt = nil
    ringDismissedWhileInactive = false
    captureInterrupted = false
    stagedBackgroundDeadline = nil
    pendingPhoneBackgroundCheck?.cancel()
    pendingPhoneBackgroundCheck = nil
    pendingPhoneEvent = nil
  }

  func refreshPhoneState(changed: SystemPhoneCall? = nil) {
    guard let id = observingSession, phoneState != .active else { return }
    let list = calls(changed: changed)
    // A delayed final update can carry the only evidence that a ringing call was answered.
    let endedAfterAnswer = changed.map { $0.ended && $0.connected && ringingCalls.contains($0.uuid) } ?? false
    let next: SystemPhoneState = endedAfterAnswer ? .active : state(of: list)
    ringingCalls.formUnion(list.filter { !$0.active }.map { $0.uuid })
    if let changed, changed.ended { ringingCalls.remove(changed.uuid) }
    if next != .idle {
      if hostInBackground { phoneBackgroundSession = id }
      if stagedBackgroundDeadline != nil {
        pendingPhoneBackgroundCheck?.cancel()
        pendingPhoneBackgroundCheck = nil
        stagedBackgroundDeadline = nil
      }
    }
    if next != phoneState {
      if next == .idle {
        ringDismissedAt = ProcessInfo.processInfo.systemUptime
        ringDismissedWhileInactive = UIApplication.shared.applicationState != .active
      } else {
        ringDismissedAt = nil
        ringDismissedWhileInactive = false
      }
      phoneState = next
      let event: [String: Any] = ["type": "systemCallState", "sessionId": id, "state": next.rawValue]
      if let sink { sink(event) } else { pendingPhoneEvent = event }
      if next == .active {
        if gate.ticket?.sessionId == id {
          let reply = pendingJoin
          pendingJoin = nil
          leave(id, endObservation: false)
          reply?(systemCallBusy())
        }
        return
      }
      if next == .ringing, pendingJoin != nil, let ticket = gate.ticket {
        failJoin(ticket, code: "system_call_busy", message: "System phone call in progress")
        return
      }
      if next == .ringing, let engine {
        audioNeedsRestore = true
        _ = engine.muteLocalAudioStream(true)
        _ = engine.adjustPlaybackSignalVolume(0)
      }
    }
    if next == .idle { restoreAudioIfNeeded(id, attemptsLeft: 3) }
  }

  private func restoreAudioIfNeeded(_ id: String, attemptsLeft: Int) {
    guard observingSession == id, phoneState == .idle, audioNeedsRestore, let engine,
          !hostInBackground, UIApplication.shared.applicationState != .background else { return }
    // AVAudioSession can dispatch a route notification in response to either operation.
    audioNeedsRestore = false
    let audio = AVAudioSession.sharedInstance()
    let restored: Bool
    do {
      try audio.setActive(true)
      let ports = audio.currentRoute.outputs.map { $0.portType }
      let builtIn = !ports.isEmpty && ports.allSatisfy { [.builtInReceiver, .builtInSpeaker].contains($0) }
      let capture = desiredMute || !captureInterrupted || engine.enableLocalAudio(true) == 0
      if capture && !desiredMute { captureInterrupted = false }
      let mic = engine.muteLocalAudioStream(desiredMute)
      let playback = engine.adjustPlaybackSignalVolume(100)
      let route = !builtIn || engine.setEnableSpeakerphone(desiredSpeaker) == 0
      restored = capture && mic == 0 && playback == 0 && route
    } catch {
      restored = false
    }
    guard !restored else {
      restoreRetry?.cancel()
      restoreRetry = nil
      return
    }
    audioNeedsRestore = true
    // Phone state can go idle before iOS releases audio. Also retry on audio/foreground notifications.
    guard attemptsLeft > 0, restoreRetry == nil else { return }
    let retry = DispatchWorkItem { [weak self] in
      guard let self, self.observingSession == id else { return }
      self.restoreRetry = nil
      guard self.state(of: self.calls()) == .idle else { self.refreshPhoneState(); return }
      self.restoreAudioIfNeeded(id, attemptsLeft: attemptsLeft - 1)
    }
    restoreRetry = retry
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: retry)
  }

  private func systemCallBusy() -> FlutterError { error("system_call_busy", "System phone call in progress") }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = CustomerRtcPlugin()
    registrar.addMethodCallDelegate(instance, channel: FlutterMethodChannel(name: "customer_rtc", binaryMessenger: registrar.messenger()))
    FlutterEventChannel(name: "customer_rtc/events", binaryMessenger: registrar.messenger()).setStreamHandler(instance)
    registrar.register(NativeVideoFactory(owner: instance), withId: "customer_rtc/video")
    registrar.publish(instance)
  }

  /// Optional native presenter. Mount in the host's top container during native/H5 routes.
  @objc public func attachPresentation(to container: UIView) {
    attachPresentation(to: container, onFullScreenChanged: nil)
  }

  /// UIKit owns the system bars. Let the host select its call or business-page
  /// appearance when the attached overlay enters or leaves full-screen mode.
  @objc public func attachPresentation(to container: UIView, onFullScreenChanged: ((Bool) -> Void)?) {
    precondition(Thread.isMainThread)
    if let existing = overlay, existing.superview === container {
      container.bringSubviewToFront(existing)
      existing.onFullScreenChanged = onFullScreenChanged
      onFullScreenChanged?(existing.isFullScreenCall)
      return
    }
    removeOverlay()
    let view = HostCallOverlay(frame: container.bounds)
    view.onAction = { [weak self] id, action in
      guard let self = self, self.presentation["sessionId"] as? String == id else { return }
      self.emit(["type": "presentationAction", "sessionId": id, "action": action])
    }
    container.addSubview(view)
    overlay = view
    view.display(presentation, receivedAt: presentationReceivedAt, announceWeak: false)
    view.onFullScreenChanged = onFullScreenChanged
    onFullScreenChanged?(view.isFullScreenCall)
    bindVideos()
  }

  /// Identify the outgoing container so an old transition cannot detach its successor.
  @objc public func detachPresentation(from container: UIView) {
    precondition(Thread.isMainThread)
    guard let view = overlay, view.superview === container else { return }
    removeOverlay()
    bindVideos()
  }

  private func removeOverlay() {
    guard let view = overlay else { return }
    view.removeFromSuperview()
    overlay = nil
    if view.isFullScreenCall { view.onFullScreenChanged?(false) }
  }

  @objc public func handlePresentationBack() -> Bool {
    precondition(Thread.isMainThread)
    return overlay?.minimizeForBack() ?? false
  }

  /// Call when the app owning this Engine actually enters the background.
  @objc public func hostDidEnterBackground() {
    precondition(Thread.isMainThread)
    if !hostInBackground {
      // A new background interval only needs past IDs that Dart can still observe.
      let presentedId = presentation["sessionId"] as? String
      interruptedSessionIds = interruptedSessionIds.filter {
        $0 == presentedId || $0 == gate.ticket?.sessionId || pendingBackgroundEvents.contains($0)
      }
    }
    hostInBackground = true
    enforceHostBackground()
  }

  @objc public func hostDidEnterForeground() {
    precondition(Thread.isMainThread)
    // If the app was suspended before the scheduled check ran, settle that background interval first.
    if stagedBackgroundDeadline.map({ ProcessInfo.processInfo.systemUptime >= $0 }) ?? true {
      let deferred = pendingPhoneBackgroundCheck
      deferred?.perform()
      deferred?.cancel()
    }
    hostInBackground = false
    ringDismissedWhileInactive = false
    phoneBackgroundSession = nil
    refreshPhoneState()
  }

  private func enforceHostBackground() {
    guard hostInBackground, let id = gate.ticket?.sessionId ?? presentation["sessionId"] as? String else { return }
    if observingSession == id {
      refreshPhoneState()
      if phoneState != .idle { phoneBackgroundSession = id }
      // The decline/timeout callback can precede the scene's delayed background notification.
      if ringDismissedWhileInactive, let dismissed = ringDismissedAt, ProcessInfo.processInfo.systemUptime - dismissed < 0.4 {
        phoneBackgroundSession = id
      }
      if phoneBackgroundSession == id { return }
      let staged = gate.ticket == nil && presentation["phase"] as? String == "waiting"
      if engine != nil || staged {
        // Full-screen incoming-call UI can background the scene just before CallKit reports the ring.
        guard pendingPhoneBackgroundCheck == nil else { return }
        let check = DispatchWorkItem { [weak self] in
          guard let self, self.hostInBackground || staged, self.observingSession == id else { return }
          self.pendingPhoneBackgroundCheck = nil
          self.stagedBackgroundDeadline = nil
          self.refreshPhoneState()
          if self.phoneState == .idle && self.phoneBackgroundSession != id { self.interruptForBackground(id) }
        }
        pendingPhoneBackgroundCheck = check
        if staged { stagedBackgroundDeadline = ProcessInfo.processInfo.systemUptime + 0.4 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: check)
        return
      }
    }
    interruptForBackground(id)
  }

  private func interruptForBackground(_ id: String) {
    if interruptedSessionIds.insert(id).inserted { pendingBackgroundEvents.append(id) }
    replayBackgroundEvents()
    // Replay the release result when Dart leaves after iOS has suspended it.
    if gate.ticket?.sessionId == id { leave(id, forBackground: true) }
  }

  private func replayBackgroundEvents() {
    while let id = pendingBackgroundEvents.first, let events = sink {
      pendingBackgroundEvents.removeFirst()
      events(["type": "hostBackground", "sessionId": id])
    }
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    if let ticket = gate.ticket { leave(ticket.sessionId) }
    if let id = observingSession { endPhoneObservation(id) }
    callObserver.setDelegate(nil, queue: nil)
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    removeOverlay()
    presentation = [:]
    pendingBackgroundEvents.removeAll()
    interruptedSessionIds.removeAll()
    sink = nil
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    if let event = pendingPhoneEvent {
      pendingPhoneEvent = nil
      events(event)
    }
    refreshPhoneState()
    replayBackgroundEvents()
    return nil
  }
  public func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
  func emit(_ event: [String: Any]) { assert(Thread.isMainThread); sink?(event) }
  private func error(_ code: String, _ message: String, details: [String: Any]? = nil) -> FlutterError {
    FlutterError(code: code, message: message, details: details)
  }
  private func sdkError(_ code: Int, operation: String, recovery: String) -> FlutterError {
    error("sdkError", "Native RTC operation failed", details: ["sdkCode": code, "operation": operation, "recovery": recovery])
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    assert(Thread.isMainThread)
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "setFlutterCallFullscreen":
      // The Flutter view already fills its window; Flutter sets the bar style.
      result(nil)
    case "getPlatformVersion": result("iOS " + UIDevice.current.systemVersion)
    case "getSystemCallState":
      let current = state(of: calls())
      if let id = args["sessionId"] as? String, !id.isEmpty {
        if current == .idle { beginPhoneObservation(id) }
        if observingSession == id {
          refreshPhoneState()
          result(phoneState.rawValue)
          return
        }
      }
      result(current.rawValue)
    case "endSystemCallObservation":
      if let id = args["sessionId"] as? String, gate.ticket?.sessionId != id { endPhoneObservation(id) }
      result(nil)
    case "join": join(args, result: result)
    case "updatePresentation":
      let id = args["sessionId"] as? String
      if let active = gate.ticket, id != active.sessionId { result(nil); return }
      let changedSession = id != presentation["sessionId"] as? String
      presentation = args
      presentationReceivedAt = ProcessInfo.processInfo.systemUptime
      overlay?.display(args, receivedAt: presentationReceivedAt)
      if changedSession { bindVideos() }
      enforceHostBackground()
      result(nil)
    case "leave":
      guard let id = args["sessionId"] as? String, !id.isEmpty else { result(error("invalid_arguments", "sessionId required")); return }
      leave(id) { status in result(["releaseStatus": status]) }
    case "setMuted", "setCameraEnabled", "switchCamera", "setSpeaker", "renewToken", "setVideoQuality", "rebindVideo":
      guard let id = args["sessionId"] as? String, gate.ticket?.sessionId == id, let engine = engine, !gate.cleaning else {
        result(error("no_session", "No matching active call")); return
      }
      var status: Int32
      switch call.method {
      case "setMuted":
        guard let enabled = args["muted"] as? Bool else { result(error("invalid_arguments", "muted required")); return }
        let suppress = phoneState == .ringing || audioNeedsRestore
        status = 0
        if !enabled && !suppress && captureInterrupted {
          status = engine.enableLocalAudio(true)
          if status == 0 { captureInterrupted = false }
        }
        if status == 0 { status = engine.muteLocalAudioStream(suppress || enabled) }
        if status == 0 { desiredMute = enabled }
      case "setCameraEnabled":
        guard let enabled = args["enabled"] as? Bool else { result(error("invalid_arguments", "enabled required")); return }
        status = engine.enableLocalVideo(enabled)
      case "rebindVideo":
        let bindStatus = bindVideos(force: true)
        result(bindStatus == 0 ? nil : sdkError(Int(bindStatus), operation: "rebindVideo", recovery: "retryOperation"))
        return
      case "setVideoQuality":
        guard let quality = args["quality"] as? String, ["sd", "hd"].contains(quality) else {
          result(error("invalid_arguments", "Unsupported video quality")); return
        }
        status = configureQuality(quality, engine)
      case "switchCamera": status = engine.switchCamera()
      case "setSpeaker":
        guard let enabled = args["enabled"] as? Bool else { result(error("invalid_arguments", "enabled required")); return }
        status = phoneState == .ringing || audioNeedsRestore ? 0 : engine.setEnableSpeakerphone(enabled)
        if status == 0 { desiredSpeaker = enabled }
      default:
        guard let token = args["token"] as? String, !token.isEmpty, token.utf8.count <= 8192 else { result(error("invalid_arguments", "token required")); return }
        status = engine.renewToken(token)
      }
      result(status == 0 ? nil : sdkError(Int(status), operation: call.method, recovery: "retryOperation"))
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func join(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let id = args["sessionId"] as? String, !id.isEmpty, id.utf8.count <= 128 else {
      result(error("invalid_arguments", "Invalid sessionId")); return
    }
    if state(of: calls()) != .idle || (observingSession == id && phoneState == .active) {
      result(systemCallBusy()); return
    }
    if hostInBackground || UIApplication.shared.applicationState == .background {
      interruptForBackground(id)
      result(error("host_background", "App backgrounded during this session")); return
    }
    guard !interruptedSessionIds.contains(id) else {
      result(error("host_background", "App backgrounded during this session")); return
    }
    if let presentedId = presentation["sessionId"] as? String, presentedId != id {
      result(error("cancelled", "Session no longer presented")); return
    }
    guard let appId = args["appId"] as? String, appId.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil,
          let channel = args["channel"] as? String, !channel.isEmpty, channel.utf8.count <= 64,
          let token = args["token"] as? String, token.utf8.count <= 8192,
          let uidNumber = args["uid"] as? NSNumber, CFGetTypeID(uidNumber) != CFBooleanGetTypeID(),
          uidNumber.doubleValue >= 1, uidNumber.doubleValue <= 4294967295,
          uidNumber.doubleValue.rounded() == uidNumber.doubleValue else {
      result(error("invalid_arguments", "Invalid call configuration")); return
    }
    let peerValue = args["expectedPeerUid"]
    let peer = peerValue as? NSNumber
    if peerValue != nil && !(peerValue is NSNull) {
      guard let number = peer, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue >= 1, number.doubleValue <= 4294967295,
            number.doubleValue.rounded() == number.doubleValue,
            number.uintValue != uidNumber.uintValue else {
        result(error("invalid_arguments", "Invalid expectedPeerUid")); return
      }
    }
    let facing = args["cameraFacing"] as? String
    let quality = args["videoQuality"] as? String
    if (facing != nil && facing != "front" && facing != "rear") ||
       (quality != nil && quality != "sd" && quality != "hd") {
      result(error("invalid_arguments", "Unsupported camera or quality configuration")); return
    }
    let sceneWindows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    let legacyWindow: UIWindow? = UIApplication.shared.delegate?.window ?? nil
    let hasHost = sceneWindows.contains { $0.isKeyWindow && $0.rootViewController != nil } || legacyWindow?.rootViewController != nil
    guard hasHost else { result(error("missing_activity", "No foreground host")); return }
    guard observingSession == nil || observingSession == id,
          Self.sdkOwner == nil, Self.retirement.sessionId == nil, let ticket = gate.reserve(id) else {
      result(error("busy", "A call is active or cleaning up")); return
    }
    beginPhoneObservation(id)
    Self.sdkOwner = self
    if lastReleasedId == id { lastReleasedId = nil }
    expectedPeer = peer?.uintValue
    pendingJoin = result
    requestPermission(.video) { [weak self] camera in
      guard let self = self, self.canContinueJoin(ticket) else { return }
      guard camera else { self.failJoin(ticket, code: "permission_denied", message: "Camera permission denied"); return }
      self.requestPermission(.audio) { [weak self] microphone in
        guard let self = self, self.canContinueJoin(ticket) else { return }
        guard microphone else { self.failJoin(ticket, code: "permission_denied", message: "Microphone permission denied"); return }
        let delegate = CallDelegate(owner: self, ticket: ticket)
        self.delegate = delegate
        let config = AgoraRtcEngineConfig()
        config.appId = appId
        config.channelProfile = .communication
        let log = AgoraLogConfig()
        log.level = .none
        config.logConfig = log
        let engine = AgoraRtcEngineKit.sharedEngine(with: config, delegate: delegate)
        self.engine = engine
        let route = engine.setDefaultAudioRouteToSpeakerphone(true)
        guard route == 0 else { self.failJoin(ticket, code: "sdkError", message: "Audio route initialization failed", sdkCode: Int(route)); return }
        let video = engine.enableVideo()
        guard video == 0 else { self.failJoin(ticket, code: "sdkError", message: "Video initialization failed", sdkCode: Int(video)); return }
        if let facing = facing {
          let camera = AgoraCameraCapturerConfiguration()
          camera.cameraDirection = facing == "rear" ? .rear : .front
          let status = engine.setCameraCapturerConfiguration(camera)
          guard status == 0 else { self.failJoin(ticket, code: "sdkError", message: "Camera configuration failed", sdkCode: Int(status)); return }
        }
        if let quality = quality {
          let status = self.configureQuality(quality, engine)
          guard status == 0 else { self.failJoin(ticket, code: "sdkError", message: "Video quality configuration failed", sdkCode: Int(status)); return }
        }
        self.bindVideos()
        guard self.canContinueJoin(ticket) else { return }
        let preview = engine.startPreview()
        guard preview == 0 else { self.failJoin(ticket, code: "sdkError", message: "Preview initialization failed", sdkCode: Int(preview)); return }
        let options = AgoraRtcChannelMediaOptions()
        options.channelProfile = .communication
        options.clientRoleType = .broadcaster
        options.publishCameraTrack = true
        options.publishMicrophoneTrack = true
        options.autoSubscribeAudio = false
        options.autoSubscribeVideo = false
        guard self.canContinueJoin(ticket) else { return }
        let status = engine.joinChannel(byToken: token.isEmpty ? nil : token, channelId: channel, uid: uidNumber.uintValue, mediaOptions: options)
        guard status == 0 else { self.failJoin(ticket, code: "sdkError", message: "Join request rejected", sdkCode: Int(status)); return }
        let completion = self.pendingJoin; self.pendingJoin = nil; completion?(nil)
      }
    }
  }

  private func canContinueJoin(_ ticket: SessionGate.Ticket) -> Bool {
    guard gate.isCurrent(ticket) else { return false }
    guard state(of: calls()) == .idle else {
      failJoin(ticket, code: "system_call_busy", message: "System phone call in progress")
      return false
    }
    return true
  }

  private func configureQuality(_ quality: String, _ engine: AgoraRtcEngineKit) -> Int32 {
    let configuration = AgoraVideoEncoderConfiguration()
    configuration.dimensions = quality == "hd" ? CGSize(width: 1280, height: 720) : CGSize(width: 640, height: 360)
    configuration.frameRate = 15
    return engine.setVideoEncoderConfiguration(configuration)
  }

  private static func requestMediaPermission(_ media: AVMediaType, completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: media) {
    case .authorized: completion(true)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: media) { allowed in DispatchQueue.main.async { completion(allowed) } }
    default: completion(false)
    }
  }

  private func failJoin(_ ticket: SessionGate.Ticket, code: String, message: String, sdkCode: Int? = nil) {
    guard gate.isCurrent(ticket) else { return }
    let completion = pendingJoin; pendingJoin = nil
    leave(ticket.sessionId)
    completion?(sdkCode.map { self.sdkError($0, operation: "join", recovery: "retryCall") } ?? error(code, message))
  }

  private func leave(_ id: String, forBackground: Bool = false, endObservation: Bool = true, completion: ((String) -> Void)? = nil) {
    if endObservation { endPhoneObservation(id) }
    if Self.retirement.waitIfReleasing(id, completion: completion) { return }
    guard gate.beginLeave(id) != nil else {
      completion?(lastReleasedId == id ? lastReleaseStatus : "released")
      return
    }
    let cancelledJoin = pendingJoin; pendingJoin = nil
    var policy = CleanupPolicy()
    let retiringEngine = engine
    if let engine = retiringEngine {
      engine.delegate = nil
      policy.stop(engine.stopPreview())
      policy.stop(engine.enableLocalVideo(false))
      policy.stop(engine.enableLocalAudio(false))
      policy.stop(engine.setupLocalVideo(nil))
      if let uid = remoteUid {
        let canvas = AgoraRtcVideoCanvas(); canvas.uid = uid
        policy.stop(engine.setupRemoteVideo(canvas))
      }
      policy.stop(engine.leaveChannel(nil))
    }
    engine = nil; delegate = nil; remoteUid = nil; hasRemoteFrame = false
    boundLocal = nil; boundRemote = nil; localBound = false; boundUid = nil; expectedPeer = nil
    let finish = { [self] () -> String in
      policy.destroyReturned()
      let status = policy.releaseStatus!
      lastReleasedId = id
      lastReleaseStatus = status
      gate.finishLeave()
      Self.sdkOwner = nil
      cancelledJoin?(forBackground ? error("host_background", "App backgrounded during this session") :
        error("cancelled", "Join cancelled"))
      return status
    }
    if retiringEngine != nil {
      Self.retirement.start(id, destroy: { AgoraRtcEngineKit.destroy() }, finish: finish, completion: completion)
    } else {
      let status = finish()
      completion?(status)
    }
  }

  func addVideo(_ view: NativeVideoView, id: Int64) { videos.setObject(view, forKey: NSNumber(value: id)); bindVideos() }
  func removeVideo(_ id: Int64, role: String) {
    videos.removeObject(forKey: NSNumber(value: id))
    bindVideos()
  }

  // Prefer the visible host overlay. Fall back to the latest Flutter view for that role.
  private func canvasTarget(_ role: String, _ ticket: SessionGate.Ticket) -> UIView? {
    if let host = overlay, host.superview != nil, host.sessionId == ticket.sessionId {
      return role == "local" ? host.localVideo : host.remoteVideo
    }
    let ids = (videos.keyEnumerator().allObjects as? [NSNumber] ?? []).sorted { $0.int64Value > $1.int64Value }
    for id in ids {
      if let view = videos.object(forKey: id), !view.probe, view.role == role { return view.view() }
    }
    return nil
  }

  @discardableResult private func bindVideos(force: Bool = false) -> Int32 {
    guard let engine = engine, let ticket = gate.ticket else { return 0 }
    var failure: Int32 = 0
    func report(_ code: Int32, _ role: String, _ target: UIView?) {
      if code != 0 {
        failure = code
        callback(ticket, type: "videoBindingError", values: ["role": role, "details": ["sdkCode": Int(code)]])
      } else if target != nil {
        callback(ticket, type: "videoBound", values: ["role": role])
      }
    }
    let local = canvasTarget("local", ticket)
    if force || local !== boundLocal || (localBound && local == nil) {
      let canvas = AgoraRtcVideoCanvas(); canvas.view = local; canvas.uid = 0; canvas.renderMode = .hidden
      let code = engine.setupLocalVideo(local == nil ? nil : canvas)
      if code == 0 { boundLocal = local; localBound = local != nil }
      report(code, "local", local)
    }
    if let uid = remoteUid {
      let remote = canvasTarget("remote", ticket)
      if force || remote !== boundRemote || (boundUid != nil && (boundUid != uid || remote == nil)) {
        let canvas = AgoraRtcVideoCanvas(); canvas.view = remote; canvas.uid = uid; canvas.renderMode = .hidden
        let code = engine.setupRemoteVideo(canvas)
        if code == 0 { boundRemote = remote; boundUid = remote == nil ? nil : uid }
        report(code, "remote", remote)
      }
    }
    return failure
  }
  fileprivate func callback(_ ticket: SessionGate.Ticket, type: String, values: [String: Any] = [:]) {
    guard gate.isCurrent(ticket) else { return }
    var event = values; event["type"] = type; event["sessionId"] = ticket.sessionId; emit(event)
  }
  fileprivate func peerJoined(_ ticket: SessionGate.Ticket, uid: UInt) {
    guard gate.isCurrent(ticket), remoteUid == nil, expectedPeer == nil || expectedPeer == uid,
          let engine = engine else { return }
    let audio = engine.muteRemoteAudioStream(uid, mute: false)
    let status = audio == 0 ? engine.muteRemoteVideoStream(uid, mute: false) : audio
    guard status == 0 else {
      _ = engine.muteRemoteAudioStream(uid, mute: true)
      _ = engine.muteRemoteVideoStream(uid, mute: true)
      callback(ticket, type: "error", values: ["code": "sdkError", "details": ["sdkCode": Int(status)]])
      leave(ticket.sessionId); return
    }
    remoteUid = uid; hasRemoteFrame = false; bindVideos()
    callback(ticket, type: "remoteJoined", values: ["uid": uid])
  }
  fileprivate func peerLeft(_ ticket: SessionGate.Ticket, uid: UInt) {
    guard gate.isCurrent(ticket), remoteUid == uid else { return }
    let canvas = AgoraRtcVideoCanvas(); canvas.uid = uid; engine?.setupRemoteVideo(canvas)
    _ = engine?.muteRemoteAudioStream(uid, mute: true)
    _ = engine?.muteRemoteVideoStream(uid, mute: true)
    boundUid = nil; boundRemote = nil; remoteUid = nil; hasRemoteFrame = false
    callback(ticket, type: "remoteLeft", values: ["uid": uid])
  }
  fileprivate func peerFrame(_ ticket: SessionGate.Ticket, uid: UInt) {
    guard gate.isCurrent(ticket), remoteUid == uid, !hasRemoteFrame else { return }
    hasRemoteFrame = true; callback(ticket, type: "remoteVideo", values: ["uid": uid])
  }
  fileprivate func localAudio(_ ticket: SessionGate.Ticket, state: AgoraAudioLocalState, reason: AgoraAudioLocalReason) {
    guard gate.isCurrent(ticket) else { return }
    if reason == .interrupted || reason == .deviceBusy {
      // Capture can lose the device before CallKit delivers the incoming-call observation.
      captureInterrupted = true
      let justDismissed = ringDismissedAt.map { ProcessInfo.processInfo.systemUptime - $0 < 2 } ?? false
      if phoneState == .ringing || audioNeedsRestore || justDismissed {
        audioNeedsRestore = true
        if phoneState == .idle { refreshPhoneState() }
      }
    } else if state == .recording || state == .encoding {
      captureInterrupted = false
    }
    callback(ticket, type: "mediaTrackState", values: ["track": "localAudio", "state": state.rawValue, "reason": reason.rawValue])
  }

  fileprivate func network(_ ticket: SessionGate.Ticket, _ uid: UInt, _ tx: UInt, _ rx: UInt) {
    guard uid == 0 || uid == remoteUid else { return }
    callback(ticket, type: "networkQuality", values: ["uid": uid, "txQuality": tx, "rxQuality": rx])
  }

  fileprivate func remoteTrack(_ ticket: SessionGate.Ticket, uid: UInt, state: UInt, reason: UInt) {
    guard gate.isCurrent(ticket), remoteUid == uid else { return }
    if state == 0 || state == 4 { hasRemoteFrame = false }
    callback(ticket, type: "mediaTrackState", values: ["track": "remoteVideo", "uid": uid, "state": state, "reason": reason])
  }

  fileprivate func peerRenderStats(_ ticket: SessionGate.Ticket, uid: UInt, frames: Int) {
    guard gate.isCurrent(ticket), remoteUid == uid else { return }
    callback(ticket, type: "remoteVideoStats", values: ["uid": uid, "rendererOutputFrameRate": frames])
  }
}

private final class CallDelegate: NSObject, AgoraRtcEngineDelegate {
  private weak var owner: CustomerRtcPlugin?
  private let ticket: SessionGate.Ticket
  init(owner: CustomerRtcPlugin, ticket: SessionGate.Ticket) { self.owner = owner; self.ticket = ticket }
  private func deliver(_ block: @escaping (CustomerRtcPlugin, SessionGate.Ticket) -> Void) {
    let ticket = self.ticket
    DispatchQueue.main.async { [weak owner] in if let owner = owner { block(owner, ticket) } }
  }
  func rtcEngine(_ engine: AgoraRtcEngineKit, localVideoStateChangedOf state: AgoraVideoLocalState, reason: AgoraLocalVideoStreamReason, sourceType: AgoraVideoSourceType) {
    guard sourceType.rawValue == 0 else { return }
    deliver { $0.callback($1, type: "mediaTrackState", values: ["track": "localVideo", "state": state.rawValue, "reason": reason.rawValue]) }
  }
  func rtcEngine(_ engine: AgoraRtcEngineKit, localAudioStateChanged state: AgoraAudioLocalState, reason: AgoraAudioLocalReason) {
    deliver { $0.localAudio($1, state: state, reason: reason) }
  }
  func rtcEngine(_ engine: AgoraRtcEngineKit, remoteVideoStateChangedOfUid uid: UInt, state: AgoraVideoRemoteState, reason: AgoraVideoRemoteReason, elapsed: Int) {
    deliver { $0.remoteTrack($1, uid: uid, state: state.rawValue, reason: reason.rawValue) }
  }

  func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) { deliver { $0.callback($1, type: "joined", values: ["uid": uid]) } }
  func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) { deliver { $0.peerJoined($1, uid: uid) } }
  func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) { deliver { $0.peerLeft($1, uid: uid) } }
  func rtcEngine(_ engine: AgoraRtcEngineKit, firstRemoteVideoFrameOfUid uid: UInt, size: CGSize, elapsed: Int) { deliver { $0.peerFrame($1, uid: uid) } }
  func rtcEngine(_ engine: AgoraRtcEngineKit, remoteVideoStats stats: AgoraRtcRemoteVideoStats) {
    let uid = stats.uid; let frames = stats.rendererOutputFrameRate
    deliver { $0.peerRenderStats($1, uid: uid, frames: frames) }
  }
  func rtcEngine(_ engine: AgoraRtcEngineKit, tokenPrivilegeWillExpire token: String) { deliver { $0.callback($1, type: "tokenRequired") } }
  func rtcEngineRequestToken(_ engine: AgoraRtcEngineKit) { deliver { $0.callback($1, type: "tokenRequired") } }
  func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) { deliver { $0.callback($1, type: "error", values: ["code": "sdkError", "message": "Native RTC error", "details": ["sdkCode": errorCode.rawValue, "operation": "event", "recovery": "retryCall"]]) } }
  func rtcEngine(_ engine: AgoraRtcEngineKit, networkQuality uid: UInt, txQuality: AgoraNetworkQuality, rxQuality: AgoraNetworkQuality) {
    deliver { $0.network($1, uid, txQuality.rawValue, rxQuality.rawValue) }
  }
  func rtcEngine(_ engine: AgoraRtcEngineKit, didAudioRouteChanged routing: AgoraAudioOutputRouting) {
    let route: String
    switch routing {
    case .headset, .headsetNoMic, .usb: route = "wired"
    case .earpiece: route = "earpiece"
    case .speakerphone, .loudspeaker: route = "speaker"
    case .bluetoothDeviceHfp, .bluetoothDeviceA2dp: route = "bluetooth"
    default: route = "other"
    }
    deliver { $0.callback($1, type: "audioRoute", values: ["route": route]) }
  }
  func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
    let value: String
    switch state { case .connecting: value = "connecting"; case .connected: value = "connected"; case .reconnecting: value = "reconnecting"; case .failed: value = "failed"; default: value = "disconnected" }
    deliver { $0.callback($1, type: "connection", values: ["state": value, "reason": reason.rawValue]) }
  }
}
