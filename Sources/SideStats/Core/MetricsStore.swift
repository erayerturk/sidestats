import Foundation
import SwiftUI

struct SourceStatus {
    var loading = false
    var lastSuccess: Date?
    var lastAttempt: Date?
    var error: String?
}

enum SortOption: String, CaseIterable, Identifiable {
    case net = "Net", revenue = "Revenue", spend = "Spend", downloads = "Downloads", name = "Name"
    var id: String { rawValue }
}

@MainActor
final class MetricsStore: ObservableObject {
    static let fetchDays = 90
    let providers: [Provider] = [
        AppStoreConnectProvider(), GooglePlayProvider(), AdMobProvider(),
        AppleSearchAdsProvider(), GoogleAdsProvider(), MetaAdsProvider(), CustomRevenueProvider(), DemoProvider(),
    ]

    @Published var config = Config.load() { didSet { if config != oldValue { config.save(); recompute() } } }
    @Published var range: DateRangeOption = DateRangeOption(rawValue: UserDefaults.standard.string(forKey: "range") ?? "") ?? .d30 {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "range"); recompute() }
    }
    @Published var sort: SortOption = .net { didSet { recompute() } }
    @Published private(set) var status: [SourceKind: SourceStatus] = [:]
    @Published private(set) var groups: [AppGroupSummary] = []
    @Published private(set) var totals = Totals()
    @Published private(set) var series: [DailyPoint] = []
    @Published private(set) var missingCurrencies: [String] = []
    @Published private(set) var campaigns: [CampaignSummary] = []

    private var results: [SourceKind: ProviderResult] = [:]
    private var rates: [String: Double] = [:]
    private var timer: Timer?

    init() {
        for kind in SourceKind.allCases {
            if let r = Storage.load(ProviderResult.self, "source-\(kind.rawValue).json") { results[kind] = r }
            status[kind] = SourceStatus(lastSuccess: UserDefaults.standard.object(forKey: "ok-\(kind.rawValue)") as? Date)
        }
        recompute()
        Task { rates = await FXService.shared.rates(base: config.baseCurrency); recompute() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isLoading, self.hasAnySource else { return }
                let last = self.configuredSources.compactMap { self.status[$0]?.lastAttempt ?? self.status[$0]?.lastSuccess }.min() ?? .distantPast
                if Date().timeIntervalSince(last) >= Double(self.config.revenueRefreshMinutes * 60) {
                    Task { await self.refresh() }
                }
            }
        }
    }

    var configuredSources: [SourceKind] { providers.filter { Self.isConfigured($0, config) }.map(\.kind) }

    /// Account-based providers are configured when any enabled account is.
    nonisolated static func isConfigured(_ p: Provider, _ c: Config) -> Bool {
        guard let k = p.accountKind else { return p.isConfigured(c) }
        return c.accounts(k).contains { $0.enabled && p.isConfigured($0.scoped(c)) }
    }

    /// Runs a provider once per configured account and merges the results; failing accounts become warnings.
    nonisolated static func fetch(_ p: Provider, _ c: Config, start: String, end: String) async throws -> ProviderResult {
        guard let k = p.accountKind else { return try await p.fetch(config: c, start: start, end: end) }
        let accounts = c.accounts(k).filter { $0.enabled && p.isConfigured($0.scoped(c)) }
        return try await ResourceClaims.$current.withValue(ResourceClaims()) {
            try await fetchAccounts(p, accounts, c, start: start, end: end)
        }
    }

    nonisolated private static func fetchAccounts(_ p: Provider, _ accounts: [SourceAccount], _ c: Config,
                                                  start: String, end: String) async throws -> ProviderResult {
        let tasks = accounts.map { a in
            Task { () -> (String, Result<ProviderResult, Error>) in
                do { return (a.displayName, .success(try await p.fetch(config: a.scoped(c), start: start, end: end))) }
                catch { return (a.displayName, .failure(error)) }
            }
        }
        var out = ProviderResult()
        var errors: [String] = []
        for t in tasks {
            let (name, r) = await t.value
            switch r {
            case .success(let res):
                out.rows += res.rows; out.names += res.names
                if let c = res.campaigns { out.campaigns = (out.campaigns ?? []) + c }
                errors += (res.warnings ?? []).map { accounts.count > 1 ? "\(name): \($0)" : $0 }
            case .failure(let e):
                errors.append(accounts.count > 1 ? "\(name): \(e.localizedDescription)" : e.localizedDescription)
            }
        }
        if out.rows.isEmpty && errors.count == accounts.count && !errors.isEmpty {
            throw SideStatsError(errors.joined(separator: "\n"))
        }
        out.warnings = errors.isEmpty ? nil : errors
        return out
    }
    var isLoading: Bool { status.values.contains { $0.loading } }
    var hasAnySource: Bool { !configuredSources.isEmpty }

    func refresh(only kinds: Set<SourceKind>? = nil) async {
        // Sample data would mix with real numbers once a real source is connected.
        if config.useDemoData && configuredSources.contains(where: { $0 != .demo }) { config.useDemoData = false }
        rates = await FXService.shared.rates(base: config.baseCurrency)
        let start = DayFormat.daysAgo(Self.fetchDays - 1), end = DayFormat.daysAgo(0)
        let cfg = config
        // Drop cached data for sources that were disconnected.
        for kind in SourceKind.allCases where !configuredSources.contains(kind) && results[kind] != nil {
            results[kind] = nil
            Storage.remove("source-\(kind.rawValue).json")
        }
        await withTaskGroup(of: Void.self) { group in
            for p in providers where Self.isConfigured(p, cfg) && (kinds?.contains(p.kind) ?? true) {
                status[p.kind, default: .init()].loading = true
                status[p.kind, default: .init()].lastAttempt = Date()
                group.addTask { [p] in
                    do {
                        let r = try await Self.fetch(p, cfg, start: start, end: end)
                        await self.finished(p.kind, .success(r))
                    } catch {
                        await self.finished(p.kind, .failure(error))
                    }
                }
            }
        }
        recompute()
    }

    private func finished(_ kind: SourceKind, _ result: Result<ProviderResult, Error>) {
        var s = status[kind] ?? .init()
        s.loading = false
        switch result {
        case .success(let r):
            results[kind] = r
            Storage.save(r, "source-\(kind.rawValue).json")
            s.lastSuccess = Date(); s.error = r.warnings?.joined(separator: "\n")
            UserDefaults.standard.set(s.lastSuccess, forKey: "ok-\(kind.rawValue)")
        case .failure(let e):
            s.error = e.localizedDescription
        }
        status[kind] = s
        recompute()
    }

    // MARK: - Aggregation

    func displayName(_ key: AppKey) -> String {
        if let alias = config.aliases[key.id], !alias.isEmpty { return alias }
        if key == .unassigned { return "Unattributed ad spend" }
        let best = results.values.flatMap(\.names).filter { $0.app == key }.max { $0.priority < $1.priority }
        return best?.name ?? key.storeId
    }

    nonisolated static func groupId(_ name: String) -> String {
        name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    struct Snapshot {
        var groups: [AppGroupSummary]
        var totals: Totals
        var series: [DailyPoint]
        var missingCurrencies: [String]
        var campaigns: [CampaignSummary] = []
    }

    func recompute() {
        let snap = snapshot(for: range)
        groups = snap.groups
        totals = snap.totals
        series = snap.series
        missingCurrencies = snap.missingCurrencies
        campaigns = snap.campaigns
    }

    /// Aggregates for any range without changing the sidebar's selection.
    func snapshot(for range: DateRangeOption) -> Snapshot {
        let (start, end) = range.dates()
        let days = DayFormat.days(from: start, to: end)
        let base = config.baseCurrency
        var missing = Set<String>()
        func conv(_ v: Double, _ cur: String) -> Double {
            if v == 0 || cur == base { return v }
            guard let r = rates[cur], r > 0 else { missing.insert(cur); return 0 }
            return v / r
        }

        let active = Set(configuredSources)
        let hidden = Set(config.hiddenApps)
        var byKey: [AppKey: (Totals, [String: (Double, Double)])] = [:]
        var camps: [String: CampaignSummary] = [:]
        for (kind, result) in results where active.contains(kind) {
            for info in result.campaigns ?? [] where !hidden.contains(info.app.id) {
                camps[info.id] = CampaignSummary(id: info.id, name: info.name, source: info.source,
                                                 appName: info.app == .unassigned ? nil : displayName(info.app),
                                                 state: info.state, totals: Totals())
            }
            for row in result.rows where row.date >= start && row.date <= end && !hidden.contains(row.app.id) {
                var entry = byKey[row.app] ?? (Totals(), [:])
                let t = Totals(adRevenue: conv(row.adRevenue, row.currency),
                               iapRevenue: conv(row.iapRevenue, row.currency),
                               spend: conv(row.spend, row.currency),
                               downloads: row.downloads, impressions: row.impressions,
                               adImpressions: row.adImpressions, clicks: row.clicks, installs: row.installs)
                entry.0 = entry.0 + t
                if !row.campaign.isEmpty {
                    var cs = camps[row.campaign] ?? CampaignSummary(id: row.campaign, name: row.campaign, source: row.source,
                                                                    appName: row.app == .unassigned ? nil : displayName(row.app),
                                                                    state: .unknown, totals: Totals())
                    cs.totals = cs.totals + t
                    cs.daily[row.date] = (cs.daily[row.date] ?? Totals()) + t
                    camps[row.campaign] = cs
                }
                let d = entry.1[row.date] ?? (0, 0)
                entry.1[row.date] = (d.0 + t.revenue, d.1 + t.spend)
                byKey[row.app] = entry
            }
        }

        var grouped: [String: AppGroupSummary] = [:]
        var dailyAll: [String: (Double, Double)] = [:]
        for (key, (t, daily)) in byKey {
            let name = displayName(key)
            let gid = Self.groupId(name).isEmpty ? key.id : Self.groupId(name)
            var g = grouped[gid] ?? AppGroupSummary(id: gid, name: name, keys: [], totals: Totals(), series: [])
            g.keys.append(key)
            g.totals = g.totals + t
            var map = Dictionary(uniqueKeysWithValues: g.series.map { (DayFormat.string($0.date), $0) })
            for (day, v) in daily {
                let p = map[day] ?? DailyPoint(date: DayFormat.date(day)!, revenue: 0, spend: 0)
                map[day] = DailyPoint(date: p.date, revenue: p.revenue + v.0, spend: p.spend + v.1)
                let a = dailyAll[day] ?? (0, 0)
                dailyAll[day] = (a.0 + v.0, a.1 + v.1)
            }
            g.series = Array(map.values)
            grouped[gid] = g
        }

        func fill(_ pts: [DailyPoint]) -> [DailyPoint] {
            let m = Dictionary(uniqueKeysWithValues: pts.map { (DayFormat.string($0.date), $0) })
            return days.map { m[$0] ?? DailyPoint(date: DayFormat.date($0)!, revenue: 0, spend: 0) }
        }

        var list = grouped.values
            .filter { $0.totals.revenue != 0 || $0.totals.spend != 0 || $0.totals.downloads != 0 }
            .map { g -> AppGroupSummary in var g = g; g.series = fill(g.series); return g }
        switch sort {
        case .net: list.sort { $0.totals.net > $1.totals.net }
        case .revenue: list.sort { $0.totals.revenue > $1.totals.revenue }
        case .spend: list.sort { $0.totals.spend > $1.totals.spend }
        case .downloads: list.sort { $0.totals.downloads > $1.totals.downloads }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return Snapshot(
            groups: list,
            totals: list.reduce(Totals()) { $0 + $1.totals },
            series: fill(dailyAll.map { DailyPoint(date: DayFormat.date($0.key)!, revenue: $0.value.0, spend: $0.value.1) }),
            missingCurrencies: missing.sorted(),
            campaigns: camps.values.map { c -> CampaignSummary in
                var c = c
                c.days = days.map { (DayFormat.date($0)!, c.daily[$0] ?? Totals()) }
                return c
            }.sorted {
                let r: [CampaignState: Int] = [.active: 0, .scheduled: 1, .unknown: 2, .paused: 3, .ended: 4]
                return (r[$0.state] ?? 9, -$0.totals.spend, $0.name) < (r[$1.state] ?? 9, -$1.totals.spend, $1.name)
            })
    }

    func setHidden(_ hide: Bool, for keys: [AppKey]) {
        var c = config
        let ids = keys.map(\.id)
        c.hiddenApps.removeAll { ids.contains($0) }
        if hide { c.hiddenApps += ids }
        config = c
    }

    /// Hidden apps grouped by display name, for Settings.
    var hiddenGroups: [(name: String, keys: [AppKey])] {
        let keys = config.hiddenApps.compactMap(AppKey.init(id:))
        return Dictionary(grouping: keys, by: displayName).map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    func setAlias(_ name: String?, for keys: [AppKey]) {
        var c = config
        for k in keys { c.aliases[k.id] = (name?.isEmpty ?? true) ? nil : name }
        config = c
    }
}
