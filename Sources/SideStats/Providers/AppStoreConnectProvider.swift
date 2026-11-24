import Foundation

/// App Store Connect Sales & Trends (daily SALES/SUMMARY reports).
/// Docs: https://developer.apple.com/documentation/appstoreconnectapi/download_sales_and_trends_reports
struct AppStoreConnectProvider: Provider {
    let kind = SourceKind.appStoreConnect

    /// Product type identifiers that count as a first-time download.
    static let downloadTypes: Set<String> = ["1", "1F", "1T", "F1", "1E", "1EP", "1EU"]

    func isConfigured(_ c: Config) -> Bool {
        !c.ascIssuerId.isEmpty && !c.ascKeyId.isEmpty && !c.ascVendorNumber.isEmpty && Secret.ascPrivateKey.isSet
    }

    private func token(_ c: Config) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        return try JWT.es256(
            header: ["alg": "ES256", "kid": c.ascKeyId, "typ": "JWT"],
            payload: ["iss": c.ascIssuerId, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"],
            pem: Secret.ascPrivateKey.value ?? "")
    }

    func fetch(config c: Config, start: String, end: String) async throws -> ProviderResult {
        let jwt = try token(c)

        // SKU -> app (IAP rows reference their parent app by SKU), plus display names.
        var skuToApp: [String: AppKey] = [:]
        var names: [AppNameHint] = []
        var next: String? = "https://api.appstoreconnect.apple.com/v1/apps?fields[apps]=name,sku,bundleId&limit=200"
        while let url = next {
            let json = try await HTTP.json(HTTP.request(url, bearer: jwt)) as? [String: Any] ?? [:]
            for app in json.arr("data") {
                guard let id = app.str("id"), let attrs = app.dict("attributes") else { continue }
                let key = AppKey(platform: .ios, storeId: id)
                if let sku = attrs.str("sku") { skuToApp[sku] = key }
                if let name = attrs.str("name") { names.append(.init(app: key, name: name, priority: 100)) }
            }
            next = json.dict("links")?.str("next")
        }

        // Past days never change, so they are cached on disk; the last 3 days are always refetched.
        var cache = Storage.load([String: [MetricRow]].self, "asc-days.json") ?? [:]
        let fresh = Set((0..<3).map { DayFormat.daysAgo($0) })
        let todo = DayFormat.days(from: start, to: end).filter { cache[$0] == nil || fresh.contains($0) }

        var firstError: Error?
        for chunk in stride(from: 0, to: todo.count, by: 6).map({ Array(todo[$0..<min($0 + 6, todo.count)]) }) {
            await withTaskGroup(of: (String, Result<[MetricRow]?, Error>).self) { group in
                for day in chunk {
                    group.addTask {
                        do { return (day, .success(try await fetchDay(day, c, jwt, skuToApp))) }
                        catch { return (day, .failure(error)) }
                    }
                }
                for await (day, result) in group {
                    switch result {
                    case .success(let rows?): cache[day] = rows
                    case .success(nil): if !fresh.contains(day) { cache[day] = [] }  // no sales that day
                    case .failure(let e): firstError = firstError ?? e
                    }
                }
            }
        }
        Storage.save(cache, "asc-days.json")
        if let firstError, cache.isEmpty { throw firstError }

        let rows = DayFormat.days(from: start, to: end).flatMap { cache[$0] ?? [] }
        return ProviderResult(rows: rows, names: names)
    }

    /// Returns nil when Apple has no report for that day (404 = not yet available or no sales).
    private func fetchDay(_ day: String, _ c: Config, _ jwt: String, _ skuToApp: [String: AppKey]) async throws -> [MetricRow]? {
        var comps = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/salesReports")!
        comps.queryItems = [
            .init(name: "filter[frequency]", value: "DAILY"),
            .init(name: "filter[reportType]", value: "SALES"),
            .init(name: "filter[reportSubType]", value: "SUMMARY"),
            .init(name: "filter[vendorNumber]", value: c.ascVendorNumber),
            .init(name: "filter[reportDate]", value: day),
        ]
        var req = HTTP.request(comps.url!.absoluteString, bearer: jwt)
        req.setValue("application/a-gzip", forHTTPHeaderField: "Accept")
        let (data, code) = try await HTTP.data(req, allow404: true)
        if code == 404 { return nil }
        let text = CSV.decode(try Gzip.decompress(data))

        var agg: [String: MetricRow] = [:]   // appKey|currency
        for r in CSV.records(text, delimiter: "\t") {
            let type = r["Product Type Identifier"] ?? ""
            let units = Double(r["Units"] ?? "") ?? 0
            let proceeds = Double(r["Developer Proceeds"] ?? "") ?? 0
            let currency = r["Currency of Proceeds"] ?? "USD"
            let parent = (r["Parent Identifier"] ?? "").trimmingCharacters(in: .whitespaces)
            let platform: Platform = type.hasPrefix("F") ? .mac : .ios

            let key: AppKey
            if !parent.isEmpty, let k = skuToApp[parent] { key = k }
            else if let id = r["Apple Identifier"], !id.isEmpty, parent.isEmpty { key = AppKey(platform: .ios, storeId: id) }
            else { key = AppKey(platform: platform, storeId: "sku:\(parent)") }

            let id = "\(key.id)|\(currency)"
            var row = agg[id] ?? MetricRow(date: day, app: key, source: kind, currency: currency)
            row.iapRevenue += units * proceeds
            if Self.downloadTypes.contains(type) { row.downloads += Int(units) }
            agg[id] = row
        }
        return Array(agg.values)
    }
}
