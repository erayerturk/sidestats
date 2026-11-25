import Foundation

/// Meta (Facebook/Instagram) Marketing API — daily campaign spend. Campaigns are attributed to an
/// app through the ad set's promoted_object (app install / app event campaigns).
/// Docs: https://developers.facebook.com/docs/marketing-api/insights
struct MetaAdsProvider: Provider {
    let kind = SourceKind.metaAds
    let accountKind: AccountKind? = .meta
    static let graph = "https://graph.facebook.com/v23.0"

    func isConfigured(_ c: Config) -> Bool { !c.metaAdAccounts.isEmpty && c.hasSecret(.metaAccessToken) }

    func fetch(config c: Config, start: String, end: String) async throws -> ProviderResult {
        let token = c.secret(.metaAccessToken) ?? ""
        let accounts = c.metaAdAccounts.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("act_") ? $0 : "act_\($0)" }

        var rows: [MetricRow] = []
        var infos: [CampaignInfo] = []
        for act in accounts where ResourceClaims.claim("meta:\(act)") {
            // campaign id -> app, from ad sets' promoted_object
            var campaignApp: [String: AppKey] = [:]
            for adset in try await paged("\(Self.graph)/\(act)/adsets?fields=campaign_id,promoted_object&limit=500", token) {
                guard let cid = adset.str("campaign_id"), let po = adset.dict("promoted_object"),
                      let url = po.str("object_store_url"), let key = StoreURL.appKey(from: url) else { continue }
                campaignApp[cid] = key
            }

            for camp in (try? await paged("\(Self.graph)/\(act)/campaigns?fields=id,name,effective_status&limit=500", token)) ?? [] {
                guard let id = camp.str("id"), c.tracksCampaign(act, id), camp.str("effective_status") != "DELETED" else { continue }
                let st: CampaignState
                switch camp.str("effective_status") ?? "" {
                case "ACTIVE": st = .active
                case "PAUSED", "CAMPAIGN_PAUSED", "ADSET_PAUSED": st = .paused
                case "ARCHIVED", "COMPLETED": st = .ended
                case "PENDING_REVIEW", "IN_PROCESS", "PREAPPROVED": st = .scheduled
                default: st = .unknown
                }
                infos.append(CampaignInfo(id: "\(act):\(id)", name: camp.str("name") ?? id, source: kind,
                                          app: c.assignedApp(act, id) ?? campaignApp[id] ?? .unassigned, state: st))
            }

            let range = "{\"since\":\"\(start)\",\"until\":\"\(end)\"}"
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let url = "\(Self.graph)/\(act)/insights?level=campaign&time_increment=1&limit=500"
                + "&fields=campaign_id,spend,impressions,clicks,actions,account_currency,date_start&time_range=\(range)"
            for r in try await paged(url, token) {
                guard let day = r.str("date_start"), c.tracksCampaign(act, r.str("campaign_id")) else { continue }
                let key = c.assignedApp(act, r.str("campaign_id")) ?? r.str("campaign_id").flatMap { campaignApp[$0] } ?? .unassigned
                let installs = r.arr("actions").filter { ["mobile_app_install", "app_install", "omni_app_install"].contains($0.str("action_type") ?? "") }
                    .map { $0.num("value") }.max() ?? 0
                rows.append(MetricRow(date: day, app: key, source: kind,
                                      currency: r.str("account_currency") ?? "USD",
                                      spend: r.num("spend"),
                                      adImpressions: Int(r.num("impressions")), clicks: Int(r.num("clicks")),
                                      installs: installs, campaign: "\(act):\(r.str("campaign_id") ?? "")"))
            }
        }
        return ProviderResult(rows: rows, names: CampaignAssign.names(rows), campaigns: infos)
    }

    private func paged(_ first: String, _ token: String) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var next: String? = first + "&access_token=\(token)"
        while let url = next {
            let json = try await HTTP.json(HTTP.request(url)) as? [String: Any] ?? [:]
            out += json.arr("data")
            next = json.dict("paging")?.str("next")
        }
        return out
    }
}

/// Deterministic sample data so anyone can try SideStats without connecting accounts.
struct DemoProvider: Provider {
    let kind = SourceKind.demo
    func isConfigured(_ c: Config) -> Bool { c.useDemoData }

    func fetch(config c: Config, start: String, end: String) async throws -> ProviderResult {
        let apps: [(AppKey, String, Double, Double, Double)] = [   // key, name, ad, iap, spend (daily base)
            (AppKey(platform: .ios, storeId: "demo-1"), "Pixel Puzzle", 42, 65, 30),
            (AppKey(platform: .android, storeId: "com.demo.pixelpuzzle"), "Pixel Puzzle", 58, 21, 25),
            (AppKey(platform: .ios, storeId: "demo-2"), "Habit Garden", 6, 120, 55),
            (AppKey(platform: .ios, storeId: "demo-3"), "Tiny Weather", 18, 4, 0),
            (AppKey(platform: .android, storeId: "com.demo.flashcards"), "Flashcards Pro", 33, 9, 40),
        ]
        var result = ProviderResult()
        for (i, day) in DayFormat.days(from: start, to: end).enumerated() {
            for (j, app) in apps.enumerated() {
                let wave = 1 + 0.25 * sin(Double(i + j * 3) / 3.0) + 0.1 * cos(Double(i * (j + 2)))
                result.rows.append(MetricRow(
                    date: day, app: app.0, source: kind, currency: "USD",
                    adRevenue: app.2 * wave, iapRevenue: app.3 * (2 - wave),
                    spend: app.4 * (0.8 + 0.3 * wave), downloads: Int(80 * wave) + j * 20,
                    impressions: Int(app.2 * 900 * wave)))
            }
        }
        result.names = apps.map { AppNameHint(app: $0.0, name: $0.1, priority: 100) }
        return result
    }
}
