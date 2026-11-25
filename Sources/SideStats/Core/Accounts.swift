import Foundation

/// Sources that can have several accounts (several Google logins, App Store teams, Search Ads orgs, Meta tokens).
enum AccountKind: String, Codable, CaseIterable {
    case google, appStore, searchAds, meta

    var title: String {
        switch self {
        case .google: return "Google account"
        case .appStore: return "App Store team"
        case .searchAds: return "Search Ads account"
        case .meta: return "Meta token"
        }
    }
}

/// One connected account. Only the fields of its `kind` are used; secrets live in the Keychain
/// under "<secret>.<id>" (see `Secret.scoped`).
struct SourceAccount: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var kind: AccountKind = .google
    var label = ""                     // e-mail, team or account name shown in Settings
    var enabled = true

    // Google
    var googleClientId = ""            // OAuth client the refresh token belongs to
    var admobEnabled = true
    var googleAdsEnabled = false
    var googleAdsCustomerIds = ""
    var googleAdsLoginCustomerId = ""
    var playBucket = ""
    var playNetShare = 0.85

    // App Store Connect
    var ascIssuerId = ""
    var ascKeyId = ""
    var ascVendorNumber = ""

    // Apple Search Ads
    var asaClientId = ""
    var asaTeamId = ""
    var asaKeyId = ""
    var asaOrgId = ""

    // Meta
    var metaAdAccounts = ""

    init(kind: AccountKind) { self.kind = kind }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        let x = SourceAccount(kind: .google)
        id = v(.id, x.id); kind = v(.kind, x.kind); label = v(.label, ""); enabled = v(.enabled, true)
        googleClientId = v(.googleClientId, ""); admobEnabled = v(.admobEnabled, true)
        googleAdsEnabled = v(.googleAdsEnabled, false); googleAdsCustomerIds = v(.googleAdsCustomerIds, "")
        googleAdsLoginCustomerId = v(.googleAdsLoginCustomerId, ""); playBucket = v(.playBucket, "")
        playNetShare = v(.playNetShare, 0.85)
        ascIssuerId = v(.ascIssuerId, ""); ascKeyId = v(.ascKeyId, ""); ascVendorNumber = v(.ascVendorNumber, "")
        asaClientId = v(.asaClientId, ""); asaTeamId = v(.asaTeamId, ""); asaKeyId = v(.asaKeyId, ""); asaOrgId = v(.asaOrgId, "")
        metaAdAccounts = v(.metaAdAccounts, "")
    }

    var displayName: String {
        if !label.isEmpty { return label }
        switch kind {
        case .google: return "Google account"
        case .appStore: return ascVendorNumber.isEmpty ? "App Store team" : "Vendor \(ascVendorNumber)"
        case .searchAds: return asaOrgId.isEmpty ? "Search Ads" : "Org \(asaOrgId)"
        case .meta: return "Meta"
        }
    }

    func secret(_ s: Secret) -> SecretKey { s.scoped(id) }

    /// Removes this account's Keychain items.
    func deleteSecrets() {
        for s in [Secret.ascPrivateKey, .googleClientSecret, .googleRefreshToken, .googleAdsDeveloperToken, .asaPrivateKey, .metaAccessToken] {
            s.scoped(id).set(nil)
        }
    }

    /// A Config whose single-account fields carry this account, so providers can stay single-account.
    func scoped(_ base: Config) -> Config {
        var c = base
        c.accountId = id
        switch kind {
        case .google:
            c.googleSignedInClientId = googleClientId; c.googleClientId = googleClientId
            c.admobEnabled = admobEnabled; c.googleAdsEnabled = googleAdsEnabled
            c.googleAdsCustomerIds = googleAdsCustomerIds; c.googleAdsLoginCustomerId = googleAdsLoginCustomerId
            c.playBucket = playBucket; c.playNetShare = playNetShare
        case .appStore:
            c.ascIssuerId = ascIssuerId; c.ascKeyId = ascKeyId; c.ascVendorNumber = ascVendorNumber
        case .searchAds:
            c.asaClientId = asaClientId; c.asaTeamId = asaTeamId; c.asaKeyId = asaKeyId; c.asaOrgId = asaOrgId
        case .meta:
            c.metaAdAccounts = metaAdAccounts
        }
        return c
    }
}

