import Foundation

// MARK: - Custom revenue sources
//
// Any API, shell command or pushed JSON can feed the Apps & Revenue module. A source is a
// `WidgetConfig` (same fetching, headers/secrets, placeholders and JavaScript transform as widgets)
// whose output is read as daily revenue rows instead of being rendered as widget items.

enum RevenueFormat {
    /// Shown in Settings and returned by the API / MCP.
    static let example = """
    {
      "currency": "USD",
      "rows": [
        { "date": "2026-11-24", "app": "Puzzle Pop", "platform": "ios",
          "adRevenue": 42.10, "iapRevenue": 12.99, "spend": 18.50,
          "downloads": 130, "impressions": 15200 },
        { "date": "2026-11-24", "app": "Puzzle Pop", "platform": "android",
          "adRevenue": 31.75, "downloads": 210 },
        { "date": "2026-11-23", "app": "Habit Owl", "storeId": "1234567890",
          "platform": "ios", "iapRevenue": 54.00 }
      ]
    }
    """

    static let fieldHelp = """
    date — yyyy-MM-dd (or ISO / epoch). Also: day, ds, timestamp
    app — app name; rows with the same name are merged. Also: appName, application, game, name
    platform — ios | android | mac (optional). Also: os
    storeId — App Store id or Android package (optional, merges with store data). Also: store_id, package_name, bundleId
    adRevenue — also: revenue, ad_revenue, estimated_revenue, earnings
    iapRevenue — also: iap, proceeds, sales
    spend — also: cost, ad_spend, amount_spent
    downloads — also: installs, units
    impressions — also: imps
    currency — per row or top level (default USD)
    """

    static let dateKeys = ["date", "day", "ds", "timestamp", "time", "period"]
    static let appKeys = ["app", "appName", "app_name", "application", "game", "gameName", "game_name", "name", "title", "appKey"]
    static let platformKeys = ["platform", "os"]
    static let storeKeys = ["storeId", "store_id", "appStoreId", "app_store_id", "package", "package_name", "packageName", "bundleId", "bundle_id"]
    static let adKeys = ["adRevenue", "ad_revenue", "revenue", "estimated_revenue", "revenue_sum", "earnings", "income"]
    static let iapKeys = ["iapRevenue", "iap_revenue", "iap", "proceeds", "sales"]
    static let spendKeys = ["spend", "cost", "adSpend", "ad_spend", "amount_spent"]
    static let downloadKeys = ["downloads", "installs", "units"]
    static let impressionKeys = ["impressions", "imps"]

    /// Reads revenue rows from `{rows|data|results|items|records: [...]}` or a bare array.
    static func parse(_ payload: Any, sourceName: String) throws -> ProviderResult {
        var topCurrency = "USD"
        var list: [Any]?
        if let a = payload as? [Any] { list = a }
        else if let d = payload as? [String: Any] {
            if let c = d["currency"] as? String, !c.isEmpty { topCurrency = c.uppercased() }
            for k in ["rows", "data", "results", "items", "records", "report"] {
                if let a = d[k] as? [Any] { list = a; break }
            }
            if list == nil, first(d, dateKeys) != nil { list = [d] }   // a single row
        }
        guard let list else {
            throw SideStatsError("Expected {\"rows\": [...]} or an array of rows. Use JSON path or a transform to point at the rows.")
        }
        var out = ProviderResult()
        var names: [AppKey: String] = [:]
        var skipped = 0
        for case let r as [String: Any] in list {
            guard let date = day(first(r, dateKeys)) else { skipped += 1; continue }
            let name = first(r, appKeys).map(WidgetParser.scalarText) ?? sourceName
            let platform = self.platform(first(r, platformKeys) as? String)
            let store = first(r, storeKeys).map(WidgetParser.scalarText) ?? ""
            let key: AppKey
            if !store.isEmpty, platform == .ios || platform == .mac, store.allSatisfy(\.isNumber) {
                key = AppKey(platform: platform, storeId: store)
            } else if !store.isEmpty, platform == .android {
                key = AppKey(platform: .android, storeId: store)
            } else {
                let gid = MetricsStore.groupId(name)
                key = AppKey(platform: platform, storeId: "custom:" + (gid.isEmpty ? name : gid))
            }
            names[key] = name
            let cur = ((r["currency"] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() }) ?? topCurrency
            out.rows.append(MetricRow(
                date: date, app: key, source: .custom, currency: cur,
                adRevenue: num(r, adKeys), iapRevenue: num(r, iapKeys), spend: num(r, spendKeys),
                downloads: Int(num(r, downloadKeys)), impressions: Int(num(r, impressionKeys))))
        }
        if out.rows.isEmpty {
            throw SideStatsError(list.isEmpty ? "The source returned no rows." :
                "None of the \(list.count) rows had a date (\(skipped) skipped). Each row needs \"date\": \"yyyy-MM-dd\".")
        }
        out.names = names.map { AppNameHint(app: $0.key, name: $0.value, priority: 1) }
        return out
    }

