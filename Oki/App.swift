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

final class WebController: UIViewController, WKNavigationDelegate, WKUIDelegate {
  private var web: WKWebView!

  override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

  override func loadView() {
    let cfg = WKWebViewConfiguration()
    // the site is an app-bound domain (Info.plist): this keeps its service worker, so Oki opens offline too
    cfg.limitsNavigationsToAppBoundDomains = true
    cfg.allowsInlineMediaPlayback = true
    cfg.websiteDataStore = .default()
    web = WKWebView(frame: .zero, configuration: cfg)
    web.isOpaque = false
    web.backgroundColor = mist
    web.scrollView.backgroundColor = mist
    web.scrollView.contentInsetAdjustmentBehavior = .never // the page handles the notch itself (viewport-fit=cover)
    web.scrollView.bounces = false
    web.allowsLinkPreview = false
    web.navigationDelegate = self
    web.uiDelegate = self
    view = web
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    web.load(URLRequest(url: site))
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
    if let url = action.request.url { ours(url) ? webView.load(action.request) : UIApplication.shared.open(url) }
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
