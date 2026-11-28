import CryptoKit
import SwiftUI
import WebKit

/// SponsorBlock (sponsor.ajay.app): segments the community marked in a video.
enum SponsorBlock {
    struct Segment: Codable, Hashable {
        let segment: [Double]
        let category: String
        let UUID: String
    }

    enum Action: String, CaseIterable, Codable {
        case skip, ask, off
        var label: String {
            switch self {
            case .skip: return "Skip automatically"
            case .ask: return "Show a Skip button"
            case .off: return "Don't skip"
            }
        }
    }

    /// The categories in the order Settings lists them, with what each one means.
    struct Category: Identifiable {
        let id: String
        let title: String
        let detail: String
        init(_ id: String, _ title: String, _ detail: String) {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    static let categories: [Category] = [
        Category("sponsor", "Sponsor", "Paid promotions and sponsored segments"),
        Category("selfpromo", "Self-promotion", "Merch, Patreon, the creator's other channels"),
        Category("interaction", "Interaction reminder", "\"Like and subscribe\" reminders"),
        Category("intro", "Intro", "Intro animations and openings"),
        Category("outro", "Outro", "End cards and credits"),
        Category("preview", "Preview / recap", "Previews of what's coming, recaps of earlier episodes"),
        Category("filler", "Filler", "Tangents and jokes off the main topic"),
        Category("music_offtopic", "Non-music part", "In music videos, the parts that aren't music"),
    ]

    static let defaults: [String: Action] = [
        "sponsor": .skip, "selfpromo": .skip, "interaction": .skip,
        "intro": .ask, "outro": .ask, "preview": .off, "filler": .off, "music_offtopic": .off,
    ]

    private static let settingsKey = "streamhub.sponsorBlock"

    /// What to do with each category (Settings → YouTube).
    static var actions: [String: Action] {
        get {
            guard let data = UserDefaults.standard.data(forKey: settingsKey),
                  let saved = try? JSONDecoder().decode([String: Action].self, from: data) else { return defaults }
            return defaults.merging(saved) { _, new in new }
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: settingsKey) }
        }
    }

    static let names: [String: String] = [
        "sponsor": "sponsor", "selfpromo": "self-promotion", "interaction": "like and subscribe reminder",
        "intro": "intro", "outro": "outro", "preview": "preview", "music_offtopic": "non-music part",
        "filler": "filler",
    ]

    private static let cacheKey = "streamhub.sponsorBlockCache"
    private static let cacheHours: Double = 6