    private static func first(_ d: [String: Any], _ keys: [String]) -> Any? {
        for k in keys { if let v = d[k], !(v is NSNull) { return v } }
        let lower = Dictionary(d.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        for k in keys { if let v = lower[k.lowercased()], !(v is NSNull) { return v } }
        return nil
    }

    private static func num(_ d: [String: Any], _ keys: [String]) -> Double {
        WidgetParser.number(first(d, keys)) ?? 0
    }

    static func day(_ v: Any?) -> String? {
        if let s = v as? String {
            let p = String(s.prefix(10))
            if DayFormat.date(p) != nil { return p }
        }
        return WidgetParser.parseDate(v).map(DayFormat.string)
    }

    static func platform(_ s: String?) -> Platform {
        switch (s ?? "").lowercased() {
        case "ios", "iphone", "ipad", "apple", "app store", "appstore", "itunes": return .ios
        case "android", "google", "google play", "googleplay", "play", "fireos", "amazon": return .android
        case "mac", "macos", "osx": return .mac
        default: return .other
        }
    }
}

enum CustomRevenue {
    /// Fetches one source and returns its rows. Runs the transform and JSON path like widgets do.
    static func load(_ s: WidgetConfig, headers: String? = nil) async throws -> (result: ProviderResult, raw: Data) {
        let (payload, raw) = try await WidgetFetcher.fetch(s, headers: headers)
        if payload is String, s.transform.isEmpty {
            throw SideStatsError("The source didn't return JSON: \(String(decoding: raw.prefix(200), as: UTF8.self))")
        }
        var value = try WidgetTransform.apply(s.transform, to: payload)
        if !s.jsonPath.trimmingCharacters(in: .whitespaces).isEmpty {
            value = WidgetParser.select(value, path: s.jsonPath)
        }
        return (try RevenueFormat.parse(value, sourceName: s.name), raw)
    }

    static func pushPath(_ id: String) -> URL { Storage.dir.appendingPathComponent("widget-\(id).raw") }

    static func makeSource(name: String, source: WidgetSourceType) -> WidgetConfig {
        var w = WidgetConfig()
        w.name = name
        w.source = source
        w.icon = "dollarsign.circle"
        w.refreshSeconds = 1800
        return w
    }
}

struct CustomRevenueProvider: Provider {
    let kind = SourceKind.custom
    func isConfigured(_ c: Config) -> Bool { c.revenueSources.contains { $0.enabled } }

    func fetch(config: Config, start: String, end: String) async throws -> ProviderResult {
        let sources = config.revenueSources.filter(\.enabled)
        // Fetch all sources in parallel.
        let tasks = sources.map { s in
            Task { () -> (String, Result<ProviderResult, Error>) in
                do { return (s.name, .success(try await CustomRevenue.load(s).result)) }
                catch { return (s.name, .failure(error)) }
            }
        }
        var results: [(String, Result<ProviderResult, Error>)] = []
        for t in tasks { results.append(await t.value) }
        var out = ProviderResult()
        var errors: [String] = []
        for (name, r) in results {
            switch r {
            case .success(let p): out.rows += p.rows; out.names += p.names
            case .failure(let e): errors.append("\(name): \(e.localizedDescription)")
            }
        }
        out.rows = out.rows.filter { $0.date >= start && $0.date <= end }
        if !errors.isEmpty {
            if out.rows.isEmpty { throw SideStatsError(errors.joined(separator: "\n")) }
            out.warnings = errors
        }
        return out
    }
}

// MARK: - Ready-made sources

struct RevenuePreset: Identifiable {
    var id: String
    var name: String
    var icon: String
    var summary: String
    var docs: String
    var headers: String
    var make: () -> WidgetConfig

