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

    @State private var signOutConfirm = false
    @State private var signedOut = false

    private func signOut() {
        SignInVault.clear()
        let store = WKWebsiteDataStore.default()
        let domains = ["twitch.tv", "kick.com", "crunchyroll.com"]
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
                Button("Sign out of Twitch, Kick and Crunchyroll", role: .destructive) {
                    signOutConfirm = true
                }
                .confirmationDialog("Sign out of Twitch, Kick and Crunchyroll?", isPresented: $signOutConfirm,
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
            Section("Playback") {
                Text("Twitch and Kick use their regular players.")
                Text("Previous experimental adblocking, playlist proxy, and forward-proxy settings have been retired while we prepare a fresh implementation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
