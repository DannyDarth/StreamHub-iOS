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
        webView.scrollView.isScrollEnabled = false
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
        decisionHandler(ok && (sameVideo || consent) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed = error.localizedDescription
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
      // 4. show only the player: YouTube's mobile page around it (top bar, comments, other
      //    videos) is hidden, and the player fills StreamHub's video box
      if (location.hostname === "m.youtube.com" && window.top === window) {
        const css = `
          html, body { background: #000 !important; overflow: hidden !important; }
          ytm-mobile-topbar-renderer, .mobile-topbar-header, header, ytm-pivot-bar-renderer,
          ytm-single-column-watch-next-results-renderer, ytm-item-section-renderer, .watch-below-the-player,
          ytm-engagement-panel, .ytm-autonav-bar, ytm-companion-slot { display: none !important; }
          #player-container-id, .player-container, #player-control-container {
            position: fixed !important; top: 0 !important; left: 0 !important; right: 0 !important;
            width: 100vw !important; height: 100vh !important; max-height: none !important;
            z-index: 2147483000 !important; background: #000 !important; padding: 0 !important; margin: 0 !important;
          }
          #player, .html5-video-player, .html5-video-container, video {
            width: 100% !important; height: 100% !important; max-height: none !important;
          }
          video { object-fit: contain !important; left: 0 !important; top: 0 !important; }
        `;
        const style = document.createElement("style");
        style.textContent = css;
        const add = () => { if (!style.isConnected) (document.head || document.documentElement).appendChild(style); };
        add();
        document.addEventListener("DOMContentLoaded", add);
        // start playing once the player is there (the mobile page waits for a tap otherwise)
        let tries = 0;
        const start = setInterval(() => {
          const video = document.querySelector("video");
          if (video && video.readyState > 0) {
            clearInterval(start);
            video.play().catch(() => document.querySelector(".ytp-large-play-button, .ytmCuedOverlayPlayButton, button.icon-button")?.click());
          } else if (++tries > 80) clearInterval(start);
        }, 250);
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

struct YouTubePlayerScreen: View {
    let video: YTVideo
    @StateObject private var player: YouTubeWebPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(video: YTVideo) {
        self.video = video
        _player = StateObject(wrappedValue: YouTubeWebPlayer(video: video))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    player.stop()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                }
                .accessibilityLabel("Close")
                Spacer()
                Button {
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") { openURL(url) }
                } label: {
                    Label("YouTube", systemImage: "arrow.up.forward.app")
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 16)

            ZStack {
                PlayerWebView(webView: player.webView)
                if player.adHidden {
                    ZStack {
                        Color.black
                        VStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Skipping an ad…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let message = player.failed {
                    ZStack {
                        Color.black
                        Text(message).font(.subheadline).multilineTextAlignment(.center).padding()
                    }
                }
                if let toast = player.toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 44)
                    }
                    .transition(.opacity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(Color.black)
            .animation(.default, value: player.toast)

            VStack(alignment: .leading, spacing: 6) {
                Text(video.title).font(.headline)
                Text([video.channel, video.views, video.published].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                Label("No ads · SponsorBlock skips sponsors, self-promotion and reminders",
                      systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.green)
            }
            .padding(.horizontal, 16)
            Spacer()
        }
        .padding(.top, 8)
        .background(Color(uiColor: .systemBackground))
        .task { await player.start() }
        .onDisappear { player.stop() }
    }
}

private struct PlayerWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
