import Flutter
import ImageIO
import UIKit

/// Optional UIKit host for a full-screen call above native navigation.
open class CustomerRtcNavigationController: UINavigationController {
  @objc public var showsFullScreenCall = false {
    didSet {
      guard oldValue != showsFullScreenCall else { return }
      setNeedsStatusBarAppearanceUpdate()
      setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
  }

  open override var childForStatusBarStyle: UIViewController? { showsFullScreenCall ? nil : super.childForStatusBarStyle }
  open override var childForStatusBarHidden: UIViewController? { showsFullScreenCall ? nil : super.childForStatusBarHidden }
  open override var childForHomeIndicatorAutoHidden: UIViewController? { showsFullScreenCall ? nil : super.childForHomeIndicatorAutoHidden }
  open override var preferredStatusBarStyle: UIStatusBarStyle { showsFullScreenCall ? .lightContent : super.preferredStatusBarStyle }
  open override var prefersStatusBarHidden: Bool { showsFullScreenCall ? false : super.prefersStatusBarHidden }
  open override var prefersHomeIndicatorAutoHidden: Bool { showsFullScreenCall ? false : super.prefersHomeIndicatorAutoHidden }
}

private func imageAsset(_ filename: String) -> UIImage? {
  UIImage(named: FlutterDartProject.lookupKey(forAsset: "assets/" + filename, fromPackage: "customer_video_service"))
}

private func callIcon(_ name: String, size: CGFloat) -> UIImage? {
  guard let raw = imageAsset("call_icons/call_" + name + ".png")?.cgImage else { return nil }
  let scale = CGFloat(max(raw.width, raw.height)) / size
  return UIImage(cgImage: raw, scale: scale, orientation: .up).withRenderingMode(.alwaysTemplate)
}

private func callCardBorder() -> CAGradientLayer {
  let rim = CAGradientLayer(), outline = CAShapeLayer()
  rim.colors = [UIColor.white.withAlphaComponent(0.7).cgColor, UIColor.white.withAlphaComponent(0.8).cgColor]
  outline.fillColor = nil
  outline.strokeColor = UIColor.white.cgColor
  rim.mask = outline
  return rim
}

private func callCardSize(width: CGFloat, height: CGFloat) -> CGSize {
  let scale = max(0, min(1, width / 84, height / 150))
  return CGSize(width: 84 * scale, height: 150 * scale)
}

private func layoutCard(in bounds: CGRect, avatar: UIImageView, caption: UILabel, border: CAGradientLayer) {
  let scale = bounds.width / 84
  // The 259px export's visible portrait is 180px wide and centered 15.5px above the bitmap center.
  let portraitScale = 58 * scale / 180
  avatar.bounds.size = CGSize(width: 259 * portraitScale, height: 259 * portraitScale)
  avatar.center = CGPoint(x: bounds.midX, y: 64 * scale + 15.5 * portraitScale)
  caption.frame = CGRect(x: 1.5 * scale, y: 120.5 * scale, width: 81 * scale, height: 28 * scale)
  CATransaction.begin()
  CATransaction.setDisableActions(true)
  border.frame = bounds
  if let outline = border.mask as? CAShapeLayer {
    outline.frame = bounds
    outline.lineWidth = 1.5 * scale
    outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75 * scale, dy: 0.75 * scale),
                                cornerRadius: 19.25 * scale).cgPath
  }
  CATransaction.commit()
}

