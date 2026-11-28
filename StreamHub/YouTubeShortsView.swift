import SwiftUI
import WebKit
import Combine

/// YouTube Shorts: one vertical Short at a time, filling the space, looping. Swipe up for the next
/// one, down for the one before. Each plays in StreamHub's player (no ads, SponsorBlock); they
/// start muted (tap the sound button to turn it on, and it stays on for the next ones).
struct YouTubeShortsView: View {
    @ObservedObject private var host = YouTubePlayerHost.shared
    @AppStorage("streamhub.shorts.sound") private var sound = false
    @State private var shorts: [YTVideo] = []
    @State private var next: String?
    @State private var started = false
    @State private var loading = false
    @State private var error: String?
    @State private var index = 0
    @State private var drag: CGFloat = 0
    @State private var title = ""

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
                        page(i, size: geo.size)
                            .offset(y: CGFloat(i - index) * height + drag)
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
            .onTapGesture { host.player?.togglePause() }
        }
        .task { if shorts.isEmpty { await loadMore() } }
        .onChange(of: index) { _ in playCurrent() }
        .onDisappear { host.close() }
        .onReceive(titlePublisher) { value in
            title = (value ?? "").replacingOccurrences(of: " - YouTube", with: "")
        }
    }

    private var titlePublisher: AnyPublisher<String?, Never> {
        guard let webView = host.player?.webView else { return Just(nil).eraseToAnyPublisher() }
        return webView.publisher(for: \.title).eraseToAnyPublisher()
    }

    @ViewBuilder
    private func page(_ i: Int, size: CGSize) -> some View {
        let short = shorts[i]
        ZStack {
            Color.black
            AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(short.id)/oardefault.jpg")) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.black
            }
            if i == index, let player = host.player, host.video?.id == short.id {
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
                        host.player?.shortsSetup(muted: !sound)
                    } label: {
                        Image(systemName: sound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                    .accessibilityLabel(sound ? "Turn the sound off" : "Turn the sound on")
                    if shorts.indices.contains(index), let url = URL(string: "https://www.youtube.com/shorts/\(shorts[index].id)") {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share")
                    }
                }
                .font(.title2)
                .shadow(radius: 3)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
    }

    private func playCurrent() {
        guard shorts.indices.contains(index) else { return }
        title = ""
        let short = shorts[index]
        host.play(short)
        let muted = !sound
        let player = host.player
        // YouTube's page starts it muted: set the sound (and looping) once it's going
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if host.video?.id == short.id { player?.shortsSetup(muted: muted) }
        }
        if index >= shorts.count - 3 { Task { await loadMore() } }
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
            if wasEmpty && !shorts.isEmpty { playCurrent() }
        } catch {
            if shorts.isEmpty { self.error = "Couldn't load Shorts: \(error.localizedDescription)" }
        }
    }
}