    /// The video's segments for these categories. Fast path: SponsorBlock's hash-prefix lookup
    /// (the one its own extension uses, well cached) with a 4-second limit, then the plain lookup;
    /// answers are remembered for 6 hours.
    static func segments(_ id: String, categories: [String]) async -> [Segment] {
        guard !categories.isEmpty else { return [] }
        let keep = { (all: [Segment]) in
            all.filter { categories.contains($0.category) && $0.segment.count == 2 && $0.segment[1] > $0.segment[0] }
        }
        if let all = cached(id) { return keep(all) }
        let everyCategory = String(data: (try? JSONSerialization.data(withJSONObject: Self.categories.map(\.id))) ?? Data(),
                                   encoding: .utf8) ?? "[]"
        var found: [Segment]?
        if let prefix = sha256Prefix(id),
           var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)") {
            components.queryItems = [URLQueryItem(name: "categories", value: everyCategory)]
            if let url = components.url, let (data, status) = await get(url, seconds: 4) {
                struct Video: Decodable { let videoID: String; let segments: [Segment] }
                if status == 404 { found = [] }
                else if status == 200, let videos = try? JSONDecoder().decode([Video].self, from: data) {
                    found = videos.first { $0.videoID == id }?.segments ?? []
                }
            }
        }
        if found == nil, var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments") {
            components.queryItems = [URLQueryItem(name: "videoID", value: id), URLQueryItem(name: "categories", value: everyCategory)]
            if let url = components.url, let (data, status) = await get(url, seconds: 8) {
                if status == 404 { found = [] }
                else if status == 200 { found = try? JSONDecoder().decode([Segment].self, from: data) }
            }
        }
        guard let all = found else { return [] }
        remember(id, all)
        return keep(all)
    }

    private static func get(_ url: URL, seconds: Double) async -> (Data, Int)? {
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: seconds)),
              data.count < 2_000_000 else { return nil }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func sha256Prefix(_ id: String) -> String? {
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(4).description
    }

    private struct Cached: Codable { let at: Date; let segments: [Segment] }

    private static func cached(_ id: String) -> [Segment]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let all = try? JSONDecoder().decode([String: Cached].self, from: data),
              let entry = all[id], Date().timeIntervalSince(entry.at) < cacheHours * 3600 else { return nil }
        return entry.segments
    }

    private static func remember(_ id: String, _ segments: [Segment]) {
        var all = (UserDefaults.standard.data(forKey: cacheKey))
            .flatMap { try? JSONDecoder().decode([String: Cached].self, from: $0) } ?? [:]
        all = all.filter { Date().timeIntervalSince($0.value.at) < cacheHours * 3600 }
        all[id] = Cached(at: Date(), segments: segments)
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: cacheKey) }
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

    /// A segment with a Skip button showing (SponsorBlock "Show a Skip button").
    @Published var offered: (id: String, name: String)?

    /// `shorts`: a Short in the Shorts tab (loops; held paused and muted until it's on screen;
    /// sound set by StreamHub's button, with YouTube's own unmute button hidden).
    init(video: YTVideo, shorts: Bool = false) {
        self.video = video
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.noAdsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if shorts {
            configuration.userContentController.addUserScript(
                WKUserScript(source: Self.shortsScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakHandler(self), name: "streamhub")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        if #available(iOS 16.4, *) { webView.isInspectable = false }
    }

    func start() async {
        // SponsorBlock starts loading right away, alongside the page
        let actions = SponsorBlock.actions
        let categories = SponsorBlock.categories.map(\.id).filter { (actions[$0] ?? .off) != .off }
        let id = video.id, live = video.live
        let segmentsTask = Task.detached { live ? [] : await SponsorBlock.segments(id, categories: categories) }
        if let rules = await Self.blockList() {
            webView.configuration.userContentController.add(rules)
        }
        load()
        sendSegments(await segmentsTask.value, actions: actions)
    }

    private func sendSegments(_ segments: [SponsorBlock.Segment], actions: [String: SponsorBlock.Action]) {
        let items = segments.map { ["start": $0.segment[0], "end": $0.segment[1], "id": $0.UUID,
                                    "name": SponsorBlock.names[$0.category] ?? $0.category,
                                    "ask": actions[$0.category] == .ask] as [String: Any] }
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
        case "offer":
            if let id = body["id"] as? String { offered = (id, body["name"] as? String ?? "segment") }
        case "offer-end":
            if (body["id"] as? String) == offered?.id { offered = nil }
        case "ready":
            webView.evaluateJavaScript("window.__streamhubSegments = \(segmentsJSON);", completionHandler: nil)
        default:
            break
        }
    }

    /// Full screen in iPhone's own video player (what YouTube's full-screen button does here).
    /// False if the page didn't allow it.
    func enterFullScreen() async -> Bool {
        let script = """
        const video = document.querySelector("video");
        if (!video || !video.webkitEnterFullscreen) return false;
        try { video.webkitEnterFullscreen(); } catch (e) { return false; }
        await new Promise((done) => setTimeout(done, 600));
        return Boolean(video.webkitDisplayingFullscreen || document.webkitFullscreenElement || document.fullscreenElement);
        """
        let result = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        return (result as? Bool) ?? false
    }

    /// Shorts: on screen (plays, with the sound as `sound` says) or held (paused and muted).
    func shortsState(active: Bool, sound: Bool, unpause: Bool = false) {
        let extra = unpause ? ", paused: false" : ""
        webView.evaluateJavaScript(
            "window.__sh = Object.assign(window.__sh || {}, { hold: \(!active), sound: \(sound)\(extra) }); window.__shApply && window.__shApply();",
            completionHandler: nil)
    }

    /// Shorts: pause or play (tap on the Short).
    func togglePause() {
        webView.evaluateJavaScript(
            "window.__sh = window.__sh || {}; window.__sh.paused = !window.__sh.paused; window.__shApply && window.__shApply();",
            completionHandler: nil)
    }

    /// Kept in step with the Shorts tab: loops, holds it paused and muted until it's on screen,
    /// and sets the sound through YouTube's player (setting the video's own `muted` isn't enough:
    /// the player mutes it again). YouTube's unmute button is hidden: StreamHub's does it.
    static let shortsScript = #"""
    (() => {
      window.__sh = Object.assign({ hold: true, sound: false, paused: false }, window.__sh || {});
      const style = document.createElement("style");
      style.textContent = '.ytp-unmute, [class*="unmute"], [class*="Unmute"] { display: none !important; }';
      const addStyle = () => (document.head || document.documentElement).appendChild(style);
      if (document.documentElement) addStyle(); else document.addEventListener("DOMContentLoaded", addStyle);
      window.__shApply = () => {
        const v = document.querySelector("video");
        const p = document.querySelector(".html5-video-player");
        if (!v) return;
        v.loop = true;
        const s = window.__sh;
        const ad = p && (p.classList.contains("ad-showing") || p.classList.contains("ad-interrupting"));
        if (s.hold || s.paused) {
          if (!v.paused) v.pause();
        } else if (v.paused && v.readyState > 1 && !ad) {
          v.play().catch(() => {});
        }
        if (ad) return;
        const want = Boolean(s.sound) && !s.hold;
        try {
          if (p && typeof p.isMuted === "function") {
            if (want && p.isMuted()) { p.unMute(); if (p.setVolume) p.setVolume(100); }
            if (!want && !p.isMuted()) p.mute();
          }
        } catch (e) {}
        if (v.muted === want) v.muted = !want;
        if (want && v.volume === 0) v.volume = 1;
      };
      setInterval(window.__shApply, 300);
    })();
    """#

    /// The Skip button for an offered segment.
    func skipOffered() {
        guard let id = offered?.id,
              let data = try? JSONSerialization.data(withJSONObject: [id]),
              let json = String(data: data, encoding: .utf8) else { return }
        offered = nil
        webView.evaluateJavaScript("window.__streamhubSkip && window.__streamhubSkip(\(json)[0]);", completionHandler: nil)
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
        // compiled once, then looked up
        if let compiled = try? await WKContentRuleListStore.default().contentRuleList(forIdentifier: "streamhub-youtube-ads-1") {
            return compiled
        }
        return try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "streamhub-youtube-ads-1", encodedContentRuleList: rules)
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
        // 3. SponsorBlock: skip the marked segments, or offer a Skip button for them
        if (!ad && video && Array.isArray(window.__streamhubSegments)) {
          window.__streamhubSkipped = window.__streamhubSkipped || {};
          window.__streamhubOffered = window.__streamhubOffered || {};
          window.__streamhubSkip = (id) => {
            const s = window.__streamhubSegments.find((x) => x.id === id);
            const v = document.querySelector("video");
            if (s && v) { window.__streamhubSkipped[s.id] = true; v.currentTime = s.end; }
          };
          for (const s of window.__streamhubSegments) {
            const inside = video.currentTime >= s.start && video.currentTime < s.end - 0.5;
            if (!s.ask) {
              if (inside && !window.__streamhubSkipped[s.id]) {
                window.__streamhubSkipped[s.id] = true;
                video.currentTime = s.end;
                post({ kind: "skip", name: s.name });
              }
            } else if (inside && !window.__streamhubOffered[s.id]) {
              window.__streamhubOffered[s.id] = true;
              post({ kind: "offer", id: s.id, name: s.name });
            } else if (!inside && window.__streamhubOffered[s.id]) {
              window.__streamhubOffered[s.id] = false;
              post({ kind: "offer-end", id: s.id });
            }
          }
        }
      }, 250);
      // 4. on YouTube's mobile page: start playing (muted, as YouTube does: tap the player to
      //    unmute), and show only the player. Only what's beside the player is hidden, never what
      //    holds it.
      if (location.hostname === "m.youtube.com" && window.top === window) {
        let started = false;
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
          for (const el of holder.querySelectorAll("#player, .html5-video-player, .html5-video-container, video")) {
            el.style.setProperty("width", "100%", "important");
            el.style.setProperty("height", "100%", "important");
            el.style.setProperty("max-height", "none", "important");
          }
          const video = holder.querySelector("video");
          if (video) {
            video.style.setProperty("object-fit", "contain", "important");
            video.style.setProperty("left", "0", "important");
            video.style.setProperty("top", "0", "important");
          }
          document.documentElement.style.setProperty("background", "#000", "important");
          document.body && document.body.style.setProperty("overflow", "hidden", "important");
        };
        const tick = setInterval(() => {
          isolate();
          const video = document.querySelector("video");
          const player = document.querySelector(".html5-video-player");
          const ad = player && player.classList.contains("ad-showing");
          const held = window.__sh && (window.__sh.hold || window.__sh.paused);
          if (video && video.readyState > 0 && !ad && !started && !held) {
            if (video.paused) {
              video.play().catch(() => document.querySelector(".ytp-large-play-button, .ytmCuedOverlayPlayButton")?.click());
            } else {
              started = true;
            }
          }
        }, 500);
        setTimeout(() => clearInterval(tick), 120000);
      }
      document.addEventListener("DOMContentLoaded", () => post({ kind: "ready" }));
      // SponsorBlock segments can arrive before this page: ask for them again until they're here
      let asks = 0;
      const ask = setInterval(() => {
        if (Array.isArray(window.__streamhubSegments) || ++asks > 12) clearInterval(ask);
        else post({ kind: "ready" });
      }, 2500);
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
    /// The bigger player screen is open (the video moves there and back without restarting).
    @Published var expanded = false

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
        expanded = false
        player?.stop()
        player = nil
        self.video = nil
    }
}

/// A video playing in its place in the list, edge to edge, with a bar of its own below it.
struct InlineYouTubePlayer: View {
    @ObservedObject var host = YouTubePlayerHost.shared
    let video: YTVideo
    @AppStorage("streamhub.ytComments") private var showComments = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player = host.player, !host.expanded {
                PlayerStage(player: player, video: video, mini: false)
                    .aspectRatio(16 / 9, contentMode: .fit)
            } else {
                Color.black.aspectRatio(16 / 9, contentMode: .fit)
            }
            HStack(spacing: 18) {
                Label("No ads · SponsorBlock", systemImage: "checkmark.shield")
                    .font(.caption).foregroundStyle(.green)
                Spacer()
                Button {
                    Task {
                        // iPhone's own full-screen player, the same as YouTube's full-screen
                        // button; if the page won't allow it, the bigger player instead
                        if await !(host.player?.enterFullScreen() ?? false) { host.expanded = true }
                    }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityLabel("Full screen")
                if showComments {
                    Button { host.expanded = true } label: {
                        Image(systemName: "text.bubble")
                    }
                    .accessibilityLabel("Comments")
                }
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
        .onDisappear { if !host.expanded { host.close(video) } }
    }
}

/// The bigger player: the video as large as the screen allows, title below. ⌄ goes back to the
/// list with the video still playing there; × stops it.
struct ExpandedYouTubePlayer: View {
    @ObservedObject var host = YouTubePlayerHost.shared
    @AppStorage("streamhub.ytComments") private var showComments = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 22) {
                    Button { host.expanded = false } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("Back to the list")
                    Spacer()
                    if let video = host.video {
                        Button {
                            if let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") { openURL(url) }
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .accessibilityLabel("Open in the YouTube app")
                    }
                    Button { host.close() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Stop the video")
                }
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(height: 44)

                if let player = host.player, let video = host.video {
                    // as wide as the screen, and as tall as it can be while the title still shows
                    PlayerStage(player: player, video: video, mini: false)
                        .frame(width: geo.size.width,
                               height: min(geo.size.height * 0.62, max(geo.size.width * 9 / 16, geo.size.width * 0.75)))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(video.title).font(.headline)
                        Text([video.channel, video.views, video.published].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Label("No ads · SponsorBlock (Settings → YouTube)", systemImage: "checkmark.shield")
                            .font(.caption).foregroundStyle(.green)
                    }
                    .padding(.horizontal, 16)

                    if showComments {
                        Divider()
                        YouTubeCommentsList(videoId: video.id).id(video.id)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}

/// The video itself and what StreamHub shows over it (ad being skipped, SponsorBlock skips).
struct PlayerStage: View {
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
            if let offered = player.offered {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { player.skipOffered() } label: {
                            Label("Skip \(offered.name)", systemImage: "forward.end.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                    }
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

/// A video's comments under the bigger player (Settings → YouTube → Show comments), loading more
/// as you scroll.
struct YouTubeCommentsList: View {
    let videoId: String
    @State private var comments: [YTComment] = []
    @State private var next: String?
    @State private var count = ""
    @State private var off = false
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var create: String?
    /// Replies you posted from StreamHub, by comment.
    @State private var mine: [String: [String]] = [:]
    @State private var composing: Composer?

    struct Composer: Identifiable {
        let id = UUID()
        let params: String
        let reply: Bool
        let to: YTComment?
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(count.isEmpty ? "Comments" : count).font(.subheadline.weight(.semibold))
                    Spacer()
                    if let create {
                        Button {
                            composing = Composer(params: create, reply: false, to: nil)
                        } label: {
                            Label("Add a comment", systemImage: "square.and.pencil").font(.footnote.weight(.semibold))
                        }
                    }
                }
                ForEach(comments) { comment in
                    HStack(alignment: .top, spacing: 10) {
                        AsyncImage(url: comment.avatar.flatMap(URL.init(string:))) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color(uiColor: .tertiarySystemBackground)
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(comment.author).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(comment.published).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(comment.text).font(.subheadline)
                            let meta = [comment.likes.isEmpty || comment.likes == "0" ? "" : "👍 \(comment.likes)",
                                        comment.replies.isEmpty || comment.replies == "0" ? "" : "\(comment.replies) \(comment.replies == "1" ? "reply" : "replies")"]
                                .filter { !$0.isEmpty }.joined(separator: " · ")
                            HStack(spacing: 12) {
                                if !meta.isEmpty { Text(meta).font(.caption2).foregroundStyle(.secondary) }
                                if let params = comment.reply {
                                    Button("Reply") { composing = Composer(params: params, reply: true, to: comment) }
                                        .font(.caption2.weight(.semibold))
                                }
                            }
                            ForEach(mine[comment.id] ?? [], id: \.self) { text in
                                Text("You: \(text)")
                                    .font(.caption)
                                    .padding(.leading, 8)
                                    .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 2) }
                            }
                        }
                    }
                }
                if let error {
                    VStack(spacing: 6) {
                        Text("Couldn't load comments.").font(.footnote).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }.font(.footnote)
                    }
                    .frame(maxWidth: .infinity)
                    .help(error)
                } else if off {
                    Text("Comments are turned off for this video.").font(.footnote).foregroundStyle(.secondary)
                } else if loaded && comments.isEmpty {
                    Text("No comments yet.").font(.footnote).foregroundStyle(.secondary)
                } else if !loaded || next != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .id(comments.count)
                        .onAppear { Task { await load() } }
                }
            }
            .padding(16)
        }
        .sheet(item: $composing) { composer in
            CommentComposer(composer: composer) { text in
                if let to = composer.to {
                    mine[to.id, default: []].append(text)
                } else {
                    comments.insert(YTComment(id: "mine-\(UUID().uuidString)", author: "You", avatar: nil, text: text,
                                              published: "just now", likes: "", replies: "", pinned: false, reply: nil), at: 0)
                }
            }
        }
    }

    private func load() async {
        guard !loading, !(loaded && next == nil) else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page = try await YouTubeAPI.shared.comments(videoId, next: loaded ? next : nil)
            let seen = Set(comments.map(\.id))
            comments += page.comments.filter { !seen.contains($0.id) }
            next = page.next
            if !page.count.isEmpty { count = page.count }
            off = page.off
            if create == nil { create = page.create }
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Write a comment or a reply; it's posted as your signed-in YouTube account.
private struct CommentComposer: View {
    let composer: YouTubeCommentsList.Composer
    let posted: (String) -> Void
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let to = composer.to {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(to.author).font(.caption.weight(.semibold))
                        Text(to.text).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Text("Posted publicly as your signed-in YouTube account.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle(composer.reply ? "Reply" : "Add a comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Posting…" : (composer.reply ? "Reply" : "Post")) {
                        Task { await send() }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func send() async {
        sending = true
        error = nil
        do {
            try await YouTubeAPI.shared.postComment(params: composer.params, text: text, reply: composer.reply)
            posted(text.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            self.error = "Couldn't post: \(error.localizedDescription)"
        }
        sending = false
    }
}
