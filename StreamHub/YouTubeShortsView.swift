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
    @State private var notice: String?

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
                    // the Short before, this one and the next two, stacked (out of sight but on
                    // screen for the system, so they load like the one showing); dragging moves them
                    ForEach(max(0, index - 1)...min(shorts.count - 1, index + 2), id: \.self) { i in
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
                    if let notice {
                        Text(notice)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.black.opacity(0.75), in: Capsule())
                            .foregroundStyle(.white)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
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
                        guard let player = current else { return }
                        if sound {
                            // a Short that was loaded ahead only takes the sound when it starts
                            // playing (swiping away and back did it): pause it, then play with sound
                            player.shortsState(active: false, sound: true)
                            Task {
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                if current === player { player.shortsState(active: true, sound: sound) }
                            }
                        } else {
                            player.shortsState(active: true, sound: false)
                        }
                    } label: {
                        Image(systemName: sound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(sound ? "Turn the sound off" : "Turn the sound on")
                    Button { hideChannel() } label: {
                        Image(systemName: "eye.slash").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Hide this channel")
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

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if notice == text { notice = nil }
        }
    }

    /// Hide the Short's channel everywhere (Settings → YouTube filters to undo) and move on.
    private func hideChannel() {
        guard shorts.indices.contains(index), let player = current else { return }
        let id = shorts[index].id
        Task {
            guard let info = await player.channelInfo() else {
                flash("Wait a moment: the channel isn't known yet")
                return
            }
            YouTubeFilter.shared.hide(channelId: info.id ?? "name:\(info.name)", name: info.name)
            flash("\(info.name) hidden")
            drop(id)
        }
    }

    /// Take a Short out of the list and show the next one.
    private func drop(_ id: String) {
        guard let at = shorts.firstIndex(where: { $0.id == id }) else { return }
        shorts.remove(at: at)
        if index >= shorts.count { index = max(0, shorts.count - 1) }
        show()
    }

    /// A Short from a hidden channel (known once its page loads): skip it.
    private func skipIfHidden(_ id: String) {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard shorts.indices.contains(index), shorts[index].id == id,
                  let player = current, let info = await player.channelInfo(),
                  YouTubeFilter.shared.isHidden(id: info.id, name: info.name) else { return }
            drop(id)
        }
    }

    /// Play the Short on screen; get the next two (and keep the one before) ready.
    private func show() {
        guard shorts.indices.contains(index) else { return }
        title = ""
        paused = false
        let keep = Array(shorts[max(0, index - 1)...min(shorts.count - 1, index + 2)])
        pool.update(keep: keep, active: shorts[index].id, sound: sound)
        skipIfHidden(shorts[index].id)
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
            // Shorts YouTube labels as made with AI are left out (Settings → YouTube)
            let ai = await YouTubeFilter.shared.aiLabelled(feed.videos.map(\.id))
            shorts += feed.videos.filter { !have.contains($0.id) && !ai.contains($0.id) }
            if wasEmpty && !shorts.isEmpty { show() }
        } catch {
            if shorts.isEmpty { self.error = "Couldn't load Shorts: \(error.localizedDescription)" }
        }
    }
}
