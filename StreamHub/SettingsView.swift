import WebKit
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
    @AppStorage("streamhub.ytComments") private var showYouTubeComments = true
    @State private var sponsorBlock = SponsorBlock.actions
    @State private var signOutConfirm = false
    @State private var signedOut = false

    private func signOut() {
        SignInVault.clear()
        let store = WKWebsiteDataStore.default()
        let domains = ["twitch.tv", "kick.com", "crunchyroll.com", "youtube.com", "google.com"]
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let matching = records.filter { record in
                domains.contains { record.displayName == $0 || record.displayName.hasSuffix("." + $0) }
            }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching) {
                signedOut = true
            }
        }
    }

    var body: some View {
        Form {
            Section {
                Button("Sign out of Twitch, Kick, YouTube and Crunchyroll", role: .destructive) {
                    signOutConfirm = true
                }
                .confirmationDialog("Sign out of Twitch, Kick, YouTube and Crunchyroll?", isPresented: $signOutConfirm,
                                    titleVisibility: .visible) {
                    Button("Sign out", role: .destructive) { signOut() }
                }
                if signedOut {
                    Text("Signed out.").font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Sign-ins")
            } footer: {
                Text("Your sign-ins are kept on this iPhone when you install a new version, so you don't have to sign in (and do two-factor) again. They're saved in the iPhone's Keychain and never leave the device.")
            }
            Section {
                Toggle("Show comments", isOn: $showYouTubeComments)
            } header: {
                Text("YouTube")
            } footer: {
                Text("A video's comments show under the bigger player (the speech-bubble button under a playing video opens it).")
            }
            Section {
                ForEach(SponsorBlock.categories) { category in
                    Picker(selection: Binding(
                        get: { sponsorBlock[category.id] ?? .off },
                        set: { value in
                            sponsorBlock[category.id] = value
                            SponsorBlock.actions = sponsorBlock
                        }
                    )) {
                        ForEach(SponsorBlock.Action.allCases, id: \.self) { Text($0.label).tag($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                            Text(category.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Reset to the defaults") {
                    sponsorBlock = SponsorBlock.defaults
                    SponsorBlock.actions = sponsorBlock
                }
            } header: {
                Text("YouTube · SponsorBlock")
            } footer: {
                Text("Parts of videos the SponsorBlock community marked. Skip automatically jumps past them; Show a Skip button lets you choose each time. Applies to the next video you open.")
            }
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
                Text("StreamHub checks GitHub for a new version and shows a banner with a download link. Install the new IPA with your signing service (Signulous, AltStore, Sideloadly…). Use the same bundle ID so it installs over this one and keeps your settings and sign-ins.")
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
