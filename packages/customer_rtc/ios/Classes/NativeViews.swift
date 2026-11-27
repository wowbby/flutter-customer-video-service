import Flutter
import UIKit
import WebKit

final class NativeViewFactory: NSObject, FlutterPlatformViewFactory {
  private let owner: CustomerRtcPlugin
  private let web: Bool
  init(owner: CustomerRtcPlugin, web: Bool) { self.owner = owner; self.web = web }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let params = args as? [String: Any] ?? [:]
    if web {
      let view = NativeWebView(frame: frame, id: viewId, html: params["html"] as? String ?? "", owner: owner)
      owner.addWeb(view, id: viewId)
      return view
    }
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

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
  weak var target: NativeWebView?
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.receive(message) }
}

// Serve the bundled document unchanged so WebKit sees its original doctype.
// A response header applies the policy before WebKit parses any markup.
private final class BundledDocument: NSObject, WKURLSchemeHandler {
  static let url = URL(string: "customer-rtc://bundle/index.html")!
  private let data: Data
  init(html: String) { data = Data(html.utf8) }
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard task.request.url == Self.url, task.request.httpMethod == "GET" else {
      task.didFailWithError(URLError(.unsupportedURL))
      return
    }
    let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
    let response = HTTPURLResponse(url: Self.url, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": policy])!
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class NativeWebView: NSObject, FlutterPlatformView, WKNavigationDelegate, WKUIDelegate {
  private let id: Int64
  private weak var owner: CustomerRtcPlugin?
  private let web: WKWebView
  private var disposed = false
  private var initialNavigation = true
  init(frame: CGRect, id: Int64, html: String, owner: CustomerRtcPlugin) {
    self.id = id; self.owner = owner
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(BundledDocument(html: html), forURLScheme: BundledDocument.url.scheme!)
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    let handler = WeakScriptHandler()
    config.userContentController.add(handler, name: "CustomerBridge")
    let source = "window.CustomerBridge = Object.freeze({postMessage: function(s) { if (typeof s === 'string') window.webkit.messageHandlers.CustomerBridge.postMessage(s); }});"
    config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    web = WKWebView(frame: frame, configuration: config)
    super.init()
    handler.target = self
    web.navigationDelegate = self; web.uiDelegate = self
    web.isOpaque = false; web.backgroundColor = .white
    web.scrollView.keyboardDismissMode = .interactive
    web.load(URLRequest(url: BundledDocument.url))
  }
  func view() -> UIView { web }
  func receive(_ message: WKScriptMessage) {
    guard !disposed, message.name == "CustomerBridge", message.frameInfo.isMainFrame,
          message.frameInfo.request.url == BundledDocument.url, web.url == BundledDocument.url,
          let text = message.body as? String, text.utf8.count <= 65536 else { return }
    owner?.emit(["type": "bridge", "viewId": id, "message": text])
  }
  func reply(_ json: String) {
    guard !disposed, web.url == BundledDocument.url else { return }
    web.evaluateJavaScript("if (typeof window.onNativeMessage === 'function') window.onNativeMessage(\(json));", completionHandler: nil)
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard !disposed, navigationAction.targetFrame?.isMainFrame == true,
          initialNavigation, navigationAction.request.url == BundledDocument.url else { decisionHandler(.cancel); return }
    initialNavigation = false
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !disposed, webView.url == BundledDocument.url else { return }
    owner?.emit(["type": "webReady", "viewId": id])
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
  @available(iOS 15.0, *)
  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
  func dispose() {
    guard !disposed else { return }
    disposed = true
    web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil
    web.configuration.userContentController.removeScriptMessageHandler(forName: "CustomerBridge")
    web.configuration.userContentController.removeAllUserScripts()
  }
  deinit { dispose() }
}
