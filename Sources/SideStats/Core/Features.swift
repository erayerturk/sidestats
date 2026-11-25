import Foundation

/// Feature switches. Paid features will check the license here later (e.g. `License.shared.isPro`).
enum Features {
    /// One-click connections: SideStats' own Google OAuth client, generated Search Ads keys,
    /// auto-discovery of accounts. Free for now; planned for Pro.
    static var oneClickConnect: Bool { true }
}

/// A Google OAuth "Desktop app" client. Google treats installed-app client secrets as non-confidential,
/// so the built-in one ships in Info.plist (injected at build time, not in git).
struct GoogleClient: Equatable {
    var id: String
    var secret: String

    static let builtin: GoogleClient? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let id = info["SSGoogleClientID"] as? String, !id.isEmpty,
              let secret = info["SSGoogleClientSecret"] as? String, !secret.isEmpty else { return nil }
        return GoogleClient(id: id, secret: secret)
    }()

    /// Built-in client available to this user (shipped in this build and feature enabled).
    static var oneClick: GoogleClient? { Features.oneClickConnect ? builtin : nil }

    /// The client the current Google sign-in belongs to.
    static func current(_ c: Config) -> GoogleClient? {
        let id = c.googleSignedInClientId.isEmpty ? c.googleClientId : c.googleSignedInClientId
        guard !id.isEmpty else { return nil }
        if let b = builtin, b.id == id { return b }
        guard let secret = Secret.googleClientSecret.value, !secret.isEmpty else { return nil }
        return GoogleClient(id: id, secret: secret)
    }

    static func isConnected(_ c: Config) -> Bool { current(c) != nil && Secret.googleRefreshToken.isSet }
}
