import Foundation
import WebKit

struct YTVideo: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let channel: String
    let channelId: String?
    let live: Bool
    let duration: String
    let published: String
    let views: String
    let avatar: String?

    var thumbnail: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
}

struct YTChannel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let avatar: String?
    let subscribers: String
}

struct YTFeed: Codable {
    var videos: [YTVideo]
    var next: String?
}

struct YTSearch: Codable {
    let videos: [YTVideo]
    let channels: [YTChannel]
}

struct YTChannelPage: Codable {
    let id: String
    let name: String
    let description: String
    let avatar: String?
    let videos: [YTVideo]
}

struct YTAccount: Codable {
    let name: String
    let avatar: String?
}

enum YouTubeError: LocalizedError {
    case signedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to YouTube to see this."
        case .failed(let message): return message
        }
    }
}

/// YouTube's own web API (InnerTube, unofficial), called from a hidden youtube.com page so the
/// requests carry your YouTube sign-in (the same as StreamHub desktop). You sign in on Google's own
/// page; StreamHub never sees the password. Results come back from the page directly
/// (callAsyncJavaScript); the page has no other way to talk to the app.
@MainActor
final class YouTubeAPI: NSObject, WKNavigationDelegate {
    static let shared = YouTubeAPI()
    private static let page = URL(string: "https://www.youtube.com/robots.txt")!

    private var webView: WKWebView?
    private var ready = false

    private func page() async -> WKWebView {
        if let webView, ready { return webView }
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
            view.navigationDelegate = self
            if #available(iOS 16.4, *) { view.isInspectable = false }
            webView = view
            view.load(URLRequest(url: Self.page))
        }
        while !ready { try? await Task.sleep(nanoseconds: 100_000_000) }
        return webView!
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retry(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retry(webView)
    }

    private func retry(_ webView: WKWebView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { webView.load(URLRequest(url: Self.page)) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == Self.page ? .allow : .cancel)
    }