/// Drawn inside a host-owned top-level view. Uncovered pixels pass touches to the page.
final class HostCallOverlay: UIView {
  let localVideo = UIView(), remoteVideo = UIView()
  private let panel = UIView(), shade = UIView(), insetPlaceholder = UIView()
  private let gradient = CAGradientLayer(), avatar = UIImageView()
  private let localAvatar = UIImageView()
  private var localAvatarPath: String?
  private let networkToast = UILabel()
  private var weakMask = 0
  private var dismissToast: DispatchWorkItem?
  private let statusBarShade = CAGradientLayer(), homeIndicatorShade = CAGradientLayer()
  private let insetChrome = UIButton(type: .custom), insetGradient = CAGradientLayer(), insetTime = UILabel()
  private let primaryPlaceholder = UIView(), primaryGradient = CAGradientLayer(), primaryAvatar = UIImageView()
  private let insetAvatar = UIImageView(), waitingBackground = UIImageView(), waitingLabel = UILabel(), status = UILabel()
  private let miniCard = UIButton(type: .custom), cardGradient = CAGradientLayer()
  private let cardBorder = callCardBorder(), insetBorder = callCardBorder()
  private let cardAvatar = UIImageView(), cardCaption = UILabel()
  private let waitingColors = [
    UIColor(red: 34/255, green: 45/255, blue: 45/255, alpha: 1).cgColor,
    UIColor(red: 39/255, green: 52/255, blue: 52/255, alpha: 1).cgColor
  ]
  private let waitingCaptionColor = UIColor(red: 69/255, green: 83/255, blue: 83/255, alpha: 0.4)
  private let timeLabel = UILabel(), timeCaption = UILabel()
  private let modeButton = UIButton(type: .system), qualityButton = UIButton(type: .system)
  private let qualityBackdrop = UIControl(), qualityMenu = UIView()
  private let sd = UIButton(type: .custom), hd = UIButton(type: .custom)
  private let recoveryButton = UIButton(type: .system)
  private let mic = CallActionButton(icon: "mic"), speaker = CallActionButton(icon: "speaker")
  private let camera = CallActionButton(icon: "camera"), orientation = CallActionButton(icon: "rotate")
  private let end = CallActionButton(icon: "end"), flip = CallActionButton(icon: "flip")
  private let minimizeIcon = callIcon("minimize", size: 24)
  private let waitingMinimizeIcon = callIcon("minimize_wait", size: 24)
  private var mini = true, localPrimary = false, waiting = true, rotated = false
  private var dragPosition: CGPoint?
  private var callStartUptime: TimeInterval?, frozenDuration: TimeInterval?
  private var timer: Timer?
  private(set) var sessionId: String?
  var isFullScreenCall: Bool { sessionId != nil && !mini }
  var onFullScreenChanged: ((Bool) -> Void)?
  var onAction: ((String, String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(panel)
    networkToast.isHidden = true
    networkToast.textColor = .white
    networkToast.textAlignment = .center
    networkToast.font = .systemFont(ofSize: 14)
    networkToast.backgroundColor = UIColor(white: 0.15, alpha: 0.90)
    networkToast.layer.cornerRadius = 10
    networkToast.clipsToBounds = true
    networkToast.accessibilityIdentifier = "customer_rtc.networkToast"
    addSubview(networkToast)
    localAvatar.contentMode = .scaleAspectFill
    localAvatar.backgroundColor = UIColor(white: 0.27, alpha: 1)
    localAvatar.clipsToBounds = true
    localAvatar.tintColor = .lightGray
    localAvatar.image = UIImage(systemName: "person.crop.circle.fill")
    localAvatar.accessibilityIdentifier = "customer_rtc.localAvatar"
    // The call panel can rotate independently of the physical system bars.
    for edge in [statusBarShade, homeIndicatorShade] {
      let dark = UIColor.black.withAlphaComponent(0.70).cgColor
      edge.colors = [dark, dark, UIColor.clear.cgColor]
      edge.locations = [0, 0.65, 1]
      edge.isHidden = true
      layer.addSublayer(edge)
    }
    homeIndicatorShade.startPoint = CGPoint(x: 0.5, y: 1)
    homeIndicatorShade.endPoint = CGPoint(x: 0.5, y: 0)
    panel.clipsToBounds = true
    for video in [localVideo, remoteVideo] {
      video.clipsToBounds = true
      video.backgroundColor = UIColor(white: 0.07, alpha: 1)
      video.isUserInteractionEnabled = false
      panel.addSubview(video)
    }

    waitingBackground.image = imageAsset("call_wait_background.jpg")
    waitingBackground.contentMode = .scaleAspectFill
    waitingBackground.clipsToBounds = true
    panel.addSubview(waitingBackground)
    let brandImage = imageAsset("service_avatar.png")
    for image in [avatar, insetAvatar, cardAvatar, primaryAvatar] {
      image.image = brandImage
      image.tintColor = .systemTeal
      image.contentMode = .scaleAspectFit
    }
    insetGradient.colors = [UIColor(red: 112.0/255, green: 194.0/255, blue: 190.0/255, alpha: 1).cgColor,
                            UIColor(red: 83.0/255, green: 144.0/255, blue: 141.0/255, alpha: 1).cgColor]
    primaryPlaceholder.accessibilityIdentifier = "customer_rtc.primaryPlaceholder"
    primaryPlaceholder.isUserInteractionEnabled = false
    primaryGradient.colors = insetGradient.colors
    primaryPlaceholder.layer.addSublayer(primaryGradient)
    primaryPlaceholder.addSubview(primaryAvatar)
    panel.addSubview(primaryPlaceholder)
    insetPlaceholder.backgroundColor = .black
    insetPlaceholder.layer.addSublayer(insetGradient)
    insetPlaceholder.accessibilityIdentifier = "customer_rtc.insetPlaceholder"
    insetPlaceholder.clipsToBounds = true
    insetPlaceholder.isUserInteractionEnabled = false
    insetPlaceholder.addSubview(insetAvatar)
    panel.addSubview(insetPlaceholder)
    insetChrome.accessibilityIdentifier = "customer_rtc.swapVideo"
    insetChrome.addAction(UIAction { [weak self] _ in
      guard let self = self, !self.insetChrome.isHidden, self.insetChrome.isEnabled else { return }
      self.send("swapVideo")
    }, for: .touchUpInside)
    insetChrome.clipsToBounds = true
    insetTime.accessibilityIdentifier = "customer_rtc.insetTime"
    insetTime.textAlignment = .center
    insetTime.textColor = .white
    insetTime.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    insetTime.adjustsFontSizeToFitWidth = true
    insetTime.backgroundColor = UIColor(red: 9.0/255, green: 64.0/255, blue: 61.0/255, alpha: 0.4)
    insetChrome.addSubview(insetTime)
    insetChrome.layer.addSublayer(insetBorder)
    panel.addSubview(insetChrome)
    shade.isUserInteractionEnabled = false
    gradient.colors = [UIColor.black.withAlphaComponent(0.70).cgColor, UIColor.clear.cgColor,
                       UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.70).cgColor]
    gradient.locations = [0, 0.186, 0.645, 1]
    shade.layer.addSublayer(gradient)
    panel.addSubview(shade)
    panel.addSubview(avatar)
    for label in [waitingLabel, status, timeLabel, timeCaption] {
      label.textColor = .white
      label.textAlignment = .center
      label.font = .systemFont(ofSize: 14)
      panel.addSubview(label)
    }
    waitingLabel.numberOfLines = 3
    waitingLabel.font = .systemFont(ofSize: 13)
    status.backgroundColor = UIColor.black.withAlphaComponent(0.67)
    status.font = .systemFont(ofSize: 12)
    status.adjustsFontSizeToFitWidth = true
    status.layer.cornerRadius = 8
    status.clipsToBounds = true
    timeLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .medium)
    timeCaption.font = .systemFont(ofSize: 13)
    timeCaption.text = "通话时长"
    for button in [modeButton, qualityButton, recoveryButton] {
      button.tintColor = .white
      button.setTitleColor(.white, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 15)
      panel.addSubview(button)
    }
    modeButton.addAction(UIAction { [weak self] _ in self?.changeMode() }, for: .touchUpInside)
    modeButton.accessibilityIdentifier = "customer_rtc.mode"
    qualityButton.accessibilityIdentifier = "customer_rtc.quality"
    var qualityStyle = UIButton.Configuration.plain()
    qualityStyle.baseForegroundColor = .white
    qualityStyle.contentInsets = .zero
    qualityStyle.image = callIcon("quality_arrow", size: 9)
    qualityStyle.imagePlacement = .trailing
    qualityStyle.imagePadding = 4
    qualityStyle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var result = attributes
      result.font = .systemFont(ofSize: 15)
      return result
    }
    qualityButton.configuration = qualityStyle

    qualityButton.addAction(UIAction { [weak self] _ in
      guard let self = self, self.sessionId != nil, !self.qualityButton.isHidden, self.qualityButton.isEnabled else { return }
      self.qualityBackdrop.isHidden = false
      UIAccessibility.post(notification: .layoutChanged, argument: self.hd.isSelected ? self.hd : self.sd)
    }, for: .touchUpInside)
    recoveryButton.backgroundColor = UIColor.black.withAlphaComponent(0.7)
    recoveryButton.layer.cornerRadius = 12
    recoveryButton.addAction(UIAction { [weak self] _ in
      guard let self = self, !self.recoveryButton.isHidden, self.recoveryButton.isEnabled else { return }
      self.send(self.recoveryAction)
    }, for: .touchUpInside)
    let actions = [(mic, "toggleMuted"), (speaker, "toggleSpeaker"), (camera, "toggleCamera"),
                   (orientation, "toggleOrientation"), (end, "hangup"), (flip, "switchCamera")]
    for (button, action) in actions {
      panel.addSubview(button)
      button.accessibilityIdentifier = "customer_rtc." + action
      button.addAction(UIAction { [weak self, weak button] _ in
        guard let button = button, button.isEnabled, !button.isHidden else { return }
        self?.send(action)
      }, for: .touchUpInside)
    }
    qualityBackdrop.isHidden = true
    qualityBackdrop.isAccessibilityElement = false
    qualityBackdrop.accessibilityViewIsModal = true
    qualityBackdrop.addAction(UIAction { [weak self] _ in self?.dismissQualityMenu() }, for: .touchUpInside)
    panel.addSubview(qualityBackdrop)
    qualityMenu.accessibilityIdentifier = "customer_rtc.qualityMenu"
    qualityMenu.backgroundColor = .white
    qualityMenu.layer.cornerRadius = 16
    qualityMenu.layer.shadowColor = UIColor.black.cgColor
    qualityMenu.layer.shadowOpacity = 0.24
    qualityMenu.layer.shadowRadius = 4
    qualityMenu.layer.shadowOffset = CGSize(width: 0, height: 2)
    qualityBackdrop.addSubview(qualityMenu)
    for (button, title, action) in [(sd, "标清", "setQualitySd"), (hd, "高清", "setQualityHd")] {
      button.setTitle(title, for: .normal)
      button.accessibilityIdentifier = "customer_rtc." + action
      button.setTitleColor(UIColor(red: 34 / 255, green: 41 / 255, blue: 42 / 255, alpha: 1), for: .normal)
      button.setTitleColor(UIColor(red: 0, green: 135 / 255, blue: 129 / 255, alpha: 1), for: .selected)
      button.addAction(UIAction { [weak self, weak button] _ in
        guard let self = self, let button = button, !self.qualityBackdrop.isHidden else { return }
        self.dismissQualityMenu()
        if !button.isSelected { self.send(action) }
      }, for: .touchUpInside)
      qualityMenu.addSubview(button)
    }
    let drag = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
    status.addGestureRecognizer(drag)
    status.isUserInteractionEnabled = true
    miniCard.isHidden = true
    miniCard.accessibilityIdentifier = "customer_rtc.compactMini"
    miniCard.clipsToBounds = true
    miniCard.layer.insertSublayer(cardGradient, at: 0)
    miniCard.addSubview(cardAvatar)
    cardCaption.accessibilityIdentifier = "customer_rtc.compactCaption"
    cardCaption.textAlignment = .center
    cardCaption.adjustsFontSizeToFitWidth = true
    cardCaption.textColor = .white
    miniCard.addSubview(cardCaption)
    miniCard.layer.addSublayer(cardBorder)
    miniCard.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
    miniCard.addAction(UIAction { [weak self] _ in
      guard let self = self, !self.miniCard.isHidden else { return }
      self.send("restore")
    }, for: .touchUpInside)
    panel.addSubview(miniCard)
    let tap = UITapGestureRecognizer(target: self, action: #selector(tapVideo))
    tap.delegate = self
    panel.addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) { nil }
  deinit { timer?.invalidate() }

  private var recoveryAction = "rebindVideo"

  private func updateLocalAvatar(path: String?) {
    guard path != localAvatarPath else { return }
    localAvatarPath = path
    localAvatar.image = UIImage(systemName: "person.crop.circle.fill")
    guard let path, (path as NSString).isAbsolutePath else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return }
      let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 512]
      guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.localAvatarPath == path else { return }
        self.localAvatar.image = UIImage(cgImage: thumbnail)
      }
    }
  }

  private func updateNetworkToast(mask: Int, announce: Bool) {
    guard mask != weakMask else { return }
    let newSide = mask & ~weakMask != 0
    weakMask = mask
    dismissToast?.cancel()
    networkToast.isHidden = true
    guard announce, newSide, window != nil, !isHidden else { return }
    let text = mask == 1 ? "当前你的网络不佳" : mask == 2 ? "当前对方网络不佳" : "当前双方网络不佳"
    networkToast.text = text
    networkToast.isHidden = false
    UIAccessibility.post(notification: .announcement, argument: text)
    let hide = DispatchWorkItem { [weak self] in self?.networkToast.isHidden = true }
    dismissToast = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: hide)
  }

  func display(_ snapshot: [String: Any], receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
               announceWeak: Bool = true) {
    let wasFullScreen = isFullScreenCall
    let id = snapshot["sessionId"] as? String
    if sessionId != id {
      updateNetworkToast(mask: 0, announce: false)
      updateLocalAvatar(path: nil)
      dragPosition = nil
      qualityBackdrop.isHidden = true
    }
    sessionId = id
    isHidden = id == nil
    mini = snapshot["mode"] as? String == "mini"
    accessibilityViewIsModal = isFullScreenCall
    if wasFullScreen != isFullScreenCall { onFullScreenChanged?(isFullScreenCall) }
    rotated = !mini && snapshot["rotated"] as? Bool == true
    localPrimary = snapshot["primaryVideo"] as? String == "local"
    let phase = snapshot["phase"] as? String ?? ""
    let probe = snapshot["probe"] as? Bool == true
    let surface = snapshot["showsCallSurface"] as? Bool ?? (probe || phase == "connected")
    waiting = !mini && !surface
    let canControl = snapshot["canControl"] as? Bool == true
    let retryEnd = snapshot["errorCode"] as? String == "cleanupFailed"
    let restart = snapshot["restartRequired"] as? Bool == true
    let needsRebind = snapshot["bindingFailed"] as? Bool == true
    let hasRemoteVideo = snapshot["remoteVideo"] as? Bool == true
    let cameraEnabled = snapshot["cameraEnabled"] as? Bool != false
    let muted = snapshot["muted"] as? Bool == true
    let quality = snapshot["quality"] as? String
    let qualityLabel = ["sd": "标清", "hd": "高清"][quality ?? ""] ?? "清晰度"
    let regularControls = !mini && surface
    panel.backgroundColor = waiting ? UIColor(red: 29.0 / 255, green: 38.0 / 255, blue: 38.0 / 255, alpha: 1) : .black
    let mediaCard = mini && (snapshot["answeredMiniCard"] as? Bool == true || snapshot["previewMiniCard"] as? Bool == true)
    let compactCard = mediaCard || (mini && snapshot["awaitingAnswer"] as? Bool == true)
    let businessDuration = snapshot["connectedDurationMs"] as? NSNumber
    // A preview can predate seat acceptance. Only the business sample is used after acceptance.
    let sample = (businessDuration ?? snapshot["miniElapsedMs"] as? NSNumber).map { max(0, $0.doubleValue) / 1000 }
    callStartUptime = (!mini || (mediaCard && !probe)) ? sample.map { receivedAt - $0 } : nil
    frozenDuration = phase == "ending" ? sample : nil
    let mask = phase == "ending" || id == nil ? 0 :
      ((snapshot["localWeak"] as? Bool == true ? 1 : 0) | (snapshot["remoteWeak"] as? Bool == true ? 2 : 0))
    updateNetworkToast(mask: mask, announce: announceWeak)
    updateLocalAvatar(path: id == nil ? nil : snapshot["localAvatarPath"] as? String)
    miniCard.isHidden = !compactCard
    localVideo.isHidden = waiting || compactCard || !cameraEnabled
    let cardReceivesVideo = !probe && mediaCard
    let remoteCardHasVideo = snapshot["miniRemoteVideo"] as? Bool ?? hasRemoteVideo
    let cardShowsVideo = cardReceivesVideo && remoteCardHasVideo
    // Keep the remote renderer visible behind the opaque avatar until its first frame.
    remoteVideo.isHidden = waiting || (compactCard && !cardReceivesVideo)
    cardAvatar.isHidden = cardShowsVideo
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    cardGradient.isHidden = cardShowsVideo
    cardGradient.colors = mediaCard ? insetGradient.colors : waitingColors
    CATransaction.commit()
    let label = mediaCard ? (probe ? "无媒体测试" : "通话中") : "等待接听"
    miniCard.accessibilityLabel = label + "，恢复全屏"
    cardCaption.backgroundColor = mediaCard ? insetTime.backgroundColor : waitingCaptionColor
    cardCaption.font = cardReceivesVideo ? insetTime.font : .systemFont(ofSize: 14, weight: .medium)
    cardCaption.text = cardReceivesVideo ? "00:00" : label
    miniCard.accessibilityValue = cardReceivesVideo ? cardCaption.text : nil
    waitingBackground.isHidden = !waiting
    avatar.isHidden = !waiting
    waitingLabel.isHidden = !waiting
    let waitText = snapshot["queueLabel"] as? String ?? "等待坐席接听，请稍等…"
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.minimumLineHeight = 18
    paragraph.maximumLineHeight = 18
    waitingLabel.attributedText = NSAttributedString(string: waitText, attributes: [.paragraphStyle: paragraph])
    insetPlaceholder.isHidden = mini || waiting || probe || (localPrimary ? remoteCardHasVideo : cameraEnabled)
    primaryPlaceholder.isHidden = !regularControls || probe || (localPrimary ? cameraEnabled : remoteCardHasVideo)
    primaryPlaceholder.backgroundColor = localPrimary ? .black : .clear
    primaryGradient.isHidden = localPrimary
    primaryAvatar.isHidden = localPrimary
    let userPlaceholder = localPrimary ? primaryPlaceholder : insetPlaceholder
    if localAvatar.superview !== userPlaceholder { userPlaceholder.addSubview(localAvatar) }
    localAvatar.isHidden = cameraEnabled || !regularControls || probe
    insetGradient.isHidden = !localPrimary
    insetAvatar.isHidden = !localPrimary
    insetChrome.isHidden = mini || waiting || probe
    insetChrome.isEnabled = !insetChrome.isHidden && snapshot["canSwapVideo"] as? Bool == true
    insetChrome.isUserInteractionEnabled = insetChrome.isEnabled
    insetChrome.isAccessibilityElement = insetChrome.isEnabled
    insetChrome.accessibilityLabel = localPrimary ? "切换到对方主画面" : "切换到本机主画面"
    shade.isHidden = mini || waiting
    modeButton.setImage(mini ? nil : (waiting ? waitingMinimizeIcon : minimizeIcon), for: .normal)
    modeButton.isHidden = compactCard
    modeButton.setTitle(mini ? "全屏" : nil, for: .normal)
    modeButton.accessibilityLabel = mini ? "恢复全屏" : "缩小窗口"
    qualityButton.isHidden = !regularControls || probe
    qualityButton.isEnabled = canControl
    qualityButton.configuration?.title = qualityLabel
    qualityButton.accessibilityLabel = qualityLabel
    if !canControl || qualityButton.isHidden { qualityBackdrop.isHidden = true }
    for (button, value) in [(sd, "sd"), (hd, "hd")] {
      button.isSelected = quality == value
      button.titleLabel?.font = .systemFont(ofSize: 14, weight: button.isSelected ? .semibold : .regular)
    }

    let route = snapshot["audioRoute"] as? String
    let usingSpeaker = snapshot["speaker"] as? Bool == true
    let speakerLabel = ["bluetooth": "蓝牙设备", "wired": "有线耳机", "earpiece": "听筒已开"][route ?? ""] ??
      (usingSpeaker ? "扬声器已开" : "扬声器已关")
    mic.configure(muted ? "麦克风已关" : "麦克风已开", active: !muted)
    speaker.configure(speakerLabel, active: usingSpeaker)
    camera.configure(cameraEnabled ? "摄像头已开" : "摄像头已关", active: cameraEnabled)
    flip.configure("翻转摄像头", active: false)
    for button in [mic, speaker, camera, flip] {
      button.isHidden = !regularControls
      button.isEnabled = canControl
    }
    orientation.isHidden = !regularControls
    orientation.isEnabled = snapshot["canToggleOrientation"] as? Bool == true
    let endLabel = restart ? "请重新启动 App" : (retryEnd ? "重试结束" : (probe ? "结束测试" : (surface ? "挂断" : "取消")))
    end.configure(endLabel, active: false, destructive: true)
    end.isHidden = compactCard
    end.isEnabled = !restart && (phase != "ending" || retryEnd)
    let retryToken = snapshot["canRefreshToken"] as? Bool == true
    let tokenFailure = snapshot["errorCode"] as? String == "tokenRefreshFailed"
    recoveryAction = retryToken ? "refreshToken" : "rebindVideo"
    recoveryButton.accessibilityIdentifier = "customer_rtc." + recoveryAction
    recoveryButton.setTitle(retryToken ? "重试通话授权" : "恢复画面", for: .normal)
    recoveryButton.isHidden = mini || phase == "ending" || !(retryToken || needsRebind)
    recoveryButton.isEnabled = retryToken || canControl

    let notice: String?
    if restart { notice = "释放失败，请重启 App" }
    else if retryEnd { notice = "通话尚未结束，请重试" }
    else if phase == "ending" { notice = "正在结束通话" }
    else if tokenFailure { notice = "通话授权更新失败" }
    else if needsRebind { notice = "视频画面绑定失败" }
    else if snapshot["errorCode"] as? String != nil { notice = "通话操作异常" }
    else if snapshot["needsToken"] as? Bool == true { notice = "通话授权需要更新" }
    else if probe { notice = "窗口交互测试 · 无音视频" }
    else if phase == "reconnecting" { notice = "网络重连中" }
    else if surface && !hasRemoteVideo && phase != "connected" { notice = "等待对端画面" }
    else { notice = nil }
    status.text = notice ?? (mini ? (surface ? "视频通话" : waitingLabel.text) : nil)
    status.isHidden = compactCard || status.text == nil
    timeLabel.isHidden = !regularControls || businessDuration == nil || phase == "ending"
    timeCaption.isHidden = timeLabel.isHidden
    insetTime.isHidden = insetChrome.isHidden || callStartUptime == nil || phase == "ending"
    updateTimer()
    setNeedsLayout()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateTimer()
  }

  private func updateTimer() {
    timer?.invalidate()
    timer = nil
    guard window != nil, !isHidden, let start = callStartUptime,
          !timeLabel.isHidden || !insetTime.isHidden || !miniCard.isHidden else { return }
    let elapsed = frozenDuration ?? max(0, ProcessInfo.processInfo.systemUptime - start)
    let seconds = Int(elapsed)
    let duration = seconds < 3600 ? String(format: "%02d:%02d", seconds / 60, seconds % 60) :
      String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    timeLabel.text = duration
    if mini {
      cardCaption.text = duration
      miniCard.accessibilityValue = duration
    } else {
      insetTime.text = duration
    }
    guard frozenDuration == nil else { return }
    // Return to the actual next second boundary after UI stalls or a host handoff.
    let boundary = Date(timeIntervalSinceNow: Double(seconds + 1) - elapsed)
    let next = Timer(fire: boundary, interval: 0, repeats: false) { [weak self] _ in self?.updateTimer() }
    RunLoop.main.add(next, forMode: .common)
    timer = next
  }

  private func layoutRotatedSystemBarShades() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    statusBarShade.isHidden = true
    homeIndicatorShade.isHidden = true
    guard isFullScreenCall, rotated, let window, let scene = window.windowScene else { return }
    if let bar = scene.statusBarManager, !bar.isStatusBarHidden {
      let rect = convert(bar.statusBarFrame, from: scene.coordinateSpace).intersection(bounds)
      statusBarShade.frame = rect.isNull ? .zero : rect
      statusBarShade.isHidden = rect.isEmpty
    }
    let homeArea = window.bounds.divided(atDistance: window.safeAreaInsets.bottom, from: .maxYEdge).slice
    let rect = convert(homeArea, from: window).intersection(bounds)
    homeIndicatorShade.frame = rect.isNull ? .zero : rect
    homeIndicatorShade.isHidden = rect.isEmpty
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutRotatedSystemBarShades()
    var area = safeAreaLayoutGuide.layoutFrame
    let keyboardTop = keyboardLayoutGuide.layoutFrame.minY
    if keyboardTop > area.minY { area.size.height = min(area.height, keyboardTop - area.minY) }
    guard area.width > 0, area.height > 0 else { return }
    let toastSize = networkToast.sizeThatFits(area.size)
    networkToast.bounds.size = CGSize(width: min(area.width, toastSize.width + 28), height: min(area.height, toastSize.height + 16))
    networkToast.center = CGPoint(x: area.midX, y: area.midY)
    panel.transform = .identity
    let compactCard = !miniCard.isHidden
    if mini {
      if !compactCard { area = area.insetBy(dx: 4, dy: 4) }
      let size = compactCard ? callCardSize(width: area.width, height: area.height) :
        CGSize(width: min(190, max(0, area.width)), height: min(250, max(0, area.height)))
      let margin = compactCard ? min(16, (area.width - size.width) / 2) : 0
      var origin = dragPosition ?? CGPoint(x: area.maxX - size.width - margin,
                                           y: compactCard ? 105 : area.minY + 50)
      origin.x = min(max(area.minX, origin.x), area.maxX - size.width)
      origin.y = min(max(area.minY, origin.y), area.maxY - size.height)
      panel.frame = CGRect(origin: origin, size: size)
    } else {
      panel.bounds = CGRect(origin: .zero, size: rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
      panel.center = CGPoint(x: bounds.midX, y: bounds.midY)
      if rotated { panel.transform = CGAffineTransform(rotationAngle: .pi / 2) }
    }
    let b = panel.bounds
    panel.layer.cornerRadius = compactCard ? 20 * b.width / 84 : (mini ? 12 : 0)
    if compactCard {
      // A host can first attach while minimized. Keep both SDK canvases sized for binding.
      localVideo.frame = b
      remoteVideo.frame = b
      remoteVideo.layer.cornerRadius = 0
      miniCard.frame = b
      miniCard.layer.cornerRadius = panel.layer.cornerRadius
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      cardGradient.frame = b
      CATransaction.commit()
      layoutCard(in: b, avatar: cardAvatar, caption: cardCaption, border: cardBorder)
      return
    }
    let safe = mini ? b : panel.convert(area, from: self).intersection(b)
    guard !safe.isNull, !safe.isEmpty else { return }
    let (primary, secondary) = localPrimary ? (localVideo, remoteVideo) : (remoteVideo, localVideo)
    panel.sendSubviewToBack(primary)
    panel.insertSubview(primaryPlaceholder, aboveSubview: primary)
    panel.insertSubview(shade, aboveSubview: primaryPlaceholder)
    waitingBackground.frame = b
    primary.frame = b
    primaryPlaceholder.frame = b
    let avatarScale = min(100, b.width, b.height) / 180
    primaryAvatar.bounds.size = CGSize(width: 259 * avatarScale, height: 259 * avatarScale)
    primaryAvatar.center = CGPoint(x: b.midX, y: b.midY + 15.5 * avatarScale)
    primary.layer.cornerRadius = 0
    // The portrait artboard is 375 × 812. Keep its top bar clear of taller sensor housings.
    let compact = safe.height < 400
    let headerTop = max(safe.minY + 4, compact ? 4 : min(54, b.height * 54 / 812))
    let singleRow = !waiting && safe.height < 400 && safe.width >= 420
    let controlHeight: CGFloat = compact ? 64 : 83
    let rowSpacing: CGFloat = compact ? 4 : 18
    let bottom = min(b.maxY - (compact ? 4 : 37), safe.maxY - 2)
    let controlsTop = bottom - controlHeight - (singleRow ? 0 : controlHeight + rowSpacing)
    let sideY = mini ? 38 : min(headerTop + 51, safe.maxY)
    let trailing = min(safe.width, mini ? 5 : 16)
    let legacyWidth = min(b.width * 0.3, 60)
    let sideSize = mini ? CGSize(width: legacyWidth, height: legacyWidth * 1.3) :
      callCardSize(width: safe.width - trailing, height: controlsTop - sideY - 4)
    let sideWidth = sideSize.width
    let sideFrame = CGRect(origin: CGPoint(x: safe.maxX - sideWidth - trailing, y: sideY), size: sideSize)
    secondary.frame = sideFrame
    let cardScale = sideWidth / 84
    secondary.layer.cornerRadius = mini ? 8 : 20 * cardScale
    insetPlaceholder.frame = sideFrame
    let userBounds = localPrimary ? b : insetPlaceholder.bounds
    let avatarSize = min(localPrimary ? 100 : 58, userBounds.width, userBounds.height)
    localAvatar.bounds.size = CGSize(width: avatarSize, height: avatarSize)
    localAvatar.center = CGPoint(x: userBounds.midX, y: userBounds.midY)
    localAvatar.layer.cornerRadius = avatarSize / 2
    insetChrome.frame = sideFrame
    insetPlaceholder.layer.cornerRadius = 20 * cardScale
    insetChrome.layer.cornerRadius = 20 * cardScale
    layoutCard(in: insetChrome.bounds, avatar: insetAvatar, caption: insetTime, border: insetBorder)
    shade.frame = b
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradient.frame = shade.bounds
    insetGradient.frame = insetPlaceholder.bounds
    primaryGradient.frame = b
    CATransaction.commit()
    let inset: CGFloat = 12
    let clockWidth = min(169, max(0, safe.width - 140))
    let buttonTop = max(safe.minY, headerTop - 10)
    modeButton.frame = CGRect(x: safe.minX + inset, y: buttonTop, width: 44, height: 44)
    qualityButton.frame = CGRect(x: safe.maxX - inset - 70, y: buttonTop, width: 70, height: 44)
    qualityBackdrop.frame = b
    let menuWidth = min(120, max(0, safe.width - inset * 2))
    let menuHeight = min(96, safe.height)
    let headerBottom = (b.height < 400 ? safe.minY : max(44, safe.minY)) + min(60, b.height / 3)
    qualityMenu.frame = CGRect(x: safe.maxX - inset - menuWidth, y: min(headerBottom, safe.maxY - menuHeight),
                               width: menuWidth, height: menuHeight)
    sd.frame = CGRect(x: 0, y: 0, width: menuWidth, height: menuHeight / 2)
    hd.frame = sd.frame.offsetBy(dx: 0, dy: sd.frame.height)
    timeLabel.frame = CGRect(x: safe.midX - clockWidth / 2, y: headerTop, width: clockWidth, height: 24)
    timeCaption.frame = CGRect(x: safe.midX - clockWidth / 2, y: headerTop + 26, width: clockWidth, height: 24)
    let columns: CGFloat = singleRow ? 6 : 3
    let column = min(safe.width / columns, 109)
    let directionText = safe.width > safe.height ? "切换竖屏" : "切换横屏"
    orientation.configure(directionText, active: false)
    end.large = waiting
    if mini {
      status.frame = CGRect(x: 0, y: 0, width: b.width, height: 32)
      modeButton.frame = CGRect(x: max(0, b.midX - 64), y: max(32, b.maxY - 50), width: 50, height: 44)
      end.frame = CGRect(x: b.midX, y: max(32, b.maxY - 60), width: 64, height: 58)
    } else {
      let noticeWidth = waiting ? safe.width - 16 : min(260, safe.width - 2 * (sideWidth + 16))
      status.bounds.size = CGSize(width: max(0, noticeWidth), height: 27)
      status.center = CGPoint(x: safe.midX, y: headerTop + 66)
      recoveryButton.frame = CGRect(x: safe.midX - 52, y: status.frame.maxY + 4, width: 104, height: 44)
      if waiting {
        let cancelHeight: CGFloat = compact ? 64 : 93
        let cancelY = min(b.maxY - (compact ? cancelHeight + 4 : 143), safe.maxY - cancelHeight - 2)
        end.frame = CGRect(x: safe.midX - column / 2, y: cancelY, width: column, height: cancelHeight)
        let avatarTop = max(headerTop + 44, b.height * 250 / 812)
        let avatarSide = min(100, max(0, (cancelY - avatarTop - 25) * 0.58))
        // The export includes the shadow around the 200px avatar group.
        let imageSide = avatarSide * 259 / 200
        avatar.bounds.size = CGSize(width: imageSide, height: imageSide)
        avatar.center = CGPoint(x: safe.midX, y: avatarTop + avatarSide / 2)
        let labelWidth = max(0, min(safe.width - 24, 187.5))
        let labelY = avatarTop + avatarSide + (compact ? 8 : 20)
        let maxLabelHeight = max(0, cancelY - labelY)
        let textHeight = waitingLabel.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height
        waitingLabel.frame = CGRect(x: safe.midX - labelWidth / 2, y: labelY, width: labelWidth,
                                    height: min(maxLabelHeight, ceil(textHeight / 18) * 18))
      } else {
        for (index, button) in [mic, speaker, camera, orientation, end, flip].enumerated() {
          let col = singleRow ? index : index % 3
          let firstRow = !singleRow && index < 3
          button.frame = CGRect(x: safe.midX + (CGFloat(col) - columns / 2) * column,
                                y: bottom - controlHeight - (firstRow ? controlHeight + rowSpacing : 0),
                                width: column, height: controlHeight)
        }
      }
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }

  private func dismissQualityMenu() {
    qualityBackdrop.isHidden = true
    UIAccessibility.post(notification: .layoutChanged, argument: qualityButton)
  }

  override func accessibilityPerformEscape() -> Bool {
    if qualityBackdrop.isHidden { return super.accessibilityPerformEscape() }
    dismissQualityMenu()
    return true
  }

  private func send(_ action: String) { if let id = sessionId { onAction?(id, action) } }
  private func changeMode() { send(mini ? "restore" : "minimize") }
  @objc private func tapVideo() { if mini { changeMode() } }
  @objc private func pan(_ pan: UIPanGestureRecognizer) {
    guard pan.state == .began || pan.state == .changed || pan.state == .ended else { return }
    let delta = pan.translation(in: self)
    pan.setTranslation(.zero, in: self)
    moveMini(by: delta, dock: pan.state == .ended)
  }

  func moveMini(by delta: CGPoint, dock: Bool) {
    guard mini, sessionId != nil else { return }
    var origin = CGPoint(x: panel.frame.minX + delta.x, y: panel.frame.minY + delta.y)
    if dock {
      let area = safeAreaLayoutGuide.layoutFrame
      let inset = miniCard.isHidden ? 4 : min(16, max(0, area.width - panel.frame.width) / 2)
      origin.x = origin.x + panel.frame.width / 2 < area.midX ? area.minX + inset : area.maxX - panel.frame.width - inset
    }
    dragPosition = origin
    setNeedsLayout()
    layoutIfNeeded()
  }

  func minimizeForBack() -> Bool {
    guard sessionId != nil, !mini else { return false }
    changeMode()
    return true
  }
}

