import AVKit
import SwiftUI

/// Plays a YouTube video in iPhone's own player with no ads: StreamHub asks YouTube for the
/// video's stream the way YouTube's iPhone app does and plays only that stream. YouTube's ads are
/// separate videos, so they never play. If YouTube won't give the stream, the video doesn't play
/// (it never falls back to YouTube's player with ads).
enum YouTubeStream {
    struct Resolved {
        let url: URL
        let title: String
        let author: String
        let live: Bool
        let userAgent: String
        var source = "iPhone app"
    }

    static let clientVersion = "20.10.4"
    static let userAgent = "com.google.ios.youtube/\(clientVersion) (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    /// The streams to try, in order: as YouTube's website gives it to Safari, then as YouTube's
    /// iPhone app gets it. Both are HLS streams without ads.
    static func candidates(_ id: String) async throws -> [Resolved] {
        guard id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            throw YouTubeError.failed("Not a YouTube video.")
        }
        var found: [Resolved] = []
        var reasons: [String] = []
        do {
            let web = try await YouTubeAPI.shared.player(id)
            if web.status == "OK", let hls = web.hls, let url = checked(hls) {
                found.append(Resolved(url: url, title: web.title, author: web.author, live: web.live,
                                      userAgent: YouTubeAPI.safariUserAgent, source: "website"))
            } else {
                reasons.append(web.status == "OK" ? "website: no stream" : "website: \(web.reason ?? web.status)")
            }
        } catch {
            reasons.append("website: \(error.localizedDescription)")
        }
        do {
            found.append(try await resolveIOS(id))
        } catch {
            reasons.append("iPhone app: \(error.localizedDescription)")
        }
        if found.isEmpty { throw YouTubeError.failed(reasons.joined(separator: "\n")) }
        return found
    }

    /// What the stream's server answers, step by step (shown when a stream won't play):
    /// the master playlist, one quality's playlist and its first piece of video.
    static func probe(_ resolved: Resolved) async -> String {
        func get(_ url: URL, range: Bool = false) async -> (Int, String) {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue(resolved.userAgent, forHTTPHeaderField: "User-Agent")
            if range { request.setValue("bytes=0-2047", forHTTPHeaderField: "Range") }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (-1, "") }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (status, String(decoding: data.prefix(200_000), as: UTF8.self))
        }
        func firstURI(_ playlist: String, base: URL) -> URL? {
            for line in playlist.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") && !line.isEmpty {
                return URL(string: String(line), relativeTo: base)?.absoluteURL
            }
            return nil
        }
        var steps: [String] = []
        let (masterStatus, master) = await get(resolved.url)
        steps.append("master \(masterStatus)")
        if masterStatus == 200, let variant = firstURI(master, base: resolved.url) {
            let (variantStatus, playlist) = await get(variant)
            steps.append("quality \(variantStatus)")
            if variantStatus == 200, let segment = firstURI(playlist, base: variant) {
                let (segmentStatus, _) = await get(segment, range: true)
                steps.append("video \(segmentStatus)")
            }
        } else if masterStatus == 200 {
            steps.append("no qualities: " + String(master.prefix(80)))
        }
        return steps.joined(separator: " · ")
    }

    private static func checked(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host,
              host.hasSuffix(".googlevideo.com") || host.hasSuffix(".youtube.com") else { return nil }
        return url
    }

    private static func resolveIOS(_ id: String) async throws -> Resolved {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!,
                                 timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("5", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        let body: [String: Any] = [
            "context": ["client": [
                "clientName": "IOS", "clientVersion": clientVersion, "deviceMake": "Apple",
                "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82",
                "hl": "en", "gl": "US", "utcOffsetMinutes": 0,
            ]],
            "videoId": id,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeError.failed("YouTube didn't answer.")
        }
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? ""
        guard status == "OK" else {
            let reason = playability?["reason"] as? String ?? "YouTube won't play this video here."
            throw YouTubeError.failed(reason)
        }
        let details = json["videoDetails"] as? [String: Any] ?? [:]
        guard let streaming = json["streamingData"] as? [String: Any],
              let manifest = streaming["hlsManifestUrl"] as? String, let url = checked(manifest) else {
            throw YouTubeError.failed("YouTube didn't give an ad-free stream for this video.")
        }
        return Resolved(url: url, title: details["title"] as? String ?? "",
                        author: details["author"] as? String ?? "",
                        live: details["isLive"] as? Bool ?? false, userAgent: userAgent)
    }
}