    /// Run a script body (with the helpers below in scope) and decode its `{ status, items }`.
    private func run<T: Decodable>(_ body: String, _ arguments: [String: Any] = [:], as: T.Type) async throws -> T {
        let view = await page()
        let script = Self.helpers + "\nconst result = await (async () => {\n" + body + "\n})();\nreturn JSON.stringify(result);"
        let raw = try await view.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient)
        guard let json = raw as? String, let data = json.data(using: .utf8) else {
            throw YouTubeError.failed("YouTube sent an unexpected answer.")
        }
        struct Envelope<Items: Decodable>: Decodable {
            let status: Int
            let items: Items?
            let error: String?
        }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if envelope.status == 401 { throw YouTubeError.signedOut }
        guard envelope.status == 200, let items = envelope.items else {
            throw YouTubeError.failed(envelope.error ?? "YouTube answered \(envelope.status).")
        }
        return items
    }

    func account() async throws -> YTAccount { try await run(Self.accountBody, as: YTAccount.self) }

    func home(next: String? = nil) async throws -> YTFeed {
        try await run(Self.homeBody, ["token": next.map { $0 as Any } ?? NSNull()], as: YTFeed.self)
    }

    func subscriptions(next: String? = nil) async throws -> YTFeed {
        try await run(Self.feedBody, ["token": next.map { $0 as Any } ?? NSNull()], as: YTFeed.self)
    }

    func search(_ query: String) async throws -> YTSearch {
        try await run(Self.searchBody, ["query": String(query.prefix(200))], as: YTSearch.self)
    }

    func channel(_ id: String) async throws -> YTChannelPage {
        guard id.range(of: "^UC[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil else {
            throw YouTubeError.failed("Not a YouTube channel.")
        }
        return try await run(Self.channelBody, ["channelId": id], as: YTChannelPage.self)
    }

    /// Signed in to YouTube: the sign-in cookie is there.
    static func signedIn() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.contains { ($0.name == "SAPISID" || $0.name == "__Secure-3PAPISID") && $0.domain.hasSuffix("youtube.com") }
    }

    // MARK: - Scripts (the same as StreamHub desktop's youtube.rs)

    private static let helpers = #"""
    const VERSION = "2.20251120.01.00";
    const context = { client: { clientName: "WEB", clientVersion: VERSION, hl: "en", gl: "US" } };
    const cookie = (name) => {
      const m = document.cookie.match(new RegExp("(?:^|; )" + name + "=([^;]+)"));
      return m ? decodeURIComponent(m[1]) : null;
    };
    const auth = async () => {
      const sid = cookie("SAPISID") || cookie("__Secure-3PAPISID");
      if (!sid) return null;
      const ts = Math.floor(Date.now() / 1000);
      const hash = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(`${ts} ${sid} https://www.youtube.com`));
      return `SAPISIDHASH ${ts}_${[...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("")}`;
    };
    const api = async (endpoint, body, signedIn) => {
      const headers = {
        "Content-Type": "application/json",
        "X-Origin": "https://www.youtube.com",
        "X-Youtube-Client-Name": "1",
        "X-Youtube-Client-Version": VERSION,
      };
      if (signedIn) {
        const a = await auth();
        if (!a) return { status: 401 };
        headers.Authorization = a;
        headers["X-Goog-AuthUser"] = "0";
      }
      const res = await fetch(`/youtubei/v1/${endpoint}?prettyPrint=false`, {
        method: "POST", headers, credentials: "include", body: JSON.stringify({ context, ...body }),
      });
      if (!res.ok) return { status: res.status };
      return { status: 200, data: await res.json() };
    };
    const text = (t) => (!t ? "" : typeof t === "string" ? t : t.simpleText || t.content || (t.runs || []).map((r) => r.text).join("") || "");
    const firstId = (node, prefix) => {
      let found = null;
      const walk = (n) => {
        if (found || !n || typeof n !== "object") return;
        if (n.browseEndpoint && typeof n.browseEndpoint.browseId === "string" && n.browseEndpoint.browseId.startsWith(prefix)) {
          found = n.browseEndpoint.browseId;
          return;
        }
        for (const k in n) walk(n[k]);
      };
      walk(node);
      return found;
    };
    const firstThumb = (node) => {
      let found = null;
      const walk = (n) => {
        if (found || !n || typeof n !== "object") return;
        if (Array.isArray(n.thumbnails) && n.thumbnails.length) {
          const t = n.thumbnails[n.thumbnails.length - 1].url || "";
          found = t.startsWith("//") ? "https:" + t : t;
          return;
        }
        if (Array.isArray(n.sources) && n.sources.length && n.sources[0].url) {
          found = n.sources[n.sources.length - 1].url;
          return;
        }
        for (const k in n) walk(n[k]);
      };
      walk(node);
      return found;
    };
    const collect = (root) => {
      const videos = [];
      const channels = [];
      const seenV = new Set();
      const seenC = new Set();
      const walk = (n) => {
        if (!n || typeof n !== "object") return;
        if (Array.isArray(n)) { n.forEach(walk); return; }
        const v = n.videoRenderer || n.gridVideoRenderer || n.compactVideoRenderer;
        if (v && v.videoId && !seenV.has(v.videoId)) {
          seenV.add(v.videoId);
          const badges = JSON.stringify(v.badges || []) + JSON.stringify(v.thumbnailOverlays || []);
          const live = /LIVE/.test(badges) || /watching/i.test(text(v.viewCountText));
          const owner = v.ownerText || v.longBylineText || v.shortBylineText;
          videos.push({
            id: v.videoId, title: text(v.title), channel: text(owner), channelId: firstId(owner, "UC"), live,
            duration: text(v.lengthText) || "", published: text(v.publishedTimeText),
            views: text(v.shortViewCountText) || text(v.viewCountText),
            avatar: firstThumb(v.channelThumbnailSupportedRenderers || v.channelThumbnail || null),
          });
        }
        const l = n.lockupViewModel;
        if (l && l.contentId && /VIDEO/.test(String(l.contentType || "")) && !seenV.has(l.contentId)) {
          seenV.add(l.contentId);
          const meta = (l.metadata && l.metadata.lockupMetadataViewModel) || {};
          const rows = ((meta.metadata && meta.metadata.contentMetadataViewModel && meta.metadata.contentMetadataViewModel.metadataRows) || [])
            .map((r) => (r.metadataParts || []).map((p) => text(p.text)).filter(Boolean));
          const flat = JSON.stringify(l.contentImage || {});
          const badgeTexts = [...flat.matchAll(/"thumbnailBadgeViewModel":\{"text":"([^"]*)"/g)].map((m) => m[1]);
          const live = /LIVE/.test(flat) || rows.flat().some((t) => /watching/i.test(t));
          videos.push({
            id: l.contentId, title: text(meta.title), channel: (rows[0] || [])[0] || "", channelId: firstId(meta, "UC"), live,
            duration: live ? "" : badgeTexts.find((t) => /^\d+(:\d+)+$/.test(t)) || "",
            published: (rows[1] || []).find((t) => /ago|Streamed|Scheduled|Premieres/i.test(t)) || "",
            views: (rows[1] || []).find((t) => /view|watching/i.test(t)) || "",
            avatar: firstThumb(meta.image || null),
          });
        }
        const c = n.channelRenderer;
        if (c && c.channelId && !seenC.has(c.channelId)) {
          seenC.add(c.channelId);
          channels.push({ id: c.channelId, name: text(c.title), avatar: firstThumb(c.thumbnail),
                          subscribers: text(c.videoCountText) || text(c.subscriberCountText) });
        }
        for (const k in n) if (k !== "frameworkUpdates") walk(n[k]);
      };
      walk(root);
      return { videos, channels };
    };
    const nextPage = (root) => {
      let token = null;
      const walk = (n) => {
        if (!n || typeof n !== "object") return;
        if (n.continuationItemRenderer) {
          const m = JSON.stringify(n.continuationItemRenderer).match(/"continuationCommand":\{"token":"([^"]+)"/);
          if (m) token = m[1];
          return;
        }
        for (const k in n) if (k !== "frameworkUpdates") walk(n[k]);
      };
      walk(root);
      return token;
    };
    """#

    private static let accountBody = #"""
    const r = await api("account/account_menu", {}, true);
    if (r.status !== 200) return { status: r.status };
    let name = "", photo = null;
    const walk = (n) => {
      if (!n || typeof n !== "object") return;
      if (n.activeAccountHeaderRenderer) {
        name = text(n.activeAccountHeaderRenderer.accountName);
        photo = firstThumb(n.activeAccountHeaderRenderer.accountPhoto);
        return;
      }
      for (const k in n) walk(n[k]);
    };
    walk(r.data);
    if (!name) return { status: 401 };
    return { status: 200, items: { name, avatar: photo } };
    """#

    private static let feedBody = #"""
    const r = await api("browse", token ? { continuation: token } : { browseId: "FEsubscriptions" }, true);
    if (r.status !== 200) return { status: r.status };
    const { videos } = collect(r.data);
    if (!token && !videos.length && /signInEndpoint|Sign in/.test(JSON.stringify(r.data).slice(0, 20000))) return { status: 401 };
    return { status: 200, items: { videos, next: nextPage(r.data) } };
    """#

    private static let homeBody = #"""
    const signedIn = Boolean(cookie("SAPISID") || cookie("__Secure-3PAPISID"));
    const r = await api("browse", token ? { continuation: token } : { browseId: "FEwhat_to_watch" }, signedIn);
    if (r.status !== 200) return { status: r.status };
    return { status: 200, items: { videos: collect(r.data).videos, next: nextPage(r.data) } };
    """#

    private static let searchBody = #"""
    const r = await api("search", { query }, false);
    if (r.status !== 200) return { status: r.status };
    return { status: 200, items: collect(r.data) };
    """#

    private static let channelBody = #"""
    const [videosTab, liveTab] = await Promise.all([
      api("browse", { browseId: channelId, params: "EgZ2aWRlb3PyBgQKAjoA" }, false),
      api("browse", { browseId: channelId, params: "EgdzdHJlYW1z8gYECgJ6AA==" }, false),
    ]);
    if (videosTab.status !== 200) return { status: videosTab.status };
    const meta = (videosTab.data.metadata && videosTab.data.metadata.channelMetadataRenderer) || {};
    const videos = collect(videosTab.data).videos;
    const live = liveTab.status === 200 ? collect(liveTab.data).videos.filter((v) => v.live) : [];
    return { status: 200, items: {
      id: channelId, name: meta.title || "", description: meta.description || "", avatar: firstThumb(meta.avatar || null),
      videos: [...live, ...videos.filter((v) => !live.some((l) => l.id === v.id))]
        .map((v) => ({ ...v, channel: v.channel || meta.title || "", channelId: v.channelId || channelId })),
    } };
    """#
}
