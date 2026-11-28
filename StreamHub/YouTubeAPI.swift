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
    /// History: the day YouTube files it under, and its "Remove from watch history" token.
    var day: String? = nil
    var remove: String? = nil
    /// YouTube's "Not interested" and "Don't recommend channel" tokens (recommendations only).
    var notInterested: String? = nil
    var dontRecommend: String? = nil

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

struct YTComment: Codable, Identifiable, Hashable {
    let id: String
    let author: String
    let avatar: String?
    let text: String
    let published: String
    let likes: String
    let replies: String
    let pinned: Bool
    /// YouTube's parameters for replying (nil: replies are off).
    let reply: String?
}

struct YTComments: Codable {
    let comments: [YTComment]
    let next: String?
    let count: String
    let off: Bool
    /// YouTube's parameters for a new comment on the video (nil: you can't comment).
    let create: String?
}

struct YTAccount: Codable {
    let name: String
    let avatar: String?
}

private struct Envelope<Items: Decodable>: Decodable {
    let status: Int
    let items: Items?
    let error: String?
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
    nonisolated static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15"
    private static let page = URL(string: "https://www.youtube.com/robots.txt")!

    private var webView: WKWebView?
    private var ready = false

    private func page() async -> WKWebView {
        if let webView, ready { return webView }
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration)
            // Safari on a Mac: YouTube gives Safari a ready-to-play stream (HLS) that iPhone's
            // player plays directly
            view.customUserAgent = Self.safariUserAgent
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
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if envelope.status == 401 { throw YouTubeError.signedOut }
        guard envelope.status == 200, let items = envelope.items else {
            throw YouTubeError.failed(envelope.error ?? "YouTube answered \(envelope.status).")
        }
        return items
    }

    struct Player: Decodable {
        let hls: String?
        let status: String
        let reason: String?
        let title: String
        let author: String
        let live: Bool
    }

    /// The video's stream as YouTube's website gives it to Safari (signed in, when you are).
    func player(_ id: String) async throws -> Player {
        try await run(Self.playerBody, ["videoId": id], as: Player.self)
    }

    func account() async throws -> YTAccount { try await run(Self.accountBody, as: YTAccount.self) }

    func home(next: String? = nil) async throws -> YTFeed {
        try await run(Self.homeBody, ["token": next.map { $0 as Any } ?? NSNull()], as: YTFeed.self)
    }

    func subscriptions(next: String? = nil) async throws -> YTFeed {
        try await run(Self.feedBody, ["token": next.map { $0 as Any } ?? NSNull()], as: YTFeed.self)
    }

    func history(next: String? = nil) async throws -> YTFeed {
        try await run(Self.historyBody, ["token": next.map { $0 as Any } ?? NSNull()], as: YTFeed.self)
    }

    /// YouTube's own "Remove from watch history" for one video.
    func removeFromHistory(_ token: String) async throws {
        guard token.count < 4000, token.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw YouTubeError.failed("Can't remove this video.")
        }
        _ = try await run(Self.historyRemoveBody, ["token": token], as: Bool.self)
    }

    /// Your Watch later list, a page at a time.
    func watchLater(next: String? = nil) async throws -> YTFeed {
        try await run(Self.watchLaterBody, ["token": next.map { $0 as Any } ?? NSNull()], as: YTFeed.self)
    }

    /// Save a video to Watch later (`add`), or take it off.
    /// YouTube's "Not interested" / "Don't recommend channel" for a recommended video.
    func sendFeedback(_ token: String) async throws {
        guard token.count < 4000, token.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw YouTubeError.failed("Can't do that for this video.")
        }
        _ = try await run(Self.historyRemoveBody, ["token": token], as: Bool.self)
    }

    func editWatchLater(_ videoId: String, add: Bool) async throws {
        guard videoId.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            throw YouTubeError.failed("Not a YouTube video.")
        }
        _ = try await run(Self.watchLaterEditBody, ["videoId": videoId, "add": add], as: Bool.self)
    }

    /// Post a comment (`reply` false, with the video's params) or a reply (with the comment's), as
    /// your signed-in YouTube account.
    func postComment(params: String, text: String, reply: Bool) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 10_000 else { throw YouTubeError.failed("Write something first.") }
        guard params.count < 4000, params.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw YouTubeError.failed("Can't comment here.")
        }
        _ = try await run(Self.postCommentBody, ["params": params, "commentText": text, "reply": reply], as: Bool.self)
    }

    /// Every channel you're subscribed to, by name.
    func subscribedChannels() async throws -> [YTChannel] {
        try await run(Self.subscribedBody, as: [YTChannel].self)
    }

    /// A video's comments, a page at a time (top comments first).
    func comments(_ videoId: String, next: String? = nil) async throws -> YTComments {
        guard videoId.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            throw YouTubeError.failed("Not a YouTube video.")
        }
        return try await run(Self.commentsBody, ["videoId": videoId, "pageToken": next.map { $0 as Any } ?? NSNull()],
                             as: YTComments.self)
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
    // a video's menu: the tokens behind "Not interested" and "Don't recommend channel"
    const feedbackOf = (node) => {
      const json = JSON.stringify(node || {});
      const token = (label) => (json.match(new RegExp(label + '[^]{0,1500}?"feedbackToken":"([^"]+)"')) || [])[1] || null;
      return { notInterested: token("Not interested"), dontRecommend: token("Don.t recommend channel") };
    };
    const collect = (root) => {
      const videos = [];
      const channels = [];
      const seenV = new Set();
      const seenC = new Set();
      const walk = (n) => {
        if (!n || typeof n !== "object") return;
        if (Array.isArray(n)) { n.forEach(walk); return; }
        const v = n.videoRenderer || n.gridVideoRenderer || n.compactVideoRenderer || n.playlistVideoRenderer;
        if (v && v.videoId && !seenV.has(v.videoId)) {
          seenV.add(v.videoId);
          const badges = JSON.stringify(v.badges || []) + JSON.stringify(v.thumbnailOverlays || []);
          const live = /LIVE/.test(badges) || /watching/i.test(text(v.viewCountText));
          const owner = v.ownerText || v.longBylineText || v.shortBylineText;
          videos.push({
            id: v.videoId, title: text(v.title), channel: text(owner), channelId: firstId(owner, "UC"), live,
            duration: text(v.lengthText) || "", published: text(v.publishedTimeText),
            views: text(v.shortViewCountText) || text(v.viewCountText) || (text(v.videoInfo).split(/\s*[•·]\s*/)[0] || ""),
            avatar: firstThumb(v.channelThumbnailSupportedRenderers || v.channelThumbnail || null),
            ...feedbackOf(v),
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
            ...feedbackOf(l),
          });
        }
        const c = n.channelRenderer || n.gridChannelRenderer;
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

    private static let playerBody = #"""
    const signedIn = Boolean(cookie("SAPISID") || cookie("__Secure-3PAPISID"));
    const r = await api("player", {
      videoId, contentCheckOk: true, racyCheckOk: true,
      playbackContext: { contentPlaybackContext: { html5Preference: "HTML5_PREF_WANTS" } },
    }, signedIn);
    if (r.status !== 200) return { status: r.status };
    const p = r.data.playabilityStatus || {};
    const d = r.data.videoDetails || {};
    const s = r.data.streamingData || {};
    return { status: 200, items: {
      hls: s.hlsManifestUrl || null, status: p.status || "", reason: p.reason || (p.errorScreen ? JSON.stringify(p.errorScreen).match(/"text":"([^"]+)"/)?.[1] : null) || null,
      title: d.title || "", author: d.author || "", live: Boolean(d.isLive),
    } };
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

    private static let historyBody = #"""
    const r = await api("browse", token ? { continuation: token } : { browseId: "FEhistory" }, true);
    if (r.status !== 200) return { status: r.status };
    const videos = [];
    const seen = new Set();
    const walk = (n) => {
      if (!n || typeof n !== "object") return;
      if (Array.isArray(n)) { n.forEach(walk); return; }
      const section = n.itemSectionRenderer;
      if (section) {
        const header = section.header || {};
        const day = text((header.itemSectionHeaderRenderer || {}).title)
          || (JSON.stringify(header).match(/"(?:title|content)":"([^"]+)"/) || [])[1] || "";
        for (const item of section.contents || []) {
          const v = collect(item).videos[0];
          if (!v || seen.has(v.id)) continue;
          seen.add(v.id);
          const json = JSON.stringify(item);
          const remove = (json.match(/Remove from (?:watch )?history[^]{0,600}?"feedbackToken":"([^"]+)"/i)
            || json.match(/"feedbackEndpoint":\{"feedbackToken":"([^"]+)"/) || [])[1] || null;
          videos.push({ ...v, day, remove });
        }
        return;
      }
      for (const k in n) if (k !== "frameworkUpdates") walk(n[k]);
    };
    walk(r.data);
    if (!videos.length) for (const v of collect(r.data).videos) if (!seen.has(v.id)) { seen.add(v.id); videos.push({ ...v, day: "" }); }
    if (!token && !videos.length && /signInEndpoint|Sign in/.test(JSON.stringify(r.data).slice(0, 20000))) return { status: 401 };
    return { status: 200, items: { videos, next: nextPage(r.data) } };
    """#

    private static let historyRemoveBody = #"""
    const r = await api("feedback", { feedbackTokens: [token], isFeedbackTokenUnencrypted: false, shouldMerge: false }, true);
    if (r.status !== 200) return { status: r.status };
    return { status: 200, items: true };
    """#

    private static let postCommentBody = #"""
    const r = reply
      ? await api("comment/create_comment_reply", { createReplyParams: params, commentText }, true)
      : await api("comment/create_comment", { createCommentParams: params, commentText }, true);
    if (r.status !== 200) return { status: r.status };
    const flat = JSON.stringify(r.data);
    if (/"status":"STATUS_SUCCEEDED"|createCommentAction|createCommentReplyAction|commentEntityPayload/.test(flat)) return { status: 200, items: true };
    const why = (flat.match(/"(?:errorMessage|text)":"([^"]{3,200})"/) || [])[1];
    return { status: 500, error: why || "YouTube didn't post it." };
    """#

    private static let subscribedBody = #"""
    let r = await api("browse", { browseId: "FEchannels" }, true);
    if (r.status !== 200) return { status: r.status };
    const channels = [];
    const seen = new Set();
    for (let page = 0; page < 15; page++) {
      for (const c of collect(r.data).channels) if (!seen.has(c.id)) { seen.add(c.id); channels.push(c); }
      const token = nextPage(r.data);
      if (!token) break;
      r = await api("browse", { continuation: token }, true);
      if (r.status !== 200) break;
    }
    channels.sort((a, b) => a.name.localeCompare(b.name));
    return { status: 200, items: channels };
    """#

    private static let watchLaterBody = #"""
    const r = await api("browse", token ? { continuation: token } : { browseId: "VLWL" }, true);
    if (r.status !== 200) return { status: r.status };
    const { videos } = collect(r.data);
    if (!token && !videos.length && /signInEndpoint|Sign in/.test(JSON.stringify(r.data).slice(0, 20000))) return { status: 401 };
    return { status: 200, items: { videos, next: nextPage(r.data) } };
    """#

    private static let watchLaterEditBody = #"""
    const action = add ? { action: "ACTION_ADD_VIDEO", addedVideoId: videoId } : { action: "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", removedVideoId: videoId };
    const r = await api("browse/edit_playlist", { playlistId: "WL", actions: [action] }, true);
    if (r.status !== 200) return { status: r.status };
    return /STATUS_SUCCEEDED/.test(JSON.stringify(r.data)) ? { status: 200, items: true } : { status: 500, error: "YouTube didn't change Watch later." };
    """#

    private static let commentsBody = #"""
    const signedIn = Boolean(cookie("SAPISID") || cookie("__Secure-3PAPISID"));
    let token = pageToken;
    let count = "";
    let create = null;
    if (!token) {
      const first = await api("next", { videoId: videoId }, signedIn);
      if (first.status !== 200) return { status: first.status };
      // the comments section's first page token (in the watch page, or its comments panel)
      const find = (n) => {
        if (!n || typeof n !== "object") return null;
        const s = n.itemSectionRenderer;
        if (s && /comment/i.test(String(s.sectionIdentifier || s.targetId || ""))) {
          const m = JSON.stringify(s).match(/"continuationCommand":\{"token":"([^"]+)"/);
          if (m) return m[1];
        }
        const p = n.engagementPanelSectionListRenderer;
        if (p && /comments/i.test(String(p.panelIdentifier || p.targetId || ""))) {
          const m = JSON.stringify(p).match(/"continuationCommand":\{"token":"([^"]+)"/);
          if (m) return m[1];
        }
        for (const k in n) { const t = find(n[k]); if (t) return t; }
        return null;
      };
      token = find(first.data);
      if (!token) return { status: 200, items: { comments: [], next: null, count: "", off: true, create: null } };
    }
    const r = await api("next", { continuation: token }, signedIn);
    if (r.status !== 200) return { status: r.status };
    const comments = [];
    // current format: each comment's view model points at its text and author (commentKey) and
    // at its toolbar (toolbarSurfaceKey, which holds the reply command) in frameworkUpdates
    const mutations = (((r.data.frameworkUpdates || {}).entityBatchUpdate || {}).mutations) || [];
    const ents = {};
    for (const m of mutations) if (m.entityKey && m.payload) ents[m.entityKey] = m.payload;
    const toComment = (p, replySource) => {
      const props = p.properties || {}, author = p.author || {}, bar = p.toolbar || {};
      return {
        id: props.commentId || String(comments.length),
        author: author.displayName || "",
        avatar: author.avatarThumbnailUrl || null,
        text: (props.content && props.content.content) || "",
        published: props.publishedTime || "",
        likes: bar.likeCountNotliked || bar.likeCountA11y || "",
        replies: bar.replyCount || "",
        pinned: false,
        reply: (JSON.stringify(replySource || {}).match(/"createReplyParams":"([^"]+)"/) || [])[1] || null,
      };
    };
    const views = [];
    const findViews = (n) => {
      if (!n || typeof n !== "object") return;
      if (Array.isArray(n)) { n.forEach(findViews); return; }
      if (n.commentKey && typeof n.commentKey === "string") { views.push(n); return; }
      for (const k in n) if (k !== "frameworkUpdates") findViews(n[k]);
    };
    findViews(r.data.onResponseReceivedEndpoints || []);
    for (const v of views) {
      const p = (ents[v.commentKey] || {}).commentEntityPayload;
      if (!p) continue;
      const c = toComment(p, ents[v.toolbarSurfaceKey] || ents[v.commentSurfaceKey]);
      if (!comments.some((x) => x.id === c.id)) comments.push(c);
    }
    if (!views.length) {
      for (const m of mutations) {
        const p = m.payload && m.payload.commentEntityPayload;
        if (p) comments.push(toComment(p, null));
      }
    }
    // older format
    const walk = (n) => {
      if (!n || typeof n !== "object") return;
      if (Array.isArray(n)) { n.forEach(walk); return; }
      const c = n.commentRenderer;
      if (c && c.commentId && !comments.some((x) => x.id === c.commentId)) {
        comments.push({
          id: c.commentId, author: text(c.authorText), avatar: firstThumb(c.authorThumbnail),
          text: text(c.contentText), published: text(c.publishedTimeText), likes: text(c.voteCount),
          replies: String(c.replyCount || ""), pinned: Boolean(c.pinnedCommentBadge),
          reply: (JSON.stringify(n).match(/"createReplyParams":"([^"]+)"/) || [])[1] || null,
        });
        return;
      }
      const h = n.commentsHeaderRenderer;
      if (h) {
        count = text(h.countText) || text(h.commentsCount) || count;
        create = (JSON.stringify(h).match(/"createCommentParams":"([^"]+)"/) || [])[1] || create;
      }
      for (const k in n) if (k !== "frameworkUpdates") walk(n[k]);
    };
    walk(r.data.onResponseReceivedEndpoints || r.data);
    // the next page: the continuation at the end of the list (not a thread's replies)
    let next = null;
    for (const e of r.data.onResponseReceivedEndpoints || []) {
      const items = ((e.reloadContinuationItemsCommand || e.appendContinuationItemsAction || {}).continuationItems) || [];
      const last = items[items.length - 1];
      const m = last && last.continuationItemRenderer && JSON.stringify(last.continuationItemRenderer).match(/"token":"([^"]+)"/);
      if (m) next = m[1];
    }
    return { status: 200, items: { comments, next, count, off: false, create } };
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
