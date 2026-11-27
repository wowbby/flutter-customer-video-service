import Flutter
import UIKit

final class NativeVideoFactory: NSObject, FlutterPlatformViewFactory {
  private let owner: CustomerRtcPlugin
  init(owner: CustomerRtcPlugin) { self.owner = owner }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let params = args as? [String: Any] ?? [:]
    let view = NativeVideoView(frame: frame, id: viewId, role: params["role"] as? String ?? "remote", probe: params["probe"] as? Bool ?? false, owner: owner)
    owner.addVideo(view, id: viewId)
    return view
  }
}

final class NativeVideoView: NSObject, FlutterPlatformView {
  let role: String
  let probe: Bool
  private let id: Int64
  private weak var owner: CustomerRtcPlugin?
  private let container: UIView
  init(frame: CGRect, id: Int64, role: String, probe: Bool, owner: CustomerRtcPlugin) {
    self.role = role; self.probe = probe; self.id = id; self.owner = owner
    container = UIView(frame: frame)
    super.init()
    container.backgroundColor = .black
    container.clipsToBounds = true
    if probe {
      container.backgroundColor = UIColor(red: 0.08, green: 0.25, blue: 0.29, alpha: 1)
      let label = UILabel()
      label.text = "NATIVE iOS\n\(role.uppercased())\n无音视频"
      label.numberOfLines = 3; label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.35; label.textAlignment = .center; label.textColor = .white
      label.font = .systemFont(ofSize: 12, weight: .semibold)
      label.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(label)
      NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: container.centerXAnchor), label.centerYAnchor.constraint(equalTo: container.centerYAnchor), label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor), label.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor)])
    }
  }
  func view() -> UIView { container }
  deinit { if !probe { owner?.removeVideo(id, role: role) } }
}