extension HostCallOverlay: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    touch.view === panel
  }
}

/// A single accessible button with its label below the circular control.
private final class CallActionButton: UIButton {
  private let icon = UIImageView(), caption = UILabel(), endGradient = CAGradientLayer()
  var large = false { didSet { if large != oldValue { setNeedsLayout() } } }

  init(icon name: String) {
    super.init(frame: .zero)
    icon.image = callIcon(name, size: 27.5)
    endGradient.colors = [UIColor(red: 1, green: 83.0/255, blue: 96.0/255, alpha: 0.9).cgColor,
                          UIColor(red: 1, green: 49.0/255, blue: 65.0/255, alpha: 1).cgColor]
    endGradient.locations = [0.17, 0.87]
    endGradient.startPoint = CGPoint(x: 0.2425, y: 0.0714)
    endGradient.endPoint = CGPoint(x: 0.7575, y: 0.9286)
    layer.addSublayer(endGradient)
    icon.contentMode = .center
    icon.clipsToBounds = true
    addSubview(icon)
    caption.textColor = .white
    caption.textAlignment = .center
    caption.font = .systemFont(ofSize: 13)
    caption.adjustsFontSizeToFitWidth = true
    addSubview(caption)
  }
  required init?(coder: NSCoder) { nil }
  override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.55 } }
  override var isHighlighted: Bool { didSet { icon.alpha = isHighlighted ? 0.65 : 1 } }

  func configure(_ label: String, active: Bool, destructive: Bool = false) {
    accessibilityLabel = label
    caption.text = label
    endGradient.isHidden = !destructive
    icon.backgroundColor = destructive ? .clear : UIColor.white.withAlphaComponent(active ? 0.94 : 0.30)
    icon.tintColor = active ? .black : .white
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let gap: CGFloat = bounds.height >= 80 ? 10 : 4
    let side = max(0, min(large ? 65 : 55, bounds.width - 4, bounds.height - gap - 18))
    icon.frame = CGRect(x: (bounds.width - side) / 2, y: 0, width: side, height: side)
    icon.layer.cornerRadius = side / 2
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    endGradient.frame = icon.frame
    endGradient.cornerRadius = side / 2
    CATransaction.commit()
    caption.frame = CGRect(x: 1, y: icon.frame.maxY + gap, width: max(0, bounds.width - 2), height: 18)
  }
}
