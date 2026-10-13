// Oki for iPhone: a thin shell around the web app. Everything (screens, data, sync) lives on the site,
// so updates arrive by themselves; this file changes only when the shell itself needs something new.
import UIKit
import WebKit

let site = URL(string: "https://meowmeowwwwwwwwwww.github.io/oki/")!
let mist = UIColor(red: 0xE9 / 255, green: 0xEB / 255, blue: 0xF0 / 255, alpha: 1)

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let c = UISceneConfiguration(name: nil, sessionRole: session.role)
    c.delegateClass = SceneDelegate.self
    return c
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let ws = scene as? UIWindowScene else { return }
    let w = UIWindow(windowScene: ws)
    w.backgroundColor = mist
    w.rootViewController = WebController()
    w.makeKeyAndVisible()
    window = w
  }
}

final class WebController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
  private var web: WKWebView!
  private var bottom: NSLayoutConstraint!

  override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

  override func loadView() {
    let cfg = WKWebViewConfiguration()
    // the site is an app-bound domain (Info.plist): this keeps its service worker, so Oki opens offline too
    cfg.limitsNavigationsToAppBoundDomains = true
    cfg.allowsInlineMediaPlayback = true
    cfg.websiteDataStore = .default()
    // the web app tells the shell where Даша's repo is, so «Отправить заметки в Oki» can reach it (Notes.swift)
    cfg.userContentController.add(self, name: "oki")
    web = WKWebView(frame: .zero, configuration: cfg)
    web.isOpaque = false
    web.backgroundColor = mist
    web.scrollView.backgroundColor = mist
    web.scrollView.contentInsetAdjustmentBehavior = .never // the page handles the notch itself (viewport-fit=cover)
    web.scrollView.bounces = false
    web.allowsLinkPreview = false
    web.navigationDelegate = self
    web.uiDelegate = self
    // the page ends where the keyboard begins: otherwise the keyboard covers the field you type in
    let root = UIView()
    root.backgroundColor = mist
    web.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(web)
    bottom = web.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    NSLayoutConstraint.activate([
      web.topAnchor.constraint(equalTo: root.topAnchor),
      web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      bottom,
    ])
    view = root
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    hideFormBar()
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(keyboard), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    nc.addObserver(self, selector: #selector(keyboard), name: UIResponder.keyboardWillHideNotification, object: nil)
    web.load(URLRequest(url: site))
  }

  // keyboard up: the page gets shorter by the part the keyboard covers; keyboard down: full screen again
  @objc private func keyboard(_ n: Notification) {
    guard let info = n.userInfo, let end = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
    let kb = view.convert(end, from: nil)
    let cover = n.name == UIResponder.keyboardWillHideNotification ? 0 : max(0, view.bounds.maxY - kb.minY)
    if bottom.constant == -cover { return }
    let time = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
    bottom.constant = -cover
    UIView.animate(withDuration: time, delay: 0, options: UIView.AnimationOptions(rawValue: curve << 16)) {
      self.view.layoutIfNeeded()
    }
  }

  // no «˄ ˅ ✓» bar above the keyboard: the page has its own buttons. WebKit's text view is a private class,
  // so we give it a subclass that answers «no accessory view» (the same trick Capacitor and Cordova use).
  private func hideFormBar() {
    guard let content = web.scrollView.subviews.first(where: { String(describing: type(of: $0)).hasPrefix("WKContent") }),
          let base: AnyClass = object_getClass(content) else { return }
    let name = "OkiNoBar_" + NSStringFromClass(base)
    var cls: AnyClass? = NSClassFromString(name)
    if cls == nil, let made = objc_allocateClassPair(base, name, 0) {
      let none: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
      let sel = #selector(getter: UIResponder.inputAccessoryView)
      class_addMethod(made, sel, imp_implementationWithBlock(none), "@@:")
      objc_registerClassPair(made)
      cls = made
    }
    if let cls { object_setClass(content, cls) }
  }

  // {token, owner, repo, key} after the repo is connected; null when it is forgotten
  func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
    guard m.frameInfo.isMainFrame, m.frameInfo.securityOrigin.host == site.host else { return }
    guard let d = m.body as? [String: Any], let token = d["token"] as? String, let owner = d["owner"] as? String,
          let repo = d["repo"] as? String, let key = d["key"] as? String else { return Repo.save(nil) }
    Repo.save(.init(token: token, owner: owner, repo: repo, key: key))
  }

  private func ours(_ url: URL) -> Bool {
    url.host == site.host || url.scheme == "about"
  }

  // links to other sites (GitHub, Telegram) open in Safari, Oki itself stays here
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url else { return decisionHandler(.cancel) }
    if action.targetFrame?.isMainFrame != false && !ours(url) {
      UIApplication.shared.open(url)
      return decisionHandler(.cancel)
    }
    decisionHandler(.allow)
  }

  // target="_blank"
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard let url = action.request.url else { return nil }
    if ours(url) { webView.load(action.request) } else { UIApplication.shared.open(url) }
    return nil
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    showOffline(error)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    showOffline(error)
  }

  private func showOffline(_ error: Error) {
    if (error as NSError).code == NSURLErrorCancelled { return }
    guard let f = Bundle.main.url(forResource: "Offline", withExtension: "html"),
          let html = try? String(contentsOf: f, encoding: .utf8) else { return }
    web.loadHTMLString(html, baseURL: site)
  }

  // iOS may stop the page in the background to free memory: open it again
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    webView.load(URLRequest(url: site))
  }
}