/// SponsorBlock (sponsor.ajay.app): segments the community marked in a video.
enum SponsorBlock {
    struct Segment: Decodable, Hashable {
        let segment: [Double]
        let category: String
        let UUID: String
        var start: Double { segment.first ?? 0 }
        var end: Double { segment.count > 1 ? segment[1] : 0 }
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
        return (try? JSONDecoder().decode([Segment].self, from: result.0))?.filter { $0.end > $0.start } ?? []
    }
}

/// The player: iPhone's own video player, with SponsorBlock skips.
@MainActor
final class YouTubePlayerModel: ObservableObject {
    @Published var state: State = .loading
    @Published var toast: String?
    let player = AVPlayer()
    private var segments: [SponsorBlock.Segment] = []
    private var skipped: Set<String> = []
    private var observer: Any?
    private var toastTask: Task<Void, Never>?

    enum State {
        case loading, playing(YouTubeStream.Resolved), failed(String)
    }

    static let skipCategories = ["sponsor", "selfpromo", "interaction"]

    func load(_ video: YTVideo) async {
        do {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            async let segmentsTask = SponsorBlock.segments(video.id, categories: Self.skipCategories)
            var problems: [String] = []
            for resolved in try await YouTubeStream.candidates(video.id) {
                let asset = AVURLAsset(url: resolved.url, options: ["AVURLAssetHTTPUserAgentKey": resolved.userAgent])
                let item = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: item)
                player.play()
                if let problem = await ready(item) {
                    let probe = await YouTubeStream.probe(resolved)
                    problems.append("\(resolved.source): \(problem)\n\(probe)")
                    continue
                }
                state = .playing(resolved)
                segments = resolved.live ? [] : await segmentsTask
                watchSegments()
                return
            }
            player.replaceCurrentItem(with: nil)
            state = .failed("The stream didn't play.\n" + problems.joined(separator: "\n"))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Wait until the stream plays (nil) or fails (what went wrong, with the server's answer).
    private func ready(_ item: AVPlayerItem) async -> String? {
        for _ in 0..<200 {
            switch item.status {
            case .readyToPlay:
                return nil
            case .failed:
                var parts = [item.error?.localizedDescription ?? "failed"]
                if let underlying = (item.error as NSError?)?.userInfo[NSUnderlyingErrorKey] as? NSError {
                    parts.append("\(underlying.domain) \(underlying.code)")
                }
                if let event = item.errorLog()?.events.last {
                    parts.append("HTTP \(event.errorStatusCode) \(event.errorDomain) \(event.uri.flatMap { URL(string: $0)?.host } ?? "")")
                }
                return parts.joined(separator: " · ")
            default:
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return "timed out"
    }

    private func watchSegments() {
        guard !segments.isEmpty else { return }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                  queue: .main) { [weak self] time in
            Task { @MainActor in self?.check(time.seconds) }
        }
    }

    private func check(_ now: Double) {
        guard let segment = segments.first(where: { now >= $0.start && now < $0.end - 0.5 && !skipped.contains($0.UUID) }) else { return }
        skipped.insert(segment.UUID)
        player.seek(to: CMTime(seconds: segment.end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        show("Skipped \(SponsorBlock.names[segment.category] ?? segment.category)")
    }

    private func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    func stop() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct YouTubePlayerScreen: View {
    let video: YTVideo
    @StateObject private var model = YouTubePlayerModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    model.stop()
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

            ZStack(alignment: .bottom) {
                Color.black
                switch model.state {
                case .loading:
                    ProgressView().tint(.white)
                case .playing:
                    SystemVideoPlayer(player: model.player)
                case .failed(let message):
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text(message).multilineTextAlignment(.center).font(.subheadline)
                        Text("No ads are ever played instead. You can open it in the YouTube app.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding()
                }
                if let toast = model.toast {
                    Text(toast)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 44)
                        .transition(.opacity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .animation(.default, value: model.toast)

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
        .task { await model.load(video) }
        .onDisappear { model.stop() }
    }
}

/// iPhone's own player (AVPlayerViewController): full screen, rotation and its controls.
private struct SystemVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
