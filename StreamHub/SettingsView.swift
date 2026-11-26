import SwiftUI

/// Clean slate for Twitch playback experiments. The previous adblocking and
/// proxy controls are intentionally removed from Settings.
struct SettingsView: View {
    private let retiredKeys = [
        "streamhub.twitchClientAdFiltering",
        "streamhub.twitchWebAdDiagnostics",
        "streamhub.braveStyleFilteringEnabled",
        "streamhub.autoReturnOnTwitchAdMarker",
        "streamhub.twitchProxyEnabled",
        "streamhub.twitchProxyURL",
        "streamhub.twitchForwardProxyPreference",
        "streamhub.twitchForwardProxyFallback"
    ]

    @AppStorage(UpdateChecker.enabledKey) private var checkForUpdates = true
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        Form {
            Section("Playback") {
                Text("Twitch streams play ad-free through StreamHub's ad-free servers. Kick uses its regular player.")
                Text("Ads never interrupt a Twitch stream: if no ad-free server works, the stream doesn't play. The regular Twitch player is only used if you choose it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Check for updates", isOn: $checkForUpdates)
                LabeledContent("Version", value: UpdateChecker.currentVersion)
                Button(updates.checking ? "Checking…" : "Check now") {
                    Task { await updates.check(force: true) }
                }
                .disabled(updates.checking)
                if let status = updates.status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("StreamHub checks GitHub for a new version and shows a banner with a download link. Install the new IPA with AltStore or Sideloadly; your settings and sign-ins are kept.")
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            // Remove persisted opt-ins, including those left enabled by older
            // sideloaded builds. Default behavior is ordinary web playback.
            for key in retiredKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
