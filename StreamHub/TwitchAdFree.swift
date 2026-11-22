import AVKit
import Foundation
import SwiftUI

// Ad-free Twitch playback: ads must not interrupt streams.
//
// Works like streamlink-ttvlol (which StreamHub desktop uses): the playback token and master
// playlist are requested from a country where Twitch doesn't serve ads, through an HTTP CONNECT
// proxy or a TTV.LOL-style playlist proxy. Media playlists and video segments then load directly.
// If an ad still shows up, the next proxy is used. It never falls back to Twitch directly.

/// Twitch's markers for ads stitched into a media playlist (same checks as streamlink-ttvlol).
enum TwitchAdMarkers {
    static func contains(_ playlist: String) -> Bool {
        let lower = playlist.lowercased()
        if lower.contains("twitch-stitched-ad") || lower.contains("\"stitched-ad-")
            || lower.contains("x-tv-twitch-ad-") {
            return true
        }
        // ad segments are titled "Amazon|…" in their #EXTINF tag
        return playlist.split(separator: "\n").contains { line in
            line.hasPrefix("#EXTINF") && line.contains("Amazon")
        }
    }
}

enum TwitchAdFreeResolver {
    enum Route {
        case forwardProxy(host: String, port: Int)
        case playlistProxy(base: URL)

        var label: String {
            switch self {
            case .forwardProxy(let host, _): return host
            case .playlistProxy(let base): return base.host ?? base.absoluteString
            }
        }
    }

    /// Same servers and order as StreamHub desktop's default list.
    static let routes: [Route] = [
        .forwardProxy(host: "firefox.api.cdn-perfprod.com", port: 2023),
        .forwardProxy(host: "chromium.api.cdn-perfprod.com", port: 2023),
        .playlistProxy(base: URL(string: "https://lb-na.cdn-perfprod.com")!),
        .playlistProxy(base: URL(string: "https://lb-eu.cdn-perfprod.com")!),
        .playlistProxy(base: URL(string: "https://eu.luminous.dev")!)
    ]

    struct Resolved {
        let route: Route
        let masterURL: URL
        let masterPlaylist: String

