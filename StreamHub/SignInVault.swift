import Foundation
import Security
import WebKit

/// Keeps your Twitch, Kick and Crunchyroll sign-ins when StreamHub is reinstalled.
///
/// Sign-ins are the sites' cookies in the app's web data, which a reinstall through a signing
/// service can wipe. StreamHub copies those cookies into the iOS Keychain (this device only),
/// which survives a reinstall of the same app, and puts them back when the web data is empty.
/// Nothing leaves the device, and StreamHub never sees your passwords: only the sites' own
/// sign-in cookies are kept.
enum SignInVault {
    private static let service = "com.streamhub.ios.signins"
    private static let account = "cookies"
    private static let domains = ["twitch.tv", "kick.com", "crunchyroll.com"]

    private struct StoredCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expires: Date?
        let secure: Bool
        let httpOnly: Bool
        let sameSite: String?
    }

    private static func kept(_ domain: String) -> Bool {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Copy the current sign-in cookies into the Keychain (when the app goes to the background).
    @MainActor
    static func save() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        let now = Date()
        let stored = cookies
            .filter { kept($0.domain) && ($0.expiresDate.map { $0 > now } ?? true) }
            .map {
                StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                             expires: $0.expiresDate, secure: $0.isSecure, httpOnly: $0.isHTTPOnly,
                             sameSite: $0.sameSitePolicy?.rawValue)
            }
        // never replace saved sign-ins with nothing (a fresh install before restore, or signed out
        // everywhere at once is rare: Sign out in Settings clears them on purpose)
        guard !stored.isEmpty, let data = try? JSONEncoder().encode(stored) else { return }
        write(data)
    }

    /// Put saved sign-ins back if the web data has none (after a reinstall). Call before any
    /// Twitch, Kick or Crunchyroll page loads.
    @MainActor
    static func restore() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let current = await store.allCookies()
        guard !current.contains(where: { kept($0.domain) }),
              let data = read(),
              let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return }
        let now = Date()
        for item in stored where kept(item.domain) && (item.expires.map { $0 > now } ?? true) {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: item.name, .value: item.value, .domain: item.domain, .path: item.path,
            ]
            if let expires = item.expires { properties[.expires] = expires }
            if item.secure { properties[.secure] = "TRUE" }
            if item.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite = item.sameSite { properties[.sameSitePolicy] = sameSite }
            if let cookie = HTTPCookie(properties: properties) {
                await store.setCookie(cookie)
            }
        }
    }

    /// Forget the saved sign-ins (Settings → Sign out of everything).
    static func clear() {
        SecItemDelete(query() as CFDictionary)
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func write(_ data: Data) {
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query() as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func read() -> Data? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
