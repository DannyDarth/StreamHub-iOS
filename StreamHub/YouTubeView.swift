import SwiftUI
import WebKit

/// The YouTube tab: your Home, Shorts and Subscriptions (signed in on Google's own page), search and
/// channel pages. Videos play in StreamHub's player with no ads and SponsorBlock.
struct YouTubeView: View {
    private enum FeedSection: String, CaseIterable, Identifiable {
        case home = "Home"
        case shorts = "Shorts"
        case subscriptions = "Subscriptions"
        case history = "History"
        case later = "Watch later"
        var id: String { rawValue }
        /// Short enough for four tabs on an iPhone.
        var label: String { self == .subscriptions ? "Subs" : rawValue }
    }

    @State private var section: FeedSection = .home
    /// The section Watch later goes back to.
    @State private var lastMain: FeedSection = .home
    /// Filter by channel: any channel you're subscribed to; shows its latest videos.
    @State private var channelFilter: YTChannel?
    @State private var subscribed: [YTChannel] = []
    @State private var channels: [String] = []
    @State private var query = ""
    @State private var searching = false
    @State private var signedIn = false
    @State private var account: YTAccount?
    @State private var showSignIn = false
    @State private var reloadToken = 0
    @ObservedObject private var host = YouTubePlayerHost.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search YouTube", text: $query)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { searching = !query.trimmingCharacters(in: .whitespaces).isEmpty }
                if searching || !query.isEmpty {
                    Button {
                        query = ""
                        searching = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)

            if searching {
                YouTubeSearchResults(query: query, play: { YouTubePlayerHost.shared.play($0) })
                    .id(query)
            } else {
                HStack {
                    // Home, Shorts, Subscriptions, History; Watch later sits on the row below
                    Picker("Section", selection: Binding(
                        get: { section == .later ? lastMain : section },
                        set: { section = $0; lastMain = $0; channelFilter = nil }
                    )) {
                        ForEach([FeedSection.home, .shorts, .subscriptions, .history]) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .opacity(section == .later ? 0.55 : 1)
                    if signedIn {
                        Menu {
                            if let account { Text(account.name) }
                            Button("Sign out of YouTube", role: .destructive) { Task { await signOut() } }
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.title3)
                        }
                        .accessibilityLabel("YouTube account")
                    }
                }
                .padding(.horizontal, 16)

                // Filter by channel (the channels in the list) and Watch later
                HStack(spacing: 10) {
                    Menu {
                        Button {
                            channelFilter = nil
                        } label: {
                            Label("All channels", systemImage: channelFilter == nil ? "checkmark" : "")
                        }
                        ForEach(subscribed) { channel in
                            Button {
                                channelFilter = channel
                            } label: {
                                Label(channel.name, systemImage: channelFilter?.id == channel.id ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Label(channelFilter?.name ?? "Filter by channel", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(channelFilter == nil ? Color(uiColor: .secondarySystemBackground) : Color.white, in: Capsule())
                            .foregroundStyle(channelFilter == nil ? Color.primary : Color.black)
                    }
                    .disabled(subscribed.isEmpty)
                    if channelFilter != nil {
                        Button { channelFilter = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Show all channels")
                    }
                    Spacer()
                    if signedIn {
                        Button {
                            section = section == .later ? lastMain : .later
                            channelFilter = nil
                        } label: {
                            Label("Watch later", systemImage: "clock")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(section == .later ? Color.white : Color(uiColor: .secondarySystemBackground), in: Capsule())
                                .foregroundStyle(section == .later ? Color.black : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)

                if !signedIn {
                    Button {
                        showSignIn = true
                    } label: {
                        Label("Sign in to YouTube for your recommendations and subscriptions", systemImage: "person.crop.circle.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }

                if let channel = channelFilter {
                    YouTubeChannelView(id: channel.id, play: { YouTubePlayerHost.shared.play($0) }, compact: true)
                        .id("filter-\(channel.id)")
                } else {
                switch section {
                case .shorts:
                    YouTubeShortsView().id("shorts-\(reloadToken)")
                case .home:
                    YouTubeFeedList(kind: .home, play: { YouTubePlayerHost.shared.play($0) }, channels: $channels).id("home-\(reloadToken)")
                case .subscriptions:
                    if signedIn {
                        YouTubeFeedList(kind: .subscriptions, play: { YouTubePlayerHost.shared.play($0) }, channels: $channels).id("subs-\(reloadToken)")
                    } else {
                        Spacer()
                        Text("Sign in to see new videos from your subscriptions.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                case .later:
                    if signedIn {
                        YouTubeFeedList(kind: .later, play: { YouTubePlayerHost.shared.play($0) }, channels: $channels).id("later-\(reloadToken)")
                    } else {
                        Spacer()
                        Text("Sign in to see your Watch later list.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                case .history:
                    if signedIn {
                        YouTubeFeedList(kind: .history, play: { YouTubePlayerHost.shared.play($0) }, channels: $channels).id("history-\(reloadToken)")
                    } else {
                        Spacer()
                        Text("Sign in to see the videos you've watched.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                }
            }
        }
        .task {
            await refreshAccount()
            if signedIn { subscribed = (try? await YouTubeAPI.shared.subscribedChannels()) ?? [] }
        }
        .fullScreenCover(isPresented: $host.expanded) { ExpandedYouTubePlayer() }
        .sheet(isPresented: $showSignIn) {
            YouTubeSignInSheet {
                showSignIn = false
                Task {
                    await refreshAccount()
                    reloadToken += 1
                }
            }
        }
    }

    private func refreshAccount() async {
        signedIn = await YouTubeAPI.signedIn()
        account = signedIn ? try? await YouTubeAPI.shared.account() : nil
    }

    private func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let google = records.filter { record in
            let name = record.displayName
            return ["youtube.com", "google.com"].contains { name == $0 || name.hasSuffix("." + $0) }
        }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: google)
        await refreshAccount()
        reloadToken += 1
    }
}

/// Home, Subscriptions or History, loading more as you scroll. Subscriptions and History are
/// grouped by day.
private struct YouTubeFeedList: View {
    enum Kind { case home, subscriptions, history, later }
    let kind: Kind
    let play: (YTVideo) -> Void
    /// Only this channel's videos (Filter by channel); the list's channels go back up for the menu.
    var filter: String? = nil
    @Binding var channels: [String]

    @State private var videos: [YTVideo] = []
    @State private var next: String?
    @State private var loading = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if kind == .subscriptions || kind == .history {
                    ForEach(groups) { group in
                        Text(group.label).font(.title3.weight(.bold)).padding(.horizontal, 16)
                        ForEach(group.videos) { video in row(video) }
                    }
                } else {
                    ForEach(shown) { video in row(video) }
                }
                if let error {
                    VStack(spacing: 8) {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Try again") { Task { await load(more: !videos.isEmpty) } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else if loading || (next != nil) || !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .id(videos.count)
                        .onAppear { Task { await load(more: loaded) } }
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear { reportChannels() }
        .onChange(of: videos.count) { _ in reportChannels() }
        .refreshable {
            videos = []
            next = nil
            loaded = false
            await load(more: false)
        }
    }

    private func row(_ video: YTVideo) -> some View {
        switch kind {
        case .history:
            return YouTubeVideoRow(video: video, play: play, onRemove: video.remove != nil ? { remove(video) } : nil)
        case .later:
            return YouTubeVideoRow(video: video, play: play, onRemove: { removeFromLater(video) },
                                   removeLabel: "Remove from Watch later")
        default:
            return YouTubeVideoRow(video: video, play: play, onHide: { hidden in videos.removeAll { $0.id == hidden.id } })
        }
    }

    /// Watch later: take a video off the list.
    private func removeFromLater(_ video: YTVideo) {
        Task {
            do {
                try await YouTubeAPI.shared.editWatchLater(video.id, add: false)
                videos.removeAll { $0.id == video.id }
            } catch {
                self.error = "Couldn't remove it: \(error.localizedDescription)"
            }
        }
    }

    /// History: take a video out of your YouTube watch history.
    private func remove(_ video: YTVideo) {
        guard let token = video.remove else { return }
        Task {
            do {
                try await YouTubeAPI.shared.removeFromHistory(token)
                videos.removeAll { $0.id == video.id }
                if YouTubePlayerHost.shared.isPlaying(video) { YouTubePlayerHost.shared.close() }
            } catch {
                self.error = "Couldn't remove it: \(error.localizedDescription)"
            }
        }
    }

    private var shown: [YTVideo] {
        guard let filter else { return videos }
        return videos.filter { $0.channel == filter }
    }

    private func reportChannels() {
        var seen = Set<String>()
        channels = videos.map(\.channel).filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private struct DayGroup: Identifiable {
        let label: String
        var videos: [YTVideo]
        var id: String { label }
    }

    private var groups: [DayGroup] {
        var result: [DayGroup] = []
        for video in shown {
            let label = kind == .history
                ? ((video.day?.isEmpty == false) ? video.day! : "Earlier")
                : video.live ? "Live now" : YouTubeDays.label(video.published)
            if let index = result.firstIndex(where: { $0.label == label }) {
                result[index].videos.append(video)
            } else {
                result.append(DayGroup(label: label, videos: [video]))
            }
        }
        return result
    }

    private func load(more: Bool) async {
        guard !loading, !(more && next == nil) else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let page: YTFeed
            switch kind {
            case .home: page = try await YouTubeAPI.shared.home(next: more ? next : nil)
            case .subscriptions: page = try await YouTubeAPI.shared.subscriptions(next: more ? next : nil)
            case .history: page = try await YouTubeAPI.shared.history(next: more ? next : nil)
            case .later: page = try await YouTubeAPI.shared.watchLater(next: more ? next : nil)
            }
            let seen = Set(videos.map(\.id))
            videos += page.videos.filter { !seen.contains($0.id) }
            next = page.next
            loaded = true
            if videos.isEmpty {
                switch kind {
                case .home: error = "YouTube didn't recommend any videos."
                case .subscriptions: error = "No new videos."
                case .history: error = "Your watch history is empty (or turned off in your YouTube account)."
                case .later: error = "Nothing in Watch later. Save videos with ⋯ → Save to Watch later."
                }
            }
        } catch {
            self.error = error.localizedDescription
            loaded = true
        }
    }
}

private struct YouTubeSearchResults: View {
    let query: String
    let play: (YTVideo) -> Void
    @State private var results: YTSearch?
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let results {
                    if !results.channels.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(results.channels) { channel in
                                    NavigationLink {
                                        YouTubeChannelView(id: channel.id, play: play)
                                    } label: {
                                        VStack(spacing: 6) {
                                            YouTubeAvatar(url: channel.avatar, size: 64)
                                            Text(channel.name).font(.caption.weight(.semibold)).lineLimit(1)
                                        }
                                        .frame(width: 84)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    ForEach(results.videos) { YouTubeVideoRow(video: $0, play: play) }
                    if results.videos.isEmpty && results.channels.isEmpty {
                        Text("Nothing found.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    }
                } else if let error {
                    Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.vertical, 8)
        }
        .task {
            do { results = try await YouTubeAPI.shared.search(query) } catch { self.error = error.localizedDescription }
        }
    }
}

struct YouTubeChannelView: View {
    let id: String
    let play: (YTVideo) -> Void
    /// Inside the YouTube tab (Filter by channel): no navigation title.
    var compact = false
    @State private var page: YTChannelPage?
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let page {
                    HStack(spacing: 12) {
                        YouTubeAvatar(url: page.avatar, size: 56)
                        Text(page.name).font(.title2.weight(.bold))
                    }
                    .padding(.horizontal, 16)
                    if !page.description.isEmpty {
                        Text(page.description).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                            .padding(.horizontal, 16)
                    }
                    ForEach(page.videos) { YouTubeVideoRow(video: $0, play: play, showChannel: false) }
                } else if let error {
                    Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle(compact ? "" : (page?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { page = try await YouTubeAPI.shared.channel(id) } catch { self.error = error.localizedDescription }
        }
    }
}

private struct YouTubeVideoRow: View {
    let video: YTVideo
    let play: (YTVideo) -> Void
    var showChannel = true
    /// History or Watch later: take it off the list.
    var onRemove: (() -> Void)? = nil
    var removeLabel = "Remove from watch history"
    /// Not interested / Don't recommend channel worked: take it out of the list.
    var onHide: ((YTVideo) -> Void)? = nil
    @State private var savedForLater = false
    @ObservedObject private var host = YouTubePlayerHost.shared

    var body: some View {
        if host.isPlaying(video) {
            VStack(alignment: .leading, spacing: 8) {
                InlineYouTubePlayer(video: video)
                details.padding(.horizontal, 16)
            }
        } else {
            card.padding(.horizontal, 16)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { play(video) } label: {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: video.thumbnail) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color(uiColor: .secondarySystemBackground)
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                    if video.live {
                        Text("LIVE").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 4)).padding(8)
                    } else if !video.duration.isEmpty {
                        Text(video.duration).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4)).padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            details
        }
    }

    private var details: some View {
            HStack(alignment: .top, spacing: 10) {
                if showChannel {
                    channelLink { YouTubeAvatar(url: video.avatar, size: 36) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Button { play(video) } label: {
                        Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    if showChannel {
                        channelLink { Text(video.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Text([video.views, video.published].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Group {
                    Spacer(minLength: 4)
                    Menu {
                        if let url = URL(string: "https://www.youtube.com/watch?v=\(video.id)") {
                            ShareLink(item: url, subject: Text(video.title)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        if !video.live && removeLabel != "Remove from Watch later" {
                            Button {
                                Task {
                                    if (try? await YouTubeAPI.shared.editWatchLater(video.id, add: true)) != nil { savedForLater = true }
                                }
                            } label: {
                                Label(savedForLater ? "Saved to Watch later" : "Save to Watch later",
                                      systemImage: savedForLater ? "checkmark" : "clock")
                            }
                            .disabled(savedForLater)
                        }
                        if let token = video.notInterested {
                            Button { feedback(token) } label: {
                                Label("Not interested", systemImage: "nosign")
                            }
                        }
                        if let token = video.dontRecommend {
                            Button { feedback(token) } label: {
                                Label("Don't recommend channel", systemImage: "person.crop.circle.badge.minus")
                            }
                        }
                        if let onRemove {
                            Button(role: .destructive, action: onRemove) {
                                Label(removeLabel, systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel("More")
                }
            }
    }

    /// Not interested / Don't recommend channel: tell YouTube, then hide the video here.
    private func feedback(_ token: String) {
        Task {
            if (try? await YouTubeAPI.shared.sendFeedback(token)) != nil { onHide?(video) }
        }
    }

    @ViewBuilder
    private func channelLink<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        if let channelId = video.channelId {
            NavigationLink { YouTubeChannelView(id: channelId, play: play) } label: { label() }
                .buttonStyle(.plain)
        } else {
            label()
        }
    }
}

private struct YouTubeAvatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color(uiColor: .tertiarySystemBackground)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// "3 hours ago" → Today, Yesterday, a weekday, Last week… (the same as StreamHub desktop).
enum YouTubeDays {
    static func label(_ published: String, now: Date = Date()) -> String {
        let text = published.lowercased()
        if text.contains("scheduled") || text.contains("premieres") || text.contains("upcoming") { return "Upcoming" }
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*(second|minute|hour|day|week|month|year)"#),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let nRange = Range(m.range(at: 1), in: text), let unitRange = Range(m.range(at: 2), in: text) else {
            return "Earlier"
        }
        let n = Int(text[nRange]) ?? 0
        let unit = String(text[unitRange])
        if unit.hasPrefix("week") { return n == 1 ? "Last week" : "\(n) weeks ago" }
        if unit.hasPrefix("month") { return n == 1 ? "Last month" : "\(n) months ago" }
        if unit.hasPrefix("year") { return n == 1 ? "Last year" : "\(n) years ago" }
        let hours = unit.hasPrefix("day") ? n * 24 : unit.hasPrefix("hour") ? n : 0
        let date = now.addingTimeInterval(-Double(hours) * 3600)
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
        return "Last week"
    }
}

/// Sign in to YouTube on Google's own page. StreamHub never sees the password; the sign-in stays
/// in the app's web data (and the Keychain copy that survives new versions).
private struct YouTubeSignInSheet: View {
    let done: () -> Void

    var body: some View {
        NavigationStack {
            YouTubeSignInWebView(done: done)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in to YouTube")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                }
        }
    }
}

private struct YouTubeSignInWebView: UIViewRepresentable {
    let done: () -> Void
    static let mobileSafari = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1"

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Google refuses sign-in in embedded web views it recognizes: present as Safari
        view.customUserAgent = Self.mobileSafari
        view.navigationDelegate = context.coordinator
        if #available(iOS 16.4, *) { view.isInspectable = false }
        view.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3D%252F")!))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let done: () -> Void
        private var finished = false
        init(done: @escaping () -> Void) { self.done = done }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, url.scheme?.lowercased() == "https", url.user == nil,
                  let host = url.host?.lowercased() else {
                decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
                return
            }
            let allowed = ["google.com", "youtube.com", "gstatic.com", "googleusercontent.com", "google.co.uk"]
                .contains { host == $0 || host.hasSuffix("." + $0) }
            decisionHandler(allowed || action.targetFrame?.isMainFrame == false ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, let host = webView.url?.host?.lowercased(),
                  host == "www.youtube.com" || host == "m.youtube.com" else { return }
            Task { @MainActor in
                if await YouTubeAPI.signedIn() {
                    finished = true
                    done()
                }
            }
        }
    }
}
