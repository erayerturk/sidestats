import Foundation

/// AdMob Network Report — daily estimated earnings + impressions per app.
/// Docs: https://developers.google.com/admob/api/v1/reference/rest/v1/accounts.networkReport/generate
struct AdMobProvider: Provider {
    let kind = SourceKind.admob
    let accountKind: AccountKind? = .google
    private let api = "https://admob.googleapis.com/v1"

    func isConfigured(_ c: Config) -> Bool {
        c.admobEnabled && GoogleClient.isConnected(c)
    }

    func fetch(config c: Config, start: String, end: String) async throws -> ProviderResult {
        let token = try await GoogleOAuth.shared.accessToken(config: c)
        let accounts = try await HTTP.json(HTTP.request("\(api)/accounts", bearer: token)) as? [String: Any] ?? [:]
        var result = ProviderResult()

        for account in accounts.arr("account").compactMap({ $0.str("name") }) where ResourceClaims.claim("admob:\(account)") {
            // AdMob app id -> store key, so ad revenue merges with store revenue.
            var appMap: [String: AppKey] = [:]
            var pageToken: String?
            repeat {
                var url = "\(api)/\(account)/apps?pageSize=500"
                if let pageToken { url += "&pageToken=\(pageToken)" }
                let json = try await HTTP.json(HTTP.request(url, bearer: token)) as? [String: Any] ?? [:]
                for app in json.arr("apps") {
                    guard let appId = app.str("appId") else { continue }
                    let platform: Platform = app.str("platform") == "ANDROID" ? .android : .ios
                    let linked = app.dict("linkedAppInfo") ?? [:]
                    let manual = app.dict("manualAppInfo") ?? [:]
                    let key = AppKey(platform: platform, storeId: linked.str("appStoreId") ?? "admob:\(appId)")
                    appMap[appId] = key
                    if let name = linked.str("displayName") ?? manual.str("displayName") {
                        result.names.append(.init(app: key, name: name, priority: 50))
                    }
                }
                pageToken = json.str("nextPageToken")
            } while pageToken != nil && pageToken != ""

            let body: [String: Any] = ["reportSpec": [
                "dateRange": ["startDate": Self.ymd(start), "endDate": Self.ymd(end)],
                "dimensions": ["DATE", "APP"],
                "metrics": ["ESTIMATED_EARNINGS", "IMPRESSIONS"],
                "localizationSettings": ["currencyCode": c.baseCurrency],
            ]]
            let resp = try await HTTP.json(HTTP.request("\(api)/\(account)/networkReport:generate",
                                                        method: "POST", bearer: token, json: body))
            var currency = c.baseCurrency
            for item in resp as? [[String: Any]] ?? [] {
                if let header = item.dict("header") {
                    currency = header.dict("localizationSettings")?.str("currencyCode") ?? currency
                }
                guard let row = item.dict("row") else { continue }
                let dims = row.dict("dimensionValues") ?? [:]
                let metrics = row.dict("metricValues") ?? [:]
                guard let rawDate = dims.dict("DATE")?.str("value"), rawDate.count == 8 else { continue }
                let appId = dims.dict("APP")?.str("value") ?? ""
                let key = appMap[appId] ?? AppKey(platform: .other, storeId: "admob:\(appId)")
                if appMap[appId] == nil, let label = dims.dict("APP")?.str("displayLabel") {
                    result.names.append(.init(app: key, name: label, priority: 40))
                }
                let date = "\(rawDate.prefix(4))-\(rawDate.dropFirst(4).prefix(2))-\(rawDate.suffix(2))"
                result.rows.append(MetricRow(
                    date: date, app: key, source: kind, currency: currency,
                    adRevenue: (metrics.dict("ESTIMATED_EARNINGS")?.num("microsValue") ?? 0) / 1_000_000,
                    impressions: Int(metrics.dict("IMPRESSIONS")?.num("integerValue") ?? 0)))
            }
        }
        return result
    }

    static func ymd(_ s: String) -> [String: Int] {
        let p = s.split(separator: "-").map { Int($0) ?? 0 }
        return ["year": p[0], "month": p[1], "day": p[2]]
    }
}

