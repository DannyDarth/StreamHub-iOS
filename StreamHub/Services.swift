import SwiftUI

/// The services StreamHub shows (Settings → Select services to activate). A service that's off
/// disappears from the main tabs, Followed and Settings until it's turned back on; its sign-in
/// and settings are kept.
enum Service: String, CaseIterable, Identifiable {
    case twitch = "Twitch"
    case kick = "Kick"
    case youtube = "YouTube"
    case crunchyroll = "Crunchyroll"

    var id: String { rawValue }
    var key: String { "streamhub.service.\(rawValue.lowercased())" }

    var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static var active: [Service] { allCases.filter(\.isOn) }
}
