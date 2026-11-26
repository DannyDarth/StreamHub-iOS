import SwiftUI
import WebKit

/// SponsorBlock (sponsor.ajay.app): segments the community marked in a video.
enum SponsorBlock {
    struct Segment: Codable, Hashable {
        let segment: [Double]
        let category: String
        let UUID: String
    }

    static let names: [String: String] = [
        "sponsor": "sponsor", "selfpromo": "self-promotion", "interaction": "like and subscribe reminder",
        "intro": "intro", "outro": "outro", "preview": "preview", "music_offtopic": "non-music part",
        "filler": "filler",
    ]

    static func segments(_ id: String, categories: [String]) async -> [Segment] {
        guard !categories.isEmpty,
              let list = String(data: (try? JSONSerialization.data(withJSONObject: categories)) ?? Data(), encoding: .utf8),
              var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments") else { return [] }
        components.queryItems = [URLQueryItem(name: "videoID", value: id), URLQueryItem(name: "categories", value: list)]
        guard let url = components.url,
              let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200, result.0.count < 1_000_000 else { return [] }
        return (try? JSONDecoder().decode([Segment].self, from: result.0))?
            .filter { $0.segment.count == 2 && $0.segment[1] > $0.segment[0] } ?? []
    }
}

/// YouTube's own player (YouTube's mobile page, shown as just its player), so YouTube's player
/// gets the stream the way YouTube expects. Ads are taken out of YouTube's
/// answers before the player sees them (the same idea as uBlock Origin), ad servers are blocked,
/// and if YouTube still starts an ad it's covered, muted and skipped: you never see or hear it.
/// SponsorBlock skips in the page.
@MainActor
final class YouTubeWebPlayer: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published var adHidden = false
    @Published var toast: String?
    @Published var failed: String?
    let webView: WKWebView
    private let video: YTVideo
    private var toastTask: Task<Void, Never>?
    private var segmentsJSON = "[]"

    static let skipCategories = ["sponsor", "selfpromo", "interaction"]

    init(video: YTVideo) {
        self.video = video
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.noAdsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakHandler(self), name: "streamhub")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        if #available(iOS 16.4, *) { webView.isInspectable = false }
    }

    func start() async {
        if let rules = await Self.blockList() {
            webView.configuration.userContentController.add(rules)
        }
        load()
        let segments = video.live ? [] : await SponsorBlock.segments(video.id, categories: Self.skipCategories)
        sendSegments(segments)
    }

    private func sendSegments(_ segments: [SponsorBlock.Segment]) {
        let items = segments.map { ["start": $0.segment[0], "end": $0.segment[1], "id": $0.UUID,
                                    "name": SponsorBlock.names[$0.category] ?? $0.category] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: items), let json = String(data: data, encoding: .utf8) {
            segmentsJSON = json
            webView.evaluateJavaScript("window.__streamhubSegments = \(json);", completionHandler: nil)
        }
    }

    /// YouTube's mobile page for the video, shown as just its player. (YouTube's embedded
    /// player refuses apps: errors 152 and 153.)
    private func load() {
        webView.load(URLRequest(url: URL(string: "https://m.youtube.com/watch?v=\(video.id)")!))
    }

    func stop() {
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())", completionHandler: nil)
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    // The page's reports: an ad is being hidden, or a SponsorBlock skip.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.securityOrigin.host.hasSuffix("youtube.com"),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ad":
            adHidden = (body["on"] as? Bool) ?? false
        case "skip":
            show("Skipped \(body["name"] as? String ?? "segment")")
        case "ready":
            webView.evaluateJavaScript("window.__streamhubSegments = \(segmentsJSON);", completionHandler: nil)
        default:
            break
        }
    }

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" { decisionHandler(.allow); return }
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            decisionHandler(.cancel); return
        }
        let ok = ["youtube.com", "google.com", "gstatic.com", "ytimg.com", "googlevideo.com", "youtube-nocookie.com"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
        if action.targetFrame?.isMainFrame == false {
            decisionHandler(ok ? .allow : .cancel)
            return
        }
        // the page stays on this video: other links (another video, the YouTube logo) are ignored
        let sameVideo = url.path.hasSuffix("/" + video.id) || url.query?.contains("v=\(video.id)") == true
        let consent = host.hasSuffix("google.com") || host.hasPrefix("consent.")
        let allow = ok && (sameVideo || consent)
        if !allow && !loadedOnce {
            // the first page never showed: say which address was refused instead of a black screen
            failed = "YouTube sent StreamHub to a page it doesn't open: \(host)\(url.path)"
        }
        decisionHandler(allow ? .allow : .cancel)
    }

    private var loadedOnce = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadedOnce = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failed = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled, !loadedOnce { failed = error.localizedDescription }
    }

    // MARK: - Ad blocking

    /// Requests that only serve ads or ad tracking.
    private static func blockList() async -> WKContentRuleList? {
        // WebKit's rule patterns have no "or": one rule per pattern
        let rules = #"""
        [
          {"trigger":{"url-filter":"^https?://([^/]*\\.)?doubleclick\\.net/"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://([^/]*\\.)?googleadservices\\.com/"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://([^/]*\\.)?googlesyndication\\.com/"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://([^/]*\\.)?googletagservices\\.com/"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://[^/]*youtube\\.com/pagead/"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://[^/]*youtube\\.com/api/stats/ads"},"action":{"type":"block"}},
          {"trigger":{"url-filter":"^https?://[^/]*youtube\\.com/get_midroll_info"},"action":{"type":"block"}}
        ]
        """#
        return try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "streamhub-youtube-ads", encodedContentRuleList: rules)
    }

    /// Runs in YouTube's pages before YouTube's own scripts.
    static let noAdsScript = #"""
    (() => {
      if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname)) return;
      const post = (data) => { try { window.webkit.messageHandlers.streamhub.postMessage(data); } catch (e) {} };
      // 1. take the ads out of YouTube's answers before the player reads them
      const AD_KEYS = ["adPlacements", "adSlots", "playerAds", "adBreakHeartbeatParams"];
      const prune = (o, depth = 0) => {
        if (!o || typeof o !== "object" || depth > 6) return o;
        for (const k of AD_KEYS) if (k in o) { try { delete o[k]; } catch (e) {} }
        if (Array.isArray(o)) { o.forEach((x) => prune(x, depth + 1)); return o; }
        for (const k of ["playerResponse", "response", "data"]) if (o[k]) prune(o[k], depth + 1);
        return o;
      };
      const parse = JSON.parse;
      JSON.parse = function () { return prune(parse.apply(this, arguments)); };
      const json = Response.prototype.json;
      Response.prototype.json = function () { return json.apply(this, arguments).then((v) => prune(v)); };
      for (const name of ["ytInitialPlayerResponse"]) {
        let value;
        try {
          Object.defineProperty(window, name, { configurable: true, get: () => value, set: (v) => { value = prune(v); } });
        } catch (e) {}
      }
      // 2. if YouTube still starts an ad: StreamHub covers the player, and the ad is muted and skipped
      let inAd = false, wasMuted = false;
      setInterval(() => {
        const player = document.querySelector(".html5-video-player");
        const video = document.querySelector("video");
        const ad = !!(player && (player.classList.contains("ad-showing") || player.classList.contains("ad-interrupting")));
        if (ad && video) {
          if (!inAd) { inAd = true; wasMuted = video.muted; post({ kind: "ad", on: true }); }
          video.muted = true;
          try { video.playbackRate = 16; } catch (e) {}
          if (isFinite(video.duration) && video.duration > 0) video.currentTime = video.duration;
          document.querySelectorAll(".ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-container button")
            .forEach((b) => b.click());
        } else if (inAd) {
          inAd = false;
          if (video) { video.muted = wasMuted; video.playbackRate = 1; }
          post({ kind: "ad", on: false });
        }
        // 3. SponsorBlock: skip the marked segments
        if (!ad && video && Array.isArray(window.__streamhubSegments)) {
          window.__streamhubSkipped = window.__streamhubSkipped || {};
          for (const s of window.__streamhubSegments) {
            if (video.currentTime >= s.start && video.currentTime < s.end - 0.5 && !window.__streamhubSkipped[s.id]) {
              window.__streamhubSkipped[s.id] = true;
              video.currentTime = s.end;
              post({ kind: "skip", name: s.name });
            }
          }
        }
      }, 250);
      // 4. on YouTube's mobile page: start playing with sound (YouTube starts it muted), and show
      //    only the player. Only what's beside the player is hidden, never what holds it.
      if (location.hostname === "m.youtube.com" && window.top === window) {
        let unmuted = false;
        const isolate = () => {
          const holder = document.querySelector("#player-container-id")
            || (document.querySelector(".html5-video-player") || {}).parentElement;
          if (!holder) return;
          let node = holder;
          while (node && node !== document.documentElement) {
            const parent = node.parentElement;
            if (!parent) break;
            for (const sibling of parent.children) {
              if (sibling !== node && !sibling.contains(holder) && !/^(SCRIPT|STYLE|LINK)$/.test(sibling.tagName)) {
                sibling.style.setProperty("display", "none", "important");
              }
            }
            node = parent;
          }
          for (const [k, v] of Object.entries({ position: "fixed", top: "0", left: "0", width: "100vw", height: "100vh",
                                                "max-height": "none", margin: "0", padding: "0", "z-index": "2147483000", background: "#000" })) {
            holder.style.setProperty(k, v, "important");
          }
          document.documentElement.style.setProperty("background", "#000", "important");
          document.body && document.body.style.setProperty("overflow", "hidden", "important");
        };
        const tick = setInterval(() => {
          isolate();
          const video = document.querySelector("video");
          const player = document.querySelector(".html5-video-player");
          const ad = player && player.classList.contains("ad-showing");
          if (video && video.readyState > 0 && !ad) {
            if (video.paused && !unmuted) {
              video.play().catch(() => document.querySelector(".ytp-large-play-button, .ytmCuedOverlayPlayButton")?.click());
            }
            if (!unmuted && !video.paused) {
              unmuted = true;
              video.muted = false;
              try { player && player.unMute && player.unMute(); } catch (e) {}
              document.querySelectorAll(".ytp-unmute, .ytmUnmuteButton, .unmute-button, button[aria-label*='nmute']").forEach((b) => b.click());
            }
          }
        }, 500);
        setTimeout(() => clearInterval(tick), 120000);
      }
      document.addEventListener("DOMContentLoaded", () => post({ kind: "ready" }));
    })();
    """#
}

/// WebKit holds script message handlers strongly: this keeps the player from never being freed.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// The video that's playing. It plays right where it is in the list (in place of its
/// thumbnail), one at a time; Full screen turns the phone sideways and fills the screen.
@MainActor
final class YouTubePlayerHost: ObservableObject {
    static let shared = YouTubePlayerHost()
    @Published private(set) var player: YouTubeWebPlayer?
    @Published private(set) var video: YTVideo?
    @Published var fullScreen = false {
        didSet { if fullScreen != oldValue { Self.rotate(landscape: fullScreen) } }
    }

    func isPlaying(_ video: YTVideo) -> Bool { self.video?.id == video.id && player != nil }

    func play(_ video: YTVideo) {
        guard self.video?.id != video.id else { return }
        player?.stop()
        let player = YouTubeWebPlayer(video: video)
        self.player = player
        self.video = video
        Task { await player.start() }
    }

    /// Stop the video (it was closed, or scrolled out of sight).
    func close(_ video: YTVideo? = nil) {
        if let video, video.id != self.video?.id { return }
        fullScreen = false
        player?.stop()
        player = nil
        self.video = nil
    }

    private static func rotate(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
    }
}

/// A video playing in its place in the list, edge to edge, with a bar of its own below it.
struct InlineYouTubePlayer: View {
    @ObservedObject var host = YouTubePlayerHost.shared
    let video: YTVideo
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player = host.player, !host.fullScreen {
                PlayerStage(player: player, video: video, mini: false)
                    .aspectRatio(16 / 9, contentMode: .fit)
            } else {
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
            }
            HStack(spacing: 18) {
                Label("No ads · SponsorBlock", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.green)
                Spacer()
                Button { host.fullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Full screen")
                Button {
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") { openURL(url) }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .accessibilityLabel("Open in the YouTube app")
                Button { host.close() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Stop the video")
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
        }
        // scrolled out of sight: the video stops
        .onDisappear { if !host.fullScreen { host.close(video) } }
    }
}

/// Full screen: the phone turns sideways and the video fills it. × (or turning back) leaves.
struct FullScreenYouTubePlayer: View {
    @ObservedObject var host = YouTubePlayerHost.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player = host.player, let video = host.video {
                PlayerStage(player: player, video: video, mini: false)
                    .ignoresSafeArea()
            }
            Button { host.fullScreen = false } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(12)
            .accessibilityLabel("Leave full screen")
        }
        .statusBarHidden()
    }
}

/// The video itself and what StreamHub shows over it (ad being skipped, SponsorBlock skips).
private struct PlayerStage: View {
    @ObservedObject var player: YouTubeWebPlayer
    let video: YTVideo
    let mini: Bool

    var body: some View {
        ZStack {
            Color.black
            PlayerWebView(webView: player.webView)
                .allowsHitTesting(!mini)
            if player.adHidden {
                ZStack {
                    Color.black
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        if !mini { Text("Skipping an ad…").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if let message = player.failed {
                ZStack {
                    Color.black
                    Text(message).font(mini ? .caption2 : .subheadline).multilineTextAlignment(.center).padding()
                }
            }
            if let toast = player.toast, !mini {
                VStack {
                    Text(toast)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: player.toast)
    }
}

/// Holds the player's web view; a new video's web view replaces the old one in place.
private struct PlayerWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        container.subviews.forEach { $0.removeFromSuperview() }
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
