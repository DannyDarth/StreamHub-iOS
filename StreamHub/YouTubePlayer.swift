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
    }

    static let clientVersion = "20.10.4"
    static let userAgent = "com.google.ios.youtube/\(clientVersion) (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"

    /// The stream to play: first as YouTube's website gives it to Safari, then as YouTube's
    /// iPhone app gets it. Both are HLS streams without ads.
    static func resolve(_ id: String) async throws -> Resolved {
        guard id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            throw YouTubeError.failed("Not a YouTube video.")
        }
        var reasons: [String] = []
        do {
            let web = try await YouTubeAPI.shared.player(id)
            if web.status == "OK", let hls = web.hls, let url = checked(hls) {
                return Resolved(url: url, title: web.title, author: web.author, live: web.live,
                                userAgent: YouTubeAPI.safariUserAgent)
            }
            if web.status != "OK" { reasons.append(web.reason ?? "YouTube won't play this video here.") }
        } catch {
            reasons.append(error.localizedDescription)
        }
        do {
            return try await resolveIOS(id)
        } catch {
            reasons.append(error.localizedDescription)
        }
        throw YouTubeError.failed(reasons.first { !$0.contains("ad-free stream") } ?? reasons.last
            ?? "YouTube didn't give an ad-free stream for this video.")
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
            let resolved = try await YouTubeStream.resolve(video.id)
            let asset = AVURLAsset(url: resolved.url, options: ["AVURLAssetHTTPUserAgentKey": resolved.userAgent])
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.play()
            state = .playing(resolved)
            segments = resolved.live ? [] : await segmentsTask
            watchSegments()
        } catch {
            state = .failed(error.localizedDescription)
        }
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