        /// The best video variant (Twitch lists the highest quality first). AVPlayer plays this
        /// media playlist directly, like streamlink-ttvlol loads media playlists directly.
        var mediaURL: URL? {
            let lines = masterPlaylist.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
                // skip audio-only variants (no RESOLUTION attribute)
                guard line.contains("RESOLUTION="), index + 1 < lines.count else { continue }
                let uri = lines[index + 1]
                if !uri.isEmpty, !uri.hasPrefix("#"), let url = URL(string: uri, relativeTo: masterURL)?.absoluteURL {
                    return url
                }
            }
            return nil
        }
    }

    enum Failure: Error {
        case invalidChannel
        case unavailable
        case containsAds
    }

    static func isValidChannel(_ channel: String) -> Bool {
        channel.range(of: "^[A-Za-z0-9_]{3,25}$", options: .regularExpression) != nil
    }

    /// Resolve through one route, and make sure the stream doesn't start with ads.
    static func resolve(channel: String, route: Route) async throws -> Resolved {
        guard isValidChannel(channel) else { throw Failure.invalidChannel }
        let resolved: Resolved
        switch route {
        case .forwardProxy(let host, let port):
            resolved = try await resolveForwardProxy(channel: channel.lowercased(), host: host, port: port, route: route)
        case .playlistProxy(let base):
            resolved = try await resolvePlaylistProxy(channel: channel.lowercased(), base: base, route: route)
        }
        if try await firstMediaPlaylistHasAds(resolved) {
            throw Failure.containsAds
        }
        return resolved
    }

    private static func validMaster(_ data: Data, _ response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U"),
              text.contains("#EXT-X-STREAM-INF") else {
            return nil
        }
        return text
    }

    private static func addPlayerHeaders(_ request: inout URLRequest) {
        request.setValue("https://player.twitch.tv", forHTTPHeaderField: "Referer")
        request.setValue("https://player.twitch.tv", forHTTPHeaderField: "Origin")
    }

    /// Token and master playlist both go through the proxy, like streamlink-ttvlol's httpproxy mode.
    private static func resolveForwardProxy(channel: String, host: String, port: Int, route: Route) async throws -> Resolved {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let token = try await playbackToken(channel: channel, session: session)
        var components = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(channel).m3u8")!
        components.queryItems = [
            URLQueryItem(name: "sig", value: token.signature),
            URLQueryItem(name: "token", value: token.value),
            URLQueryItem(name: "allow_source", value: "true"),
            URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "fast_bread", value: "true"),
            URLQueryItem(name: "player_backend", value: "mediaplayer"),
            URLQueryItem(name: "supported_codecs", value: "h264"),
            URLQueryItem(name: "p", value: String(Int.random(in: 1...999_999)))
        ]
        guard let url = components.url else { throw Failure.unavailable }
        var request = URLRequest(url: url)
        addPlayerHeaders(&request)
        let (data, response) = try await session.data(for: request)
        guard let master = validMaster(data, response) else { throw Failure.unavailable }
        return Resolved(route: route, masterURL: url, masterPlaylist: master)
    }

    /// TTV.LOL API: the proxy requests the token and master playlist itself.
    private static func resolvePlaylistProxy(channel: String, base: URL, route: Route) async throws -> Resolved {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let prefix = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = (prefix.isEmpty ? "" : "/" + prefix) + "/playlist/\(channel).m3u8"
        components?.queryItems = [
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "allow_source", value: "true"),
            URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "fast_bread", value: "true"),
            URLQueryItem(name: "supported_codecs", value: "h264")
        ]
        guard let url = components?.url else { throw Failure.unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        addPlayerHeaders(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let master = validMaster(data, response) else { throw Failure.unavailable }
        return Resolved(route: route, masterURL: url, masterPlaylist: master)
    }

    /// Check the media playlist before playing, so a stream that starts with ads is skipped.
    private static func firstMediaPlaylistHasAds(_ resolved: Resolved) async throws -> Bool {
        guard let mediaURL = resolved.mediaURL else { throw Failure.unavailable }
        return await mediaPlaylistHasAds(mediaURL)
    }

    /// Fetch a media playlist and check it for Twitch's ad markers (false if it can't be loaded).
    static func mediaPlaylistHasAds(_ mediaURL: URL) async -> Bool {
        var request = URLRequest(url: mediaURL)
        request.timeoutInterval = 10
        addPlayerHeaders(&request)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return TwitchAdMarkers.contains(text)
    }

    private struct TokenResponse: Decodable {
        struct DataValue: Decodable {
            struct Token: Decodable { let value: String; let signature: String }
            let streamPlaybackAccessToken: Token?
        }
        let data: DataValue?
    }

    private static func playbackToken(channel: String, session: URLSession) async throws -> TokenResponse.DataValue.Token {
        let payload: [String: Any] = [
            "operationName": "PlaybackAccessToken",
            "variables": [
                "isLive": true, "login": channel, "isVod": false, "vodID": "",
                "playerType": "embed", "platform": "site"
            ] as [String: Any],
            "extensions": [
                "persistedQuery": [
                    "version": 1,
                    "sha256Hash": "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
                ] as [String: Any]
            ] as [String: Any]
        ]
        var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("kimne78kx3ncx6brgo4mv6wki5h1ko", forHTTPHeaderField: "Client-ID")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let token = try JSONDecoder().decode(TokenResponse.self, from: data).data?.streamPlaybackAccessToken else {
            throw Failure.unavailable
        }
        return token
    }
}

/// Small status badge in the corner of the video, like StreamHub desktop's.
struct TwitchAdBlockBadge: View {
    enum Level { case ok, warning, failed }
    let level: Level
    let title: String
    let detail: String

    private var color: Color {
        switch level {
        case .ok: return Color(red: 0.24, green: 0.81, blue: 0.43)
        case .warning: return Color(red: 0.96, green: 0.72, blue: 0.24)
        case .failed: return Color(red: 0.95, green: 0.33, blue: 0.35)
        }
    }

