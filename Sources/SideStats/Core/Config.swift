import Foundation

/// Non-secret settings (UserDefaults). Secrets are stored in the Keychain via `Secret`.
struct Config: Codable, Equatable {
    var baseCurrency = "USD"
    var useDemoData = false
    var autoHide = true
    var edgeDelayMs = 150
    var revenueRefreshMinutes = 30

    // App Store Connect
    var ascIssuerId = ""
    var ascKeyId = ""
    var ascVendorNumber = ""

    // Google (shared OAuth client for AdMob + Play)
    var googleClientId = ""          // own OAuth client (advanced); empty = built-in client
    var googleSignedInClientId = ""  // client the stored refresh token belongs to
    var admobEnabled = true
    var playBucket = ""            // gs://pubsite_prod_rev_... or bare id
    var playNetShare = 0.85        // share of Play gross kept after Google's fee
    var googleAdsEnabled = false
    var googleAdsCustomerIds = ""      // comma separated; empty = every accessible account
    var googleAdsLoginCustomerId = ""  // manager (MCC) id when accessing clients through it

    // Apple Search Ads
    var asaClientId = ""
    var asaTeamId = ""
    var asaKeyId = ""
    var asaOrgId = ""              // optional; first org from /acls when empty

    // Meta Ads
    var metaAdAccounts = ""        // comma separated, with or without act_ prefix

    /// Connected accounts (several per source). The single-account fields above are filled from an
    /// account by `SourceAccount.scoped` when a provider runs.
    var accounts: [SourceAccount] = []
    var accountsMigrated = false
    /// Set on scoped copies only: which account's Keychain items to use.
    var accountId = ""
    /// Set on scoped copies only: the account's campaign selection (nil = all campaigns).
    var campaignFilter: [String]? = nil

    /// Whether a campaign ("<account>:<campaign id>") of the scoped account is tracked.
    func tracksCampaign(_ account: String, _ campaign: String?) -> Bool {
        guard let f = campaignFilter else { return true }
        return f.contains("\(account):\(campaign ?? "")")
    }

    /// Custom revenue sources (any API / command / pushed JSON), see CustomRevenue.swift
    var revenueSources: [WidgetConfig] = []

    /// AppKey.id -> custom group name (merges apps across platforms or renames them)
    var aliases: [String: String] = [:]

    static func load() -> Config {
        // Merge stored keys over defaults so newly added settings don't invalidate old configs.
        guard let d = UserDefaults.standard.data(forKey: "config"),
              let stored = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(stored) { _, new in new }),
              var c = try? JSONDecoder().decode(Config.self, from: merged) else { return Config(accountsMigrated: true) }
        if !c.accountsMigrated { c.migrateToAccounts(); c.save() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "config") }
    }
}

enum Secret: String {
    case ascPrivateKey, googleClientSecret, googleRefreshToken, googleAdsDeveloperToken, asaPrivateKey, metaAccessToken

    var value: String? { Keychain.get(rawValue) }
    func set(_ v: String?) { Keychain.set(rawValue, v) }
    var isSet: Bool { !(value ?? "").isEmpty }
}

protocol Provider {
    var kind: SourceKind { get }
    /// Sources with several accounts run once per account (with a scoped Config) and are merged.
    var accountKind: AccountKind? { get }
    func isConfigured(_ c: Config) -> Bool
    /// Fetch daily metrics for the inclusive yyyy-MM-dd range.
    func fetch(config: Config, start: String, end: String) async throws -> ProviderResult
}

extension Provider {
    var accountKind: AccountKind? { nil }
}

enum StoreURL {
    /// Maps an App Store / Play Store URL to an AppKey.
    static func appKey(from url: String) -> AppKey? {
        if url.contains("apps.apple.com") || url.contains("itunes.apple.com"),
           let r = url.range(of: #"id(\d+)"#, options: .regularExpression) {
            return AppKey(platform: .ios, storeId: String(url[r].dropFirst(2)))
        }
        if url.contains("play.google.com"), let comps = URLComponents(string: url),
           let id = comps.queryItems?.first(where: { $0.name == "id" })?.value {
            return AppKey(platform: .android, storeId: id)
        }
        return nil
    }
}
