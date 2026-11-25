import Foundation

enum Platform: String, Codable, CaseIterable {
    case ios, mac, android, other

    var label: String {
        switch self {
        case .ios: return "iOS"
        case .mac: return "macOS"
        case .android: return "Android"
        case .other: return "Other"
        }
    }

    var short: String {
        switch self {
        case .ios: return "iOS"
        case .mac: return "MAC"
        case .android: return "AND"
        case .other: return "ADS"
        }
    }

    var symbol: String {
        switch self {
        case .ios: return "iphone"
        case .mac: return "laptopcomputer"
        case .android: return "candybarphone"
        case .other: return "questionmark.circle"
        }
    }
}

/// Uniquely identifies one store listing (e.g. ios:123456789, android:com.foo.bar).
struct AppKey: Hashable, Codable, Comparable {
    var platform: Platform
    var storeId: String

    static let unassigned = AppKey(platform: .other, storeId: "unassigned")

    var id: String { "\(platform.rawValue):\(storeId)" }

    static func < (a: AppKey, b: AppKey) -> Bool { a.id < b.id }
}

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case appStoreConnect, googlePlay, admob, appleSearchAds, metaAds, custom, demo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appStoreConnect: return "App Store Connect"
        case .googlePlay: return "Google Play"
        case .admob: return "AdMob"
        case .appleSearchAds: return "Apple Search Ads"
        case .metaAds: return "Meta Ads"
        case .custom: return "Custom sources"
        case .demo: return "Demo data"
        }
    }
}

/// One day of metrics for one app from one source. Money values are in `currency`
/// and converted to the user's base currency at display time.
struct MetricRow: Codable, Hashable {
    var date: String          // yyyy-MM-dd
    var app: AppKey
    var source: SourceKind
    var currency: String
    var adRevenue: Double = 0
    var iapRevenue: Double = 0   // store proceeds: paid apps, IAP, subscriptions
    var spend: Double = 0
    var downloads: Int = 0
    var impressions: Int = 0
}

/// Display name hint discovered by a provider for an app key.
struct AppNameHint: Codable, Hashable {
    var app: AppKey
    var name: String
    var priority: Int   // higher wins
}

struct ProviderResult: Codable {
    var rows: [MetricRow] = []
    var names: [AppNameHint] = []
    /// Partial failures (e.g. one of several custom sources failed).
    var warnings: [String]?
}

enum DateRangeOption: String, CaseIterable, Identifiable {
    case d7 = "7D", d30 = "30D", mtd = "MTD", d90 = "90D"
    var id: String { rawValue }

    func dates(today: Date = Date()) -> (start: String, end: String) {
        let cal = Calendar.utc
        let end = today
        let start: Date
        switch self {
        case .d7: start = cal.date(byAdding: .day, value: -6, to: end)!
        case .d30: start = cal.date(byAdding: .day, value: -29, to: end)!
        case .d90: start = cal.date(byAdding: .day, value: -89, to: end)!
        case .mtd: start = cal.date(from: cal.dateComponents([.year, .month], from: end))!
        }
        return (DayFormat.string(start), DayFormat.string(end))
    }
}

/// Aggregated numbers for an app group in the selected range, in base currency.
struct Totals {
    var adRevenue: Double = 0
    var iapRevenue: Double = 0
    var spend: Double = 0
    var downloads: Int = 0
    var impressions: Int = 0

    var revenue: Double { adRevenue + iapRevenue }
    var net: Double { revenue - spend }
    var roas: Double? { spend > 0 ? revenue / spend : nil }

    static func + (a: Totals, b: Totals) -> Totals {
        Totals(adRevenue: a.adRevenue + b.adRevenue,
               iapRevenue: a.iapRevenue + b.iapRevenue,
               spend: a.spend + b.spend,
               downloads: a.downloads + b.downloads,
               impressions: a.impressions + b.impressions)
    }
}

struct DailyPoint: Identifiable {
    var date: Date
    var revenue: Double
    var spend: Double
    var net: Double { revenue - spend }
    var id: Date { date }
}

struct AppGroupSummary: Identifiable {
    var id: String          // normalized group name
    var name: String
    var keys: [AppKey]
    var totals: Totals
    var series: [DailyPoint]
    var iosStoreId: String? { keys.first(where: { $0.platform == .ios || $0.platform == .mac })?.storeId }
    var platforms: [Platform] { Array(Set(keys.map(\.platform))).sorted { $0.rawValue < $1.rawValue } }
}

enum DayFormat {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar.utc
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(_ d: Date) -> String { formatter.string(from: d) }
    static func date(_ s: String) -> Date? { formatter.date(from: s) }

    /// All yyyy-MM-dd strings between start and end inclusive.
    static func days(from start: String, to end: String) -> [String] {
        guard var d = date(start), let e = date(end) else { return [] }
        var out: [String] = []
        while d <= e {
            out.append(string(d))
            d = Calendar.utc.date(byAdding: .day, value: 1, to: d)!
        }
        return out
    }

    static func daysAgo(_ n: Int) -> String {
        string(Calendar.utc.date(byAdding: .day, value: -n, to: Date())!)
    }
}

extension Calendar {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

struct SideStatsError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
