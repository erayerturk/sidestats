import Foundation

/// Apple Search Ads Campaign Management API v5 — daily campaign spend, attributed via adamId.
/// Docs: https://developer.apple.com/documentation/apple_search_ads/implementing_oauth_for_the_apple_search_ads_api
struct AppleSearchAdsProvider: Provider {
    let kind = SourceKind.appleSearchAds
    let accountKind: AccountKind? = .searchAds
    static let api = "https://api.searchads.apple.com/api/v5"

    func isConfigured(_ c: Config) -> Bool {
        !c.asaClientId.isEmpty && !c.asaTeamId.isEmpty && !c.asaKeyId.isEmpty && c.hasSecret(.asaPrivateKey)
    }

    static func accessToken(_ c: Config) async throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let secret = try JWT.es256(
            header: ["alg": "ES256", "kid": c.asaKeyId],
            payload: ["sub": c.asaClientId, "iss": c.asaTeamId, "aud": "https://appleid.apple.com",
                      "iat": now, "exp": now + 3600],
            pem: c.secret(.asaPrivateKey) ?? "")
        let json = try await HTTP.json(HTTP.request("https://appleid.apple.com/auth/oauth2/token", method: "POST", form: [
            "grant_type": "client_credentials", "client_id": c.asaClientId,
            "client_secret": secret, "scope": "searchadsorg",
        ])) as? [String: Any] ?? [:]
        guard let t = json.str("access_token") else { throw SideStatsError("Apple Search Ads auth failed") }
        return t
    }

    func fetch(config c: Config, start: String, end: String) async throws -> ProviderResult {
        let token = try await Self.accessToken(c)

        var orgIds = c.asaOrgId.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if orgIds.isEmpty {
            let acls = try await HTTP.json(HTTP.request("\(Self.api)/acls", bearer: token)) as? [String: Any] ?? [:]
            orgIds = acls.arr("data").compactMap { $0.str("orgId") }
        }

        var rows: [MetricRow] = []
        for org in orgIds where ResourceClaims.claim("asa:\(org)") {
            var offset = 0
            while true {
                let body: [String: Any] = [
                    "startTime": start, "endTime": end, "granularity": "DAILY", "timeZone": "UTC",
                    "returnRecordsWithNoMetrics": false, "returnRowTotals": false,
                    "selector": [
                        "orderBy": [["field": "campaignId", "sortOrder": "ASCENDING"]],
                        "pagination": ["offset": offset, "limit": 1000],
                    ],
                ]
                let req = HTTP.request("\(Self.api)/reports/campaigns", method: "POST", bearer: token, json: body,
                                       headers: ["X-AP-Context": "orgId=\(org)"])
                let json = try await HTTP.json(req) as? [String: Any] ?? [:]
                let report = json.dict("data")?.dict("reportingDataResponse") ?? [:]
                let campaigns = report.arr("row")
                for row in campaigns {
                    let meta = row.dict("metadata") ?? [:]
                    guard c.tracksCampaign(org, meta.str("campaignId")) else { continue }
                    let key = meta.str("adamId").map { AppKey(platform: .ios, storeId: $0) } ?? .unassigned
                    for g in row.arr("granularity") {
                        guard let date = g.str("date") else { continue }
                        let spend = g.dict("localSpend") ?? [:]
                        let installs = g["totalInstalls"] != nil ? g.num("totalInstalls") : g.num("installs")
                        rows.append(MetricRow(date: String(date.prefix(10)), app: key, source: kind,
                                              currency: spend.str("currency") ?? "USD",
                                              spend: spend.num("amount"),
                                              adImpressions: Int(g.num("impressions")), clicks: Int(g.num("taps")),
                                              installs: installs))
                    }
                }
                let total = Int(json.dict("pagination")?.num("totalResults") ?? 0)
                offset += 1000
                if campaigns.isEmpty || offset >= total { break }
            }
        }
        return ProviderResult(rows: rows)
    }
}
