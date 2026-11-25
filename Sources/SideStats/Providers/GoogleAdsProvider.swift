import Foundation

/// Google Ads — daily spend per app (App campaigns map to their App Store / Play app; other
/// campaigns count as unattributed spend). Uses the shared Google sign-in (scope `adwords`).
/// Docs: https://developers.google.com/google-ads/api/docs/start
struct GoogleAdsProvider: Provider {
    let kind = SourceKind.googleAds
    let accountKind: AccountKind? = .google
    /// Google Ads API major versions live ~12 months; bump when Google sunsets this one.
    static let version = "v26"
    private var api: String { "https://googleads.googleapis.com/\(Self.version)" }

    func isConfigured(_ c: Config) -> Bool {
        c.googleAdsEnabled && GoogleClient.isConnected(c)
    }

    static func digits(_ s: String) -> String { s.filter(\.isNumber) }

    func fetch(config c: Config, start: String, end: String) async throws -> ProviderResult {
        let token = try await GoogleOAuth.shared.accessToken(config: c)
        var headers: [String: String] = [:]
        if let dev = c.secret(.googleAdsDeveloperToken), !dev.isEmpty { headers["developer-token"] = dev }
        let login = Self.digits(c.googleAdsLoginCustomerId)
        if !login.isEmpty { headers["login-customer-id"] = login }

        var customers = c.googleAdsCustomerIds.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { Self.digits(String($0)) }.filter { !$0.isEmpty }
        if customers.isEmpty {
            let json = try await call(HTTP.request("\(api)/customers:listAccessibleCustomers", bearer: token, headers: headers))
            customers = ((json["resourceNames"] as? [String]) ?? []).map { Self.digits($0) }
            if customers.isEmpty { throw SideStatsError("Google Ads: no accessible accounts. Enter customer IDs in Settings → Google.") }
        }

        let query = """
        SELECT segments.date, campaign.id, campaign.name, campaign.app_campaign_setting.app_id, \
        campaign.app_campaign_setting.app_store, customer.currency_code, customer.descriptive_name, metrics.cost_micros \
        FROM campaign WHERE segments.date BETWEEN '\(start)' AND '\(end)' AND metrics.cost_micros > 0
        """
        var result = ProviderResult()
        var errors: [String] = []
        var okAccounts = 0
        for cid in customers where ResourceClaims.claim("gads:\(cid)") {
            do {
                var pageToken: String?
                repeat {
                    var body: [String: Any] = ["query": query]
                    if let pageToken { body["pageToken"] = pageToken }
                    let json = try await call(HTTP.request("\(api)/customers/\(cid)/googleAds:search",
                                                           method: "POST", bearer: token, json: body, headers: headers))
                    for r in (json["results"] as? [[String: Any]]) ?? [] {
                        guard let date = r.dict("segments")?.str("date") else { continue }
                        let campaign = r.dict("campaign") ?? [:]
                        let app = campaign.dict("appCampaignSetting") ?? [:]
                        let cost = Double(r.dict("metrics")?.str("costMicros") ?? "") ?? r.dict("metrics")?.num("costMicros") ?? 0
                        let key: AppKey
                        switch (app.str("appStore"), app.str("appId")) {
                        case ("APPLE_APP_STORE", let id?) where !Self.digits(id).isEmpty: key = AppKey(platform: .ios, storeId: Self.digits(id))
                        case ("GOOGLE_APP_STORE", let id?) where !id.isEmpty: key = AppKey(platform: .android, storeId: id)
                        default: key = .unassigned
                        }
                        if key != .unassigned, let name = campaign.str("name") {
                            result.names.append(.init(app: key, name: name, priority: 0))   // store names win
                        }
                        result.rows.append(MetricRow(date: date, app: key, source: kind,
                                                     currency: r.dict("customer")?.str("currencyCode") ?? "USD",
                                                     spend: cost / 1_000_000))
                    }
                    pageToken = json.str("nextPageToken")
                } while pageToken != nil && pageToken != ""
                okAccounts += 1
            } catch {
                errors.append("\(cid): \(error.localizedDescription)")
            }
        }
        if okAccounts == 0, !errors.isEmpty { throw SideStatsError("Google Ads — " + errors.joined(separator: "\n")) }
        if !errors.isEmpty { result.warnings = errors }
        return result
    }

    private func call(_ req: URLRequest) async throws -> [String: Any] {
        do {
            return try await HTTP.json(req) as? [String: Any] ?? [:]
        } catch let e as SideStatsError {
            if e.message.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") || e.message.contains("insufficient authentication scopes") {
                throw SideStatsError("Google Ads needs one more permission: Settings → Google → Sign out, then Sign in again.")
            }
            if e.message.contains("HTTP 404") {
                throw SideStatsError("Google Ads API \(Self.version) not found (sunset?). Update SideStats. \(e.message.prefix(200))")
            }
            if e.message.contains("CLOUD_PROJECT_NOT_APPROVED_FOR_PRODUCTION") {
                throw SideStatsError(GoogleClient.builtin != nil
                    ? "Google Ads access is pending Google's approval for SideStats (Explorer access). AdMob and Play work meanwhile."
                    : "Your Cloud project only has Test access to the Google Ads API. Apply for Explorer access in Cloud Console → Google Ads API.")
            }
            if e.message.contains("REQUESTED_METRICS_FOR_MANAGER") {
                throw SideStatsError("This is a manager (MCC) account. Enter the client account IDs and put the manager ID in “Manager account ID”.")
            }
            throw e
        }
    }
}
