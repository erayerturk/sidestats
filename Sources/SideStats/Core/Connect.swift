import CryptoKit
import Foundation

/// Helpers behind the guided / one-click connection flows in Settings: key generation,
/// parsing pasted credentials and discovering accounts right after sign-in.
enum Connect {
    // MARK: App Store Connect

    static let ascKeysURL = URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!
    static let ascVendorURL = URL(string: "https://appstoreconnect.apple.com/itc/payments_and_financial_reports")!

    /// `AuthKey_ABCDE12345.p8` → `ABCDE12345`
    static func ascKeyId(fromFilename name: String) -> String? {
        guard let r = name.range(of: #"AuthKey_([A-Z0-9]{8,12})"#, options: .regularExpression) else { return nil }
        return String(name[r].dropFirst("AuthKey_".count))
    }

    static func firstUUID(in text: String) -> String? {
        text.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, options: .regularExpression)
            .map { String(text[$0]).lowercased() }
    }

    static func vendorNumber(in text: String) -> String? {
        text.range(of: #"\b8\d{7}\b|\b\d{8,9}\b"#, options: .regularExpression).map { String(text[$0]) }
    }

    /// Checks issuer / key id / private key by listing apps. Returns the app names.
    static func testASC(issuer: String, keyId: String, pem: String) async throws -> [String] {
        let now = Int(Date().timeIntervalSince1970)
        let jwt = try JWT.es256(header: ["alg": "ES256", "kid": keyId, "typ": "JWT"],
                                payload: ["iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"],
                                pem: pem)
        let json = try await HTTP.json(HTTP.request("https://api.appstoreconnect.apple.com/v1/apps?fields[apps]=name&limit=200",
                                                    bearer: jwt)) as? [String: Any] ?? [:]
        return json.arr("data").compactMap { $0.dict("attributes")?.str("name") }
    }

    /// Checks the vendor number with a tiny sales report request (404 = valid but no sales that day).
    static func testVendor(issuer: String, keyId: String, pem: String, vendor: String) async throws {
        let now = Int(Date().timeIntervalSince1970)
        let jwt = try JWT.es256(header: ["alg": "ES256", "kid": keyId, "typ": "JWT"],
                                payload: ["iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"],
                                pem: pem)
        let day = DayFormat.daysAgo(3)
        let url = "https://api.appstoreconnect.apple.com/v1/salesReports?filter[frequency]=DAILY&filter[reportType]=SALES"
            + "&filter[reportSubType]=SUMMARY&filter[vendorNumber]=\(vendor)&filter[reportDate]=\(day)"
        _ = try await HTTP.data(HTTP.request(url, bearer: jwt, headers: ["Accept": "application/a-gzip"]), allow404: true)
    }

    // MARK: Apple Search Ads

    static let asaCertificatesURL = URL(string: "https://app.searchads.apple.com/cm/app/settings/apicertificates")!

    /// New P-256 key pair: private key (stored in the Keychain) and the public key to upload.
    static func generateASAKey() -> (privatePEM: String, publicPEM: String) {
        let key = P256.Signing.PrivateKey()
        return (key.pemRepresentation, key.publicKey.pemRepresentation)
    }

    static func publicPEM(fromPrivate pem: String) -> String? {
        (try? JWT.loadKey(pem))?.publicKey.pemRepresentation
    }

    /// Parses the block Search Ads shows after uploading a public key:
    /// `clientId SEARCHADS.… teamId SEARCHADS.… keyId …`
    static func parseASACredentials(_ text: String) -> (clientId: String?, teamId: String?, keyId: String?) {
        func value(_ name: String) -> String? {
            guard let r = text.range(of: name + #"["'\s:=]+([A-Za-z0-9.\-]+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
            let m = String(text[r])
            return m.range(of: #"[A-Za-z0-9.\-]+$"#, options: .regularExpression).map { String(m[$0]) }
        }
        return (value("clientId"), value("teamId"), value("keyId"))
    }

    // MARK: Google

    static let playReportsURL = URL(string: "https://play.google.com/console/developers/download-reports/statistics")!

    /// Accepts `gs://pubsite_prod_rev_123…`, a bare bucket name, or text containing one.
    static func playBucket(in text: String) -> String? {
        text.range(of: #"pubsite_prod_[a-z_]*\d+"#, options: .regularExpression).map { "gs://" + text[$0] }
    }

    static func googleAdsCustomers(config: Config) async throws -> [String] {
        let token = try await GoogleOAuth.shared.accessToken(config: config)
        let json = try await HTTP.json(HTTP.request(
            "https://googleads.googleapis.com/\(GoogleAdsProvider.version)/customers:listAccessibleCustomers", bearer: token)) as? [String: Any] ?? [:]
        return ((json["resourceNames"] as? [String]) ?? []).map { GoogleAdsProvider.digits($0) }
    }

    static func admobAccounts(config: Config) async throws -> [String] {
        let token = try await GoogleOAuth.shared.accessToken(config: config)
        let json = try await HTTP.json(HTTP.request("https://admob.googleapis.com/v1/accounts", bearer: token)) as? [String: Any] ?? [:]
        return json.arr("account").compactMap { $0.str("publisherId") ?? $0.str("name") }
    }

    // MARK: Meta

    static let metaSystemUsersURL = URL(string: "https://business.facebook.com/settings/system-users")!

    struct MetaAccount: Identifiable, Hashable {
        var id: String      // act_…
        var name: String
        var currency: String
        var active: Bool
    }

    static func metaAdAccounts(token: String) async throws -> [MetaAccount] {
        var out: [MetaAccount] = []
        var next: String? = "\(MetaAdsProvider.graph)/me/adaccounts?fields=account_id,name,currency,account_status&limit=200&access_token=\(token)"
        while let url = next, out.count < 1000 {
            let json = try await HTTP.json(HTTP.request(url)) as? [String: Any] ?? [:]
            for a in json.arr("data") {
                guard let id = a.str("id") ?? a.str("account_id").map({ "act_" + $0 }) else { continue }
                out.append(MetaAccount(id: id, name: a.str("name") ?? id, currency: a.str("currency") ?? "",
                                       active: a.num("account_status") == 1))
            }
            next = json.dict("paging")?.str("next")
        }
        return out
    }
}

// MARK: - Campaign lists (for choosing which campaigns to track)

struct AdCampaign: Identifiable, Hashable {
    var id: String          // "<account>:<campaign id>", the key stored in `SourceAccount.campaignFilter`
    var name: String
    var group: String       // ad account / org name
    var active: Bool
    var spend30: Double?    // last 30 days, when the API gives it cheaply
    var currency = ""
}

extension Connect {
    static func googleAdsCampaigns(config c: Config) async throws -> [AdCampaign] {
        let token = try await GoogleOAuth.shared.accessToken(config: c)
        let headers = GoogleAdsProvider.headers(c)
        var out: [AdCampaign] = []
        var firstError: Error?
        for cid in try await GoogleAdsProvider.customers(c, token: token, headers: headers) {
            do {
                let list = try await GoogleAdsProvider.search(cid, """
                    SELECT customer.descriptive_name, customer.currency_code, campaign.id, campaign.name, campaign.status \
                    FROM campaign WHERE campaign.status != 'REMOVED'
                    """, token: token, headers: headers)
                var spend: [String: Double] = [:]
                if let m = try? await GoogleAdsProvider.search(cid, """
                    SELECT campaign.id, metrics.cost_micros FROM campaign WHERE segments.date DURING LAST_30_DAYS
                    """, token: token, headers: headers) {
                    for r in m { if let id = r.dict("campaign")?.str("id") { spend[id, default: 0] += (r.dict("metrics")?.num("costMicros") ?? 0) / 1_000_000 } }
                }
                for r in list {
                    guard let camp = r.dict("campaign"), let id = camp.str("id") else { continue }
                    let cust = r.dict("customer") ?? [:]
                    out.append(AdCampaign(id: "\(cid):\(id)", name: camp.str("name") ?? id,
                                          group: cust.str("descriptiveName").map { "\($0) (\(cid))" } ?? cid,
                                          active: camp.str("status") == "ENABLED", spend30: spend[id] ?? 0,
                                          currency: cust.str("currencyCode") ?? ""))
                }
            } catch {
                firstError = firstError ?? error   // e.g. a manager account: it has no campaigns of its own
            }
        }
        if out.isEmpty, let firstError { throw firstError }
        return out
    }

    static func searchAdsCampaigns(config c: Config) async throws -> [AdCampaign] {
        let token = try await AppleSearchAdsProvider.accessToken(c)
        var orgs = c.asaOrgId.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if orgs.isEmpty {
            let acls = try await HTTP.json(HTTP.request("\(AppleSearchAdsProvider.api)/acls", bearer: token)) as? [String: Any] ?? [:]
            orgs = acls.arr("data").compactMap { $0.str("orgId") }
        }
        var out: [AdCampaign] = []
        for org in orgs {
            let json = try await HTTP.json(HTTP.request("\(AppleSearchAdsProvider.api)/campaigns?limit=1000", bearer: token,
                                                        headers: ["X-AP-Context": "orgId=\(org)"])) as? [String: Any] ?? [:]
            for camp in json.arr("data") {
                guard let id = camp.str("id"), camp.str("deleted") != "1" else { continue }
                out.append(AdCampaign(id: "\(org):\(id)", name: camp.str("name") ?? id, group: "Org \(org)",
                                      active: camp.str("status") == "ENABLED" && camp.str("servingStatus") != "NOT_RUNNING",
                                      spend30: nil))
            }
        }
        return out
    }

    static func metaCampaigns(config c: Config) async throws -> [AdCampaign] {
        let token = c.secret(.metaAccessToken) ?? ""
        var out: [AdCampaign] = []
        let accounts = c.metaAdAccounts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { $0.hasPrefix("act_") ? $0 : "act_\($0)" }
        for act in accounts {
            var spend: [String: Double] = [:]
            var next: String? = "\(MetaAdsProvider.graph)/\(act)/insights?level=campaign&date_preset=last_30d&fields=campaign_id,spend&limit=500&access_token=\(token)"
            while let url = next, let json = try? await HTTP.json(HTTP.request(url)) as? [String: Any] {
                for r in json.arr("data") { if let id = r.str("campaign_id") { spend[id] = r.num("spend") } }
                next = json.dict("paging")?.str("next")
            }
            next = "\(MetaAdsProvider.graph)/\(act)/campaigns?fields=id,name,effective_status&limit=500&access_token=\(token)"
            while let url = next {
                let json = try await HTTP.json(HTTP.request(url)) as? [String: Any] ?? [:]
                for camp in json.arr("data") {
                    guard let id = camp.str("id"), camp.str("effective_status") != "DELETED" else { continue }
                    out.append(AdCampaign(id: "\(act):\(id)", name: camp.str("name") ?? id, group: act,
                                          active: camp.str("effective_status") == "ACTIVE", spend30: spend[id] ?? 0))
                }
                next = json.dict("paging")?.str("next")
            }
        }
        return out
    }
}
