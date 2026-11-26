import SwiftUI

@main
struct StreamHubApp: App {
    init() {
        // Retire all saved adblocking/proxy experiments before any WKWebView
        // or Twitch player is created, even if Settings is never opened.
        for key in [
            "streamhub.twitchClientAdFiltering",
            "streamhub.twitchWebAdDiagnostics",
            "streamhub.braveStyleFilteringEnabled",
            "streamhub.autoReturnOnTwitchAdMarker",
            "streamhub.twitchProxyEnabled",
            "streamhub.twitchProxyURL",
            "streamhub.twitchForwardProxyPreference",
            "streamhub.twitchForwardProxyFallback"
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var signInsRestored = false

    var body: some Scene {
        WindowGroup {
            Group {
                if signInsRestored {
                    ContentView()
                } else {
                    // a moment at launch: saved sign-ins go back before any site loads
                    Color.black.ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
            .task {
                await SignInVault.restore()
                signInsRestored = true
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active, signInsRestored {
                Task { await SignInVault.save() }
            }
        }
    }
}