    private var symbol: String {
        switch level {
        case .ok: return "checkmark.shield.fill"
        case .warning: return "exclamationmark.shield.fill"
        case .failed: return "xmark.shield.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

struct TwitchAdFreePlayerView: View {
    let channel: String
    var onReturnToWebPlayer: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case connecting
        case playing(server: String)
        case switching
        case failed(String)
    }

    @State private var player: AVPlayer?
    @State private var adWatcher: Task<Void, Never>?
    @State private var phase: Phase = .connecting
    @State private var routeIndex = 0
    @State private var attempt = UUID()
    @State private var adsGotThrough = 0
    @State private var showBadge = true
    @State private var badgeHideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                ZStack(alignment: .topTrailing) {
                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    } else if case .failed(let message) = phase {
                        failure(message)
                    } else {
                        ProgressView("Finding an ad-free stream…")
                            .tint(.white)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 210)
                    }
                    if showBadge, let badge = badgeContent {
                        badge
                            .padding(10)
                            .transition(.opacity)
                            .onTapGesture { withAnimation { showBadge = false } }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .task { await start(from: 0) }
        .onDisappear { stop() }
    }

    private var header: some View {
        HStack {
            Button {
                stop()
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .accessibilityLabel("Back to Twitch streams")
            Spacer()
            Text(channel).font(.headline).lineLimit(1)
            Spacer()
            Menu {
                Button("Find another ad-free server", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await start(from: routeIndex + 1) }
                }
                Button("Retry from the first server", systemImage: "arrow.clockwise") {
                    Task { await start(from: 0) }
                }
                Button("Watch in the regular Twitch player (with ads)", systemImage: "globe") {
                    stop()
                    onReturnToWebPlayer?()
                    dismiss()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Playback options")
        }
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await start(from: 0) } }
                .buttonStyle(.borderedProminent)
            Button("Watch in the regular Twitch player (with ads)") {
                stop()
                onReturnToWebPlayer?()
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 210)
    }

    private var badgeContent: TwitchAdBlockBadge? {
        let ads = adsGotThrough == 0 ? "" : " · \(adsGotThrough) ad\(adsGotThrough == 1 ? "" : "s") skipped"
        switch phase {
        case .connecting:
            return nil
        case .playing(let server):
            return TwitchAdBlockBadge(level: adsGotThrough == 0 ? .ok : .warning, title: "Ad-free", detail: "via \(server)\(ads)")
        case .switching:
            return TwitchAdBlockBadge(level: .warning, title: "Ad detected", detail: "Switching to another server")
        case .failed:
            return TwitchAdBlockBadge(level: .failed, title: "No ad-free stream", detail: "Not playing, to avoid ads")
        }
    }

    @MainActor
    private func flashBadge() {
        badgeHideTask?.cancel()
        withAnimation { showBadge = true }
        let level = badgeContent?.level
        guard level == .ok else { return }
        badgeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showBadge = false }
        }
    }

    @MainActor
    private func stop() {
        attempt = UUID()
        badgeHideTask?.cancel()
        adWatcher?.cancel()
        adWatcher = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    /// Try the routes in order, starting at `index`; play the first one without ads.
    @MainActor
    private func start(from index: Int) async {
        let current = UUID()
        attempt = current
        guard TwitchAdFreeResolver.isValidChannel(channel) else {
            phase = .failed("Invalid Twitch channel")
            flashBadge()
            return
        }
        let routes = TwitchAdFreeResolver.routes
        if player == nil { phase = .connecting }
        let first = min(max(0, index), routes.count)
        for offset in first..<routes.count {
            let route = routes[offset]
            guard let resolved = try? await TwitchAdFreeResolver.resolve(channel: channel, route: route) else {
                continue
            }
            guard attempt == current, !Task.isCancelled else { return }
            if await play(resolved, routeIndex: offset, attemptID: current) {
                return
            }
        }
        guard attempt == current else { return }
        adWatcher?.cancel()
        adWatcher = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        phase = .failed("No ad-free stream is available right now: every server failed or served ads. StreamHub won't play the stream with ads.")
        flashBadge()
    }

    @MainActor
    private func play(_ resolved: TwitchAdFreeResolver.Resolved, routeIndex index: Int, attemptID: UUID) async -> Bool {
        guard let mediaURL = resolved.mediaURL, attempt == attemptID else { return false }

        routeIndex = index
        let item = AVPlayerItem(url: mediaURL)
        if let player {
            player.replaceCurrentItem(with: item)
            player.play()
        } else {
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            newPlayer.play()
        }
        phase = .playing(server: resolved.route.label)
        flashBadge()
        watchForAds(mediaURL, attemptID: attemptID)
        return true
    }

    /// Re-check the playing media playlist every few seconds; switch servers if ads show up.
    @MainActor
    private func watchForAds(_ mediaURL: URL, attemptID: UUID) {
        adWatcher?.cancel()
        adWatcher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, attempt == attemptID else { return }
                if await TwitchAdFreeResolver.mediaPlaylistHasAds(mediaURL) {
                    guard !Task.isCancelled, attempt == attemptID else { return }
                    // don't show the ad while another server is found
                    player?.pause()
                    adsGotThrough += 1
                    phase = .switching
                    flashBadge()
                    await start(from: routeIndex + 1)
                    return
                }
            }
        }
    }
}
