import Foundation
import SwiftUI

/// YouTube filters: hide videos YouTube labels as made with AI, videos whose title has one of your
/// words, and channels you've hidden. Used on Home, Shorts, Subscriptions, search and channel pages
/// (not History or Watch later: you picked those).
///
/// The AI label isn't in YouTube's lists, only on each video's own page, so each video is checked
/// once (YouTubeAPI.aiLabels) and the answer remembered.
@MainActor
final class YouTubeFilter: ObservableObject {
    static let shared = YouTubeFilter()

    static let hideAIKey = "streamhub.yt.hideAI"
    static let wordsKey = "streamhub.yt.hiddenWords"
    private static let channelsKey = "streamhub.yt.hiddenChannels"
    private static let labelsKey = "streamhub.yt.aiLabels"

    struct HiddenChannel: Codable, Hashable, Identifiable {
        let id: String
        let name: String
    }

    @Published private(set) var hiddenChannels: [HiddenChannel] = []
    /// Bumped when a filter changes, so lists redraw.
    @Published private(set) var version = 0
    private var labels: [String: Bool] = [:]
    private var labelOrder: [String] = []

    private init() {
        UserDefaults.standard.register(defaults: [Self.hideAIKey: true])
        if let data = UserDefaults.standard.data(forKey: Self.channelsKey),
           let saved = try? JSONDecoder().decode([HiddenChannel].self, from: data) {
            hiddenChannels = saved
        }
        if let saved = UserDefaults.standard.array(forKey: Self.labelsKey) as? [[Any]] {
            for pair in saved {
                if let id = pair.first as? String, let ai = pair.last as? Bool {
                    labels[id] = ai
                    labelOrder.append(id)
                }
            }
        }
    }

    var hideAI: Bool { UserDefaults.standard.bool(forKey: Self.hideAIKey) }

    private var words: [String] {
        (UserDefaults.standard.string(forKey: Self.wordsKey) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    func changed() { version += 1 }

    func hide(channelId: String, name: String) {
        guard !hiddenChannels.contains(where: { $0.id == channelId }) else { return }
        hiddenChannels.append(HiddenChannel(id: channelId, name: name))
        saveChannels()
    }

    /// Whether a channel (from a Short: id when known, and name) is hidden.
    func isHidden(id: String?, name: String) -> Bool {
        hiddenChannels.contains { channel in
            (id != nil && channel.id == id) || (channel.id.hasPrefix("name:") && channel.name.lowercased() == name.lowercased())
        }
    }

    func unhide(_ channel: HiddenChannel) {
        hiddenChannels.removeAll { $0.id == channel.id }
        saveChannels()
    }

    private func saveChannels() {
        if let data = try? JSONEncoder().encode(hiddenChannels) {
            UserDefaults.standard.set(data, forKey: Self.channelsKey)
        }
        changed()
    }

    /// Hidden channels and title words (no waiting). `channels: false` on a channel's own page.
    func quick(_ videos: [YTVideo], channels: Bool = true) -> [YTVideo] {
        let ids = Set(hiddenChannels.map(\.id))
        // hidden from Shorts before the channel's id was known: by name
        let names = Set(hiddenChannels.filter { $0.id.hasPrefix("name:") }.map { $0.name.lowercased() })
        let ws = words
        return videos.filter { video in
            if channels, let id = video.channelId, ids.contains(id) { return false }
            if channels, !video.channel.isEmpty, names.contains(video.channel.lowercased()) { return false }
            let title = video.title.lowercased()
            return !ws.contains { title.contains($0) }
        }
    }

    /// Whether YouTube labels these videos as made with AI (checked once each, then remembered).
    func aiLabelled(_ ids: [String]) async -> Set<String> {
        guard hideAI else { return [] }
        var seen = Set<String>()
        let unknown = ids.filter { labels[$0] == nil && seen.insert($0).inserted }
        var start = 0
        while start < unknown.count {
            let batch = Array(unknown[start..<min(start + 20, unknown.count)])
            start += 20
            let result = (try? await YouTubeAPI.shared.aiLabels(batch)) ?? [:]
            for id in batch {
                // couldn't check: show it
                remember(id, result[id] ?? false)
            }
        }
        if !unknown.isEmpty { saveLabels() }
        return Set(ids.filter { labels[$0] == true })
    }

    /// All the filters.
    func clean(_ videos: [YTVideo], channels: Bool = true) async -> [YTVideo] {
        let kept = quick(videos, channels: channels)
        guard hideAI, !kept.isEmpty else { return kept }
        let ai = await aiLabelled(kept.map(\.id))
        return kept.filter { !ai.contains($0.id) }
    }

    private func remember(_ id: String, _ ai: Bool) {
        if labels[id] == nil { labelOrder.append(id) }
        labels[id] = ai
    }

    private func saveLabels() {
        let keep = labelOrder.suffix(6000)
        labelOrder = Array(keep)
        let pairs: [[Any]] = keep.compactMap { id in labels[id].map { [id, $0] } }
        UserDefaults.standard.set(pairs, forKey: Self.labelsKey)
    }
}
