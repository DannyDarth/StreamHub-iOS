import SwiftUI
import WebKit
import Combine

/// The Shorts tab's players: the Short on screen plus the one before and the next two, loaded
/// ahead (held paused and muted) so swiping to the next starts it straight away.
@MainActor
final class ShortsPlayers: ObservableObject {
    @Published private(set) var players: [String: YouTubeWebPlayer] = [:]

    func player(for id: String) -> YouTubeWebPlayer? { players[id] }

    /// Keep players for `keep` (ids, in order), make the missing ones, drop the rest. `active` plays.
    func update(keep: [YTVideo], active: String, sound: Bool) {
        let ids = Set(keep.map(\.id))
        for (id, player) in players where !ids.contains(id) {
            player.stop()
            players[id] = nil
        }
        for video in keep where players[video.id] == nil {
            let player = YouTubeWebPlayer(video: video, shorts: true)
            players[video.id] = player
            Task { await player.start() }
        }
        for (id, player) in players { player.shortsState(active: id == active, sound: sound, unpause: true) }
    }

    func stopAll() {
        for player in players.values { player.stop() }
        players = [:]
    }
}

/// YouTube Shorts: one vertical Short at a time, filling the space, looping. Swipe up for the next
/// one, down for the one before. Each plays in StreamHub's player (no ads, SponsorBlock); they
/// start muted (the sound button turns it on, and it stays on for the next ones). Tap to pause.
struct YouTubeShortsView: View {
    @StateObject private var pool = ShortsPlayers()
    @AppStorage("streamhub.shorts.sound") private var sound = false
    @State private var shorts: [YTVideo] = []
    @State private var next: String?
    @State private var started = false
    @State private var loading = false
    @State private var error: String?
    @State private var index = 0
    @State private var drag: CGFloat = 0
    @State private var title = ""
    @State private var paused = false

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack {
                Color.black
                if shorts.isEmpty {
                    VStack(spacing: 10) {
                        if let error {
                            Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Try again") { Task { await loadMore() } }
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .padding()
                } else {
                    // the Short before, this one and the next, stacked; dragging moves them
                    ForEach(max(0, index - 1)...min(shorts.count - 1, index + 1), id: \.self) { i in
                        page(shorts[i], size: geo.size)
                            .offset(y: CGFloat(i - index) * height + drag)
                    }
                    if paused {
                        Image(systemName: "play.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 4)
                            .allowsHitTesting(false)
                    }
                    overlay
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        var d = value.translation.height
                        if index == 0 && d > 0 { d /= 3 }
                        if index >= shorts.count - 1 && d < 0 { d /= 3 }
                        drag = d
                    }
                    .onEnded { value in
                        let d = value.predictedEndTranslation.height
                        if d < -height * 0.25, index < shorts.count - 1 {
                            withAnimation(.easeOut(duration: 0.22)) { index += 1; drag = 0 }
                        } else if d > height * 0.25, index > 0 {
                            withAnimation(.easeOut(duration: 0.22)) { index -= 1; drag = 0 }
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { drag = 0 }
                        }
                    }
            )
            .onTapGesture {
                paused.toggle()
                current?.togglePause()
            }
        }
        .task {
            // a video playing elsewhere in the YouTube tab stops
            YouTubePlayerHost.shared.close()
            if shorts.isEmpty { await loadMore() }
        }
        .onChange(of: index) { _ in show() }
        .onDisappear { pool.stopAll() }
        .onReceive(titlePublisher) { value in
            title = (value ?? "").replacingOccurrences(of: " - YouTube", with: "")
        }
    }

    private var current: YouTubeWebPlayer? {
        shorts.indices.contains(index) ? pool.player(for: shorts[index].id) : nil
    }

    private var titlePublisher: AnyPublisher<String?, Never> {
        guard let webView = current?.webView else { return Just(nil).eraseToAnyPublisher() }
        return webView.publisher(for: \.title).eraseToAnyPublisher()
    }

    @ViewBuilder
    private func page(_ short: YTVideo, size: CGSize) -> some View {
        ZStack {
            Color.black
            AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(short.id)/oardefault.jpg")) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.black
            }
            if let player = pool.player(for: short.id) {
                PlayerStage(player: player, video: short, mini: false)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Title, sound and share over the Short.
    private var overlay: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if !title.isEmpty && title != "YouTube" {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    Label("No ads · SponsorBlock", systemImage: "checkmark.shield")
                        .font(.caption2).foregroundStyle(.green)
                }
                .shadow(radius: 3)
                Spacer()
                VStack(spacing: 18) {
                    Button {
                        sound.toggle()
                        current?.shortsState(active: true, sound: sound)
                    } label: {
                        Image(systemName: sound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(sound ? "Turn the sound off" : "Turn the sound on")
                    if shorts.indices.contains(index), let url = URL(string: "https://www.youtube.com/shorts/\(shorts[index].id)") {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Share")
                    }
                }
                .font(.title2)
                .shadow(radius: 3)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
    }

    /// Play the Short on screen; get the next two (and keep the one before) ready.
    private func show() {
        guard shorts.indices.contains(index) else { return }
        title = ""
        paused = false
        let keep = Array(shorts[max(0, index - 1)...min(shorts.count - 1, index + 2)])
        pool.update(keep: keep, active: shorts[index].id, sound: sound)
        if index >= shorts.count - 4 { Task { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, !(started && next == nil) else { return }
        loading = true
        defer { loading = false }
        do {
            let feed = try await YouTubeAPI.shared.shorts(next: started ? next : nil)
            started = true
            next = feed.next
            error = nil
            let have = Set(shorts.map(\.id))
            let wasEmpty = shorts.isEmpty
            shorts += feed.videos.filter { !have.contains($0.id) }
            if wasEmpty && !shorts.isEmpty { show() }
        } catch {
            if shorts.isEmpty { self.error = "Couldn't load Shorts: \(error.localizedDescription)" }
        }
    }
}