/// Google Play reports from the developer's Cloud Storage bucket:
/// stats/installs/*_overview.csv (daily installs) and sales/salesreport_YYYYMM.zip (orders).
/// Docs: https://support.google.com/googleplay/android-developer/answer/6135870
struct GooglePlayProvider: Provider {
    let kind = SourceKind.googlePlay
    let accountKind: AccountKind? = .google

    func isConfigured(_ c: Config) -> Bool {
        !c.playBucket.isEmpty && GoogleClient.isConnected(c)
    }

    private func bucket(_ c: Config) -> String {
        c.playBucket.replacingOccurrences(of: "gs://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    func fetch(config c: Config, start: String, end: String) async throws -> ProviderResult {
        let token = try await GoogleOAuth.shared.accessToken(config: c)
        let b = bucket(c)
        guard ResourceClaims.claim("play:\(b)") else { return ProviderResult() }
        let months = Set(DayFormat.days(from: start, to: end).map { $0.prefix(7).replacingOccurrences(of: "-", with: "") })
        var result = ProviderResult()
        var agg: [String: MetricRow] = [:]

        func add(_ day: String, _ key: AppKey, _ currency: String, _ f: (inout MetricRow) -> Void) {
            guard day >= start && day <= end else { return }
            let id = "\(day)|\(key.id)|\(currency)"
            var row = agg[id] ?? MetricRow(date: day, app: key, source: kind, currency: currency)
            f(&row)
            agg[id] = row
        }

        // Installs
        for name in try await list(b, prefix: "stats/installs/", token: token)
        where name.hasSuffix("_overview.csv") && months.contains(where: { name.contains("_\($0)_") }) {
            let text = CSV.decode(try await download(b, name, token: token))
            for r in CSV.records(text) {
                guard let day = r["Date"], let pkg = r["Package Name"] else { continue }
                let installs = Int(r["Daily User Installs"] ?? r["Daily Device Installs"] ?? "") ?? 0
                add(day, AppKey(platform: .android, storeId: pkg), "USD") { $0.downloads += installs }
            }
        }

        // Sales (gross item price; net estimated with playNetShare)
        for month in months {
            let name = "sales/salesreport_\(month).zip"
            guard let zip = try? await download(b, name, token: token) else { continue }
            for r in CSV.records(try Self.unzipFirst(zip)) {
                guard let day = r["Order Charged Date"], let pkg = r["Product ID"] else { continue }
                let currency = r["Currency of Sale"] ?? "USD"
                var amount = Double((r["Item Price"] ?? "0").replacingOccurrences(of: ",", with: "")) ?? 0
                if (r["Financial Status"] ?? "").localizedCaseInsensitiveContains("refund") { amount = -abs(amount) }
                add(day, AppKey(platform: .android, storeId: pkg), currency) { $0.iapRevenue += amount * c.playNetShare }
            }
        }
        result.rows = Array(agg.values)
        return result
    }

    private func list(_ bucket: String, prefix: String, token: String) async throws -> [String] {
        var names: [String] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: "https://storage.googleapis.com/storage/v1/b/\(bucket)/o")!
            comps.queryItems = [.init(name: "prefix", value: prefix), .init(name: "fields", value: "items/name,nextPageToken")]
            if let pageToken { comps.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let json = try await HTTP.json(HTTP.request(comps.url!.absoluteString, bearer: token)) as? [String: Any] ?? [:]
            names += json.arr("items").compactMap { $0.str("name") }
            pageToken = json.str("nextPageToken")
        } while pageToken != nil
        return names
    }

    private func download(_ bucket: String, _ name: String, token: String) async throws -> Data {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let (d, _) = try await HTTP.data(HTTP.request(
            "https://storage.googleapis.com/storage/v1/b/\(bucket)/o/\(encoded)?alt=media", bearer: token))
        return d
    }

    static func unzipFirst(_ zip: Data) throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sidestats-\(UUID().uuidString).zip")
        try zip.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", tmp.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return CSV.decode(out)
    }
}