    static let all: [RevenuePreset] = [
        RevenuePreset(
            id: "applovin-max", name: "AppLovin MAX", icon: "chart.line.uptrend.xyaxis",
            summary: "Daily estimated ad revenue and impressions per app (last 45 days, the API's limit).",
            docs: "https://support.applovin.com/en/max/reporting-apis/revenue-reporting-api",
            headers: "$report_key: YOUR_REPORT_KEY",
            make: {
                var w = CustomRevenue.makeSource(name: "AppLovin MAX", source: .http)
                w.preset = "applovin-max"
                w.url = "https://r.applovin.com/maxReport?api_key={{$report_key}}&start={{daysAgo:44}}&end={{today}}"
                    + "&columns=day,application,store_id,package_name,platform,estimated_revenue,impressions&format=json"
                w.transform = "data => (data.results || []).map(r => ({\n  date: r.day, app: r.application, platform: r.platform,\n  storeId: r.platform === 'ios' ? r.store_id : (r.package_name || r.store_id),\n  adRevenue: Number(r.estimated_revenue), impressions: Number(r.impressions)\n}))"
                return w
            }),
        RevenuePreset(
            id: "levelplay", name: "LevelPlay (ironSource)", icon: "chart.bar",
            summary: "Daily revenue and impressions per app and platform from the LevelPlay Reporting API.",
            docs: "https://docs.unity.com/en-us/grow/levelplay/platform/api/reporting",
            headers: "$secretkey: YOUR_SECRET_KEY\n$refreshToken: YOUR_REFRESH_TOKEN",
            make: {
                var w = CustomRevenue.makeSource(name: "LevelPlay", source: .command)
                w.preset = "levelplay"
                w.command = """
                TOKEN=$(curl -sf https://platform.ironsrc.com/partners/publisher/auth -H "secretkey: $secretkey" -H "refreshToken: $refreshToken" | tr -d '"') || { echo 'LevelPlay auth failed' >&2; exit 1; }
                curl -sf "https://platform.ironsrc.com/levelPlay/reporting/v1?startDate={{daysAgo:89}}&endDate={{today}}&breakdowns=date,app,platform&metrics=revenue,impressions" -H "Authorization: Bearer $TOKEN"
                """
                w.transform = "data => (data.data || data).map(r => ({\n  date: r.date, app: r.appName || r.app || r.appKey, platform: r.platform,\n  adRevenue: r.revenue, impressions: r.impressions\n}))"
                return w
            }),
        RevenuePreset(
            id: "json-api", name: "Any JSON API", icon: "network",
            summary: "Your own backend or any service. Return the rows format, or map the response with a transform.",
            docs: "", headers: "Authorization: Bearer YOUR_TOKEN",
            make: {
                var w = CustomRevenue.makeSource(name: "My revenue API", source: .http)
                w.url = "https://api.example.com/revenue?from={{daysAgo:89}}&to={{today}}"
                return w
            }),
        RevenuePreset(
            id: "command", name: "Script / command", icon: "terminal",
            summary: "Any script that prints the rows JSON: SQL query, Python, a CSV export piped through jq…",
            docs: "", headers: "",
            make: {
                var w = CustomRevenue.makeSource(name: "My script", source: .command)
                w.command = "echo '\(RevenueFormat.example.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: ""))'"
                return w
            }),
        RevenuePreset(
            id: "push", name: "Push (API / MCP)", icon: "arrow.down.circle",
            summary: "Nothing to fetch: send rows from a server, cron job or Claude via the local API or MCP.",
            docs: "", headers: "",
            make: { CustomRevenue.makeSource(name: "Pushed revenue", source: .push) }),
    ]

    static func preset(_ id: String) -> RevenuePreset? { all.first { $0.id == id } }
}
