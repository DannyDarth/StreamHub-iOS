import SwiftUI
import WebKit

/// Crunchyroll: crunchyroll.com itself inside StreamHub, with your own sign-in (on Crunchyroll's
/// page; StreamHub never sees the password) and Crunchyroll's own player. Episodes are
/// copy-protected, so nothing is downloaded, recorded or bypassed.
struct CrunchyrollView: View {
    @ObservedObject private var browser = CrunchyrollBrowser.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!browser.canGoBack)
                    .accessibilityLabel("Back")
                Button { browser.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!browser.canGoForward)
                    .accessibilityLabel("Forward")
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Reload")
                Button { browser.goHome() } label: { Image(systemName: "house") }
                    .accessibilityLabel("Crunchyroll home")
                Spacer()
                if browser.loading {
                    ProgressView().controlSize(.small)
                }
                if browser.onEpisode {
                    Button {
                        browser.openInCrunchyrollApp()
                    } label: {
                        Label("App", systemImage: "arrow.up.forward.app")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("Watch in the Crunchyroll app")
                }
                Button {
                    if let url = browser.webView.url, CrunchyrollBrowser.allowed(url) { openURL(url) }
                } label: {
                    Image(systemName: "safari")
                }
                .accessibilityLabel("Open in Safari")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(red: 244/255, green: 117/255, blue: 33/255))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            CrunchyrollWebView(webView: browser.webView)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// One Crunchyroll page for the whole app, so switching tabs keeps your place (and what's playing).
final class CrunchyrollBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = CrunchyrollBrowser()
    static let home = URL(string: "https://www.crunchyroll.com/")!
    static let desktopScript = """
    (() => {
      if (!/(^|\\.)crunchyroll\\.com$/.test(location.hostname)) return;
      const define = (object, name, value) => {
        try { Object.defineProperty(object, name, { get: () => value, configurable: true }); } catch (e) {}
      };
      define(Navigator.prototype, "platform", "MacIntel");
      define(Navigator.prototype, "maxTouchPoints", 0);
      define(Navigator.prototype, "vendor", "Apple Computer, Inc.");
      define(Navigator.prototype, "standalone", undefined);
      try { delete window.ontouchstart; } catch (e) {}
      const realMatchMedia = window.matchMedia.bind(window);
      window.matchMedia = (query) => {
        if (/pointer\\s*:\\s*coarse|hover\\s*:\\s*none/.test(query)) {
          return Object.assign(realMatchMedia("not all"), { media: query });
        }
        return realMatchMedia(query);
      };
    })();
    """

    /// Safari on a Mac: what Safari on iPhone sends for "Request Desktop Website".
    static let desktopSafari = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    let webView: WKWebView
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var loading = false
    /// On an episode page (crunchyroll.com/…/watch/…).
    @Published private(set) var onEpisode = false
    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Crunchyroll's phone site won't play episodes ("get the app"). It tells phones apart by the
        // user agent, platform and touch screen: Crunchyroll's pages see what Safari on a Mac
        // reports, in every frame. The page itself keeps the phone's width (mobile content mode),
        // so Crunchyroll's own responsive layout fits the screen.
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.desktopScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if #available(iOS 16.4, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = Self.desktopSafari
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        if #available(iOS 16.4, *) {
            webView.isInspectable = false
        }
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                DispatchQueue.main.async { self?.loading = view.isLoading }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                let episode = view.url?.pathComponents.contains("watch") ?? false
                DispatchQueue.main.async { self?.onEpisode = episode }
            },
        ]
        webView.load(URLRequest(url: Self.home))
    }

    /// The episode in the Crunchyroll app (its link opens the app when it's installed), else the
    /// app's App Store page.
    func openInCrunchyrollApp() {
        guard let url = webView.url, Self.allowed(url) else { return }
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            if !opened, let store = URL(string: "https://apps.apple.com/app/crunchyroll/id329913454") {
                UIApplication.shared.open(store)
            }
        }
    }

    func goHome() {
        webView.load(URLRequest(url: Self.home))
    }

    /// Pages the Crunchyroll tab shows itself: Crunchyroll and its sign-in providers, over HTTPS.
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        let under = { (domain: String) in host == domain || host.hasSuffix("." + domain) }
        return under("crunchyroll.com") || host == "accounts.google.com" || host == "appleid.apple.com"
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.absoluteString == "about:blank" || url.scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if !mainFrame {
            // the player and sign-in use HTTPS frames of their own
            decisionHandler(url.scheme?.lowercased() == "https" ? .allow : .cancel)
            return
        }
        if Self.allowed(url) {
            decisionHandler(.allow)
            return
        }
        // Other sites open in Safari; App Store upsells and app links are ignored
        decisionHandler(.cancel)
        if url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
           host != "apps.apple.com", host != "itunes.apple.com" {
            UIApplication.shared.open(url)
        }
    }

    /// Links that open a new window (target="_blank") load in the same page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if Self.allowed(url) {
                webView.load(URLRequest(url: url))
            } else if url.scheme?.lowercased() == "https" {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }
}

private struct CrunchyrollWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // While the player is full screen, WebKit has moved the page into its own full-screen
        // window: taking it back here left a black screen
        if #available(iOS 16.0, *), webView.fullscreenState != .notInFullscreen { return }
        if webView.superview == nil { attach(to: container) }
    }

    private func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
