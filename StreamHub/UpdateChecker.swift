import Foundation
import SwiftUI

/// Checks GitHub for a newer StreamHub iOS release. Sideloaded apps don't update by themselves, so
/// StreamHub shows a banner with a link to the release page; installing stays a manual step
/// (AltStore or Sideloadly).
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let page: URL
        /// The IPA itself, for signing services that take a link (Signulous and others).
        let ipa: URL?
    }

    static let shared = UpdateChecker()

    static let enabledKey = "streamhub.updateCheck"
    private static let lastCheckKey = "streamhub.updateLastCheck"
    private static let skippedKey = "streamhub.updateSkippedVersion"
    private static let latestURL = URL(string: "https://api.github.com/repos/DannyDarth/StreamHub-iOS/releases/latest")!
    private static let releasesPrefix = "https://github.com/DannyDarth/StreamHub-iOS/releases/"
    private static let tagPrefix = "streamhub-ios-v"
    private static let interval: TimeInterval = 6 * 60 * 60

    /// A newer release the user hasn't dismissed.
    @Published private(set) var available: Release?
    /// What the last manual check found, for Settings.
    @Published private(set) var status: String?
    @Published private(set) var checking = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// On launch and when the app comes back: at most every 6 hours, unless `force`.
    @MainActor
    func check(force: Bool = false) async {
        guard force || Self.enabled, !checking else { return }
        let defaults = UserDefaults.standard
        if !force, Date().timeIntervalSince1970 - defaults.double(forKey: Self.lastCheckKey) < Self.interval {
            return
        }
        checking = true
        defer { checking = false }
        do {
            let release = try await Self.latest()
            defaults.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            if Self.isNewer(release.version, than: Self.currentVersion) {
                if force || defaults.string(forKey: Self.skippedKey) != release.version {
                    available = release
                }
                status = "StreamHub iOS \(release.version) is available."
            } else {
                available = nil
                status = "You have the latest version (\(Self.currentVersion))."
            }
        } catch {
            status = "Couldn't check for updates: \(error.localizedDescription)"
        }
    }

    /// Hide the banner for this version.
    @MainActor
    func dismiss() {
        if let available {
            UserDefaults.standard.set(available.version, forKey: Self.skippedKey)
        }
        available = nil
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    private enum CheckError: LocalizedError {
        case badResponse
        var errorDescription: String? { "GitHub sent an unexpected answer." }
    }

    private static func latest() async throws -> Release {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("StreamHub-iOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == "api.github.com", data.count < 1_000_000 else {
            throw CheckError.badResponse
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        // only real releases of this app, linking to this app's release pages
        guard release.draft != true, release.prerelease != true,
              release.tag_name.hasPrefix(tagPrefix),
              release.html_url.hasPrefix(releasesPrefix),
              let page = URL(string: release.html_url) else {
            throw CheckError.badResponse
        }
        let version = String(release.tag_name.dropFirst(tagPrefix.count))
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else {
            throw CheckError.badResponse
        }
        let ipa = release.assets?
            .first { $0.name.hasSuffix(".ipa") && $0.browser_download_url.hasPrefix(releasesPrefix + "download/") }
            .flatMap { URL(string: $0.browser_download_url) }
        return Release(version: version, page: page, ipa: ipa)
    }

    /// "1.10.0" is newer than "1.9.2".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The banner at the top of the app when a new version is out.
struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        if let release = checker.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("StreamHub iOS \(release.version) is available")
                        .font(.subheadline.weight(.semibold))
                    Text(copied ? "IPA link copied: paste it into your signing service." : "Install the new IPA with your signing service.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Menu {
                    Button {
                        openURL(release.page)
                    } label: {
                        Label("Open the release page", systemImage: "safari")
                    }
                    if let ipa = release.ipa {
                        Button {
                            UIPasteboard.general.url = ipa
                            copied = true
                        } label: {
                            Label("Copy the IPA link", systemImage: "doc.on.doc")
                        }
                        Button {
                            openURL(ipa)
                        } label: {
                            Label("Download the IPA", systemImage: "arrow.down.circle")
                        }
                    }
                } label: {
                    Text("Get it")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                Button {
                    checker.dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hide until the next version")
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }
}