/// A Keychain item name, optionally scoped to an account.
struct SecretKey {
    let name: String
    var value: String? { Keychain.get(name) }
    func set(_ v: String?) { Keychain.set(name, v) }
    var isSet: Bool { !(value ?? "").isEmpty }
}

extension Secret {
    func scoped(_ accountId: String) -> SecretKey { SecretKey(name: accountId.isEmpty ? rawValue : "\(rawValue).\(accountId)") }
}

extension Config {
    func accounts(_ kind: AccountKind) -> [SourceAccount] { accounts.filter { $0.kind == kind } }

    /// Secret for the account this config is scoped to (or the legacy single-account item).
    func secret(_ s: Secret) -> String? { s.scoped(accountId).value }
    func hasSecret(_ s: Secret) -> Bool { s.scoped(accountId).isSet }

    /// One-time move of the old single-account settings into `accounts`.
    mutating func migrateToAccounts() {
        guard !accountsMigrated else { return }
        accountsMigrated = true
        func move(_ secrets: [Secret], to a: SourceAccount) {
            for s in secrets { if let v = s.value, !v.isEmpty { s.scoped(a.id).set(v) } }
        }
        if Secret.googleRefreshToken.isSet {
            var a = SourceAccount(kind: .google)
            a.googleClientId = googleSignedInClientId.isEmpty ? googleClientId : googleSignedInClientId
            a.admobEnabled = admobEnabled; a.googleAdsEnabled = googleAdsEnabled
            a.googleAdsCustomerIds = googleAdsCustomerIds; a.googleAdsLoginCustomerId = googleAdsLoginCustomerId
            a.playBucket = playBucket; a.playNetShare = playNetShare
            move([.googleRefreshToken, .googleClientSecret, .googleAdsDeveloperToken], to: a)
            accounts.append(a)
        }
        if !ascIssuerId.isEmpty || !ascKeyId.isEmpty || Secret.ascPrivateKey.isSet {
            var a = SourceAccount(kind: .appStore)
            a.ascIssuerId = ascIssuerId; a.ascKeyId = ascKeyId; a.ascVendorNumber = ascVendorNumber
            move([.ascPrivateKey], to: a)
            accounts.append(a)
        }
        if !asaClientId.isEmpty || Secret.asaPrivateKey.isSet {
            var a = SourceAccount(kind: .searchAds)
            a.asaClientId = asaClientId; a.asaTeamId = asaTeamId; a.asaKeyId = asaKeyId; a.asaOrgId = asaOrgId
            move([.asaPrivateKey], to: a)
            accounts.append(a)
        }
        if Secret.metaAccessToken.isSet {
            var a = SourceAccount(kind: .meta)
            a.metaAdAccounts = metaAdAccounts
            move([.metaAccessToken], to: a)
            accounts.append(a)
        }
    }
}

/// Prevents double counting when two accounts can see the same resource (e.g. two Google logins with
/// access to one AdMob publisher). Each refresh of a provider gets a fresh set via a task-local;
/// the first account to claim a resource fetches it, the others skip it.
final class ResourceClaims: @unchecked Sendable {
    @TaskLocal static var current: ResourceClaims?
    private var claimed = Set<String>()
    private let lock = NSLock()

    /// True if the caller should fetch `id` (always true outside a multi-account refresh).
    static func claim(_ id: String) -> Bool {
        guard let c = current else { return true }
        c.lock.lock(); defer { c.lock.unlock() }
        return c.claimed.insert(id).inserted
    }
}
