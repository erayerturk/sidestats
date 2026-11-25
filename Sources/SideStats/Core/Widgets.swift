import Foundation

// MARK: - Widget definition (what the user configures / shares)

enum WidgetSourceType: String, Codable, CaseIterable, Identifiable {
    case http, command, push
    var id: String { rawValue }
    var title: String {
        switch self {
        case .http: return "HTTP API"
        case .command: return "Shell command"
        case .push: return "Push (API / MCP)"
        }
    }
}

enum WidgetDisplay: String, Codable, CaseIterable, Identifiable {
    case auto, stat, chart, list, text
    var id: String { rawValue }
}

struct WidgetConfig: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = "New widget"
    var icon = "square.grid.2x2"           // SF Symbol
    var source: WidgetSourceType = .http
    var url = ""
    var method = "GET"
    var body = ""
    var command = ""
    var jsonPath = ""                      // e.g. data.items or result.0
    var fields = ""                        // comma separated keys to keep (auto mode)
    var display: WidgetDisplay = .auto
    var refreshSeconds = 300
    var enabled = true
    /// Optional JavaScript run on the payload before rendering. Either a function expression
    /// `(data) => ({items: [...]})` or a body using `data` that returns a value. See WidgetTransform.
    var transform = ""
    /// Preset id this widget was created from (informational).
    var preset = ""

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = WidgetConfig()
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? def.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? def.name
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? def.icon
        source = try c.decodeIfPresent(WidgetSourceType.self, forKey: .source) ?? def.source
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        jsonPath = try c.decodeIfPresent(String.self, forKey: .jsonPath) ?? ""
        fields = try c.decodeIfPresent(String.self, forKey: .fields) ?? ""
        display = try c.decodeIfPresent(WidgetDisplay.self, forKey: .display) ?? .auto
        refreshSeconds = max(5, try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 300)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        transform = try c.decodeIfPresent(String.self, forKey: .transform) ?? ""
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? ""
    }

    /// "Header: value" lines, kept in the Keychain because they usually hold tokens.
    /// Cached in memory so periodic refreshes don't hit the Keychain (which can prompt) every time.
    var headers: String {
        get {
            HeaderCache.lock.lock(); defer { HeaderCache.lock.unlock() }
            if let h = HeaderCache.values[id] { return h }
            let h = Keychain.get("widget.headers.\(id)") ?? ""
            HeaderCache.values[id] = h
            return h
        }
        nonmutating set {
            HeaderCache.lock.lock(); HeaderCache.values[id] = newValue; HeaderCache.lock.unlock()
            Keychain.set("widget.headers.\(id)", newValue)
        }
    }
}

private enum HeaderCache {
    static let lock = NSLock()
    nonisolated(unsafe) static var values: [String: String] = [:]
}

// MARK: - Renderable items (the SideStats widget format)

struct WidgetItem: Identifiable {
    let id = UUID()
    var kind: Kind

    enum Kind {
        case stat(StatSpec)
        case chart(ChartSpec)
        case list(ListSpec)
        case text(TextSpec)
        case progress(ProgressSpec)
        case status(StatusSpec)
    }
}

struct StatSpec {
    var label: String
    var value: Double?
    var text: String?
    var format = "number"           // number | currency | percent | bytes | duration
    var currency = "USD"
    var decimals: Int?
    var unit: String?
    var delta: Double?              // fraction, e.g. 0.12 = +12%
    var positiveIsGood = true
    var caption: String?
    var color: String?
    var sparkline: [Double] = []
}

struct ChartPoint: Identifiable {
    let id = UUID()
    var label: String
    var date: Date?
    var y: Double
}

struct ChartSeries: Identifiable {
    let id = UUID()
    var name: String
    var color: String?
    var points: [ChartPoint]
}

struct ChartSpec {
    var label: String?
    var kind = "line"               // line | area | bar | pie
    var series: [ChartSeries]
    var format = "number"
    var currency = "USD"
    var height: Double = 110
    var usesDates: Bool { series.allSatisfy { $0.points.allSatisfy { $0.date != nil } } }
}

struct ListRow: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var value: String?
    var valueColor: String?
    var icon: String?               // https://… image or sf:symbol.name
    var url: String?
}

struct ListSpec {
    var label: String?
    var rows: [ListRow]
    var limit = 10
}

struct TextSpec {
    var text: String
    var style = "body"              // title | body | caption | mono
    var color: String?
}

struct ProgressSpec {
    var label: String
    var value: Double               // 0…1
    var caption: String?
    var color: String?
}

struct StatusSpec {
    var label: String
    var state: String               // ok | warn | error | info
    var detail: String?
}

// MARK: - Parsing: explicit format + automatic inference for plain JSON

enum WidgetParser {
    static let types: Set<String> = ["stat", "chart", "list", "text", "progress", "status"]

    /// Full pipeline: optional JS transform, then format parsing / auto-detection.
    static func process(_ payload: Any, config: WidgetConfig) throws -> [WidgetItem] {
        let transformed = config.transform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? payload : try WidgetTransform.apply(config.transform, to: payload)
        return parse(transformed, config: config)
    }

    static func parse(_ payload: Any, config: WidgetConfig) -> [WidgetItem] {
        let value = select(payload, path: config.jsonPath)
        if case .auto = config.display, let explicit = explicitItems(value) { return explicit }
        let label = config.name
        switch config.display {
        case .auto: return infer(value, label: label, fields: fieldList(config), depth: 0)
        case .stat:
            if let d = value as? [String: Any] { return statsFromDict(d, fields: fieldList(config)) }
            return [stat(label, value)]
        case .chart: return chart(value, label: nil).map { [$0] } ?? [text(pretty(value), style: "mono")]
        case .list:
            if let a = value as? [Any] { return [list(a, label: nil)] }
            if let d = value as? [String: Any] {
                return [WidgetItem(kind: .list(ListSpec(label: nil, rows: d.sorted { $0.key < $1.key }.map {
                    ListRow(title: $0.key, value: scalarText($0.value))
                }, limit: 50)))]
            }
            return [text(pretty(value), style: "mono")]
        case .text: return [text(value is String ? value as! String : pretty(value), style: value is String ? "body" : "mono")]
        }
    }

    /// The documented format: {"items":[{type:…}]}, [{type:…}], or a single {type:…}.
    static func explicitItems(_ value: Any) -> [WidgetItem]? {
        var raw: [[String: Any]]?
        func known(_ i: [String: Any]) -> Bool { types.contains((i["type"] as? String) ?? "") }
        if let d = value as? [String: Any], let items = d["items"] as? [[String: Any]], items.contains(where: known) {
            raw = items   // unknown item types are skipped, not fatal
        } else if let a = value as? [[String: Any]], !a.isEmpty, a.allSatisfy(known) { raw = a }
        else if let d = value as? [String: Any], types.contains((d["type"] as? String) ?? "") { raw = [d] }
        return raw?.compactMap(item)
    }

    static func item(_ d: [String: Any]) -> WidgetItem? {
        switch d.str("type") ?? "" {
        case "stat":
            return WidgetItem(kind: .stat(StatSpec(
                label: d.str("label") ?? "", value: number(d["value"]),
                text: number(d["value"]) == nil ? d.str("value") : nil,
                format: d.str("format") ?? "number", currency: d.str("currency") ?? "USD",
                decimals: d["decimals"] as? Int, unit: d.str("unit"),
                delta: number(d["delta"]), positiveIsGood: (d["positiveIsGood"] as? Bool) ?? true,
                caption: d.str("caption"), color: d.str("color"),
                sparkline: (d["sparkline"] as? [Any])?.compactMap(number) ?? [])))
        case "chart":
            var series: [ChartSeries] = (d["series"] as? [[String: Any]] ?? []).map {
                ChartSeries(name: $0.str("name") ?? "", color: $0.str("color"), points: points($0["points"] ?? $0["data"] ?? []))
            }
            if series.isEmpty, let pts = d["points"] ?? d["data"] {
                series = [ChartSeries(name: d.str("label") ?? "", color: d.str("color"), points: points(pts))]
            }
            return WidgetItem(kind: .chart(ChartSpec(
                label: d.str("label"), kind: d.str("kind") ?? "line", series: series,
                format: d.str("format") ?? "number", currency: d.str("currency") ?? "USD",
                height: number(d["height"]) ?? 110)))
        case "list":
            let rows = (d["rows"] as? [[String: Any]] ?? []).map {
                ListRow(title: $0.str("title") ?? "", subtitle: $0.str("subtitle"),
                        value: $0["value"].map(scalarText), valueColor: $0.str("valueColor"),
                        icon: $0.str("icon"), url: $0.str("url"))
            }
            return WidgetItem(kind: .list(ListSpec(label: d.str("label"), rows: rows, limit: (d["limit"] as? Int) ?? 10)))
        case "text":
            return WidgetItem(kind: .text(TextSpec(text: d.str("text") ?? "", style: d.str("style") ?? "body", color: d.str("color"))))
        case "progress":
            var v = number(d["value"]) ?? 0
            if let max = number(d["max"]), max > 0 { v /= max }
            return WidgetItem(kind: .progress(ProgressSpec(label: d.str("label") ?? "", value: min(max(v, 0), 1),
                                                           caption: d.str("caption"), color: d.str("color"))))
        case "status":
            return WidgetItem(kind: .status(StatusSpec(label: d.str("label") ?? "", state: d.str("state") ?? "info", detail: d.str("detail"))))
        default: return nil
        }
    }

    // MARK: inference

    static func infer(_ value: Any, label: String, fields: [String], depth: Int) -> [WidgetItem] {
        if isBool(value) {
            let b = (value as? Bool) ?? false
            return [WidgetItem(kind: .status(StatusSpec(label: label, state: b ? "ok" : "error", detail: b ? "true" : "false")))]
        }
        if number(value) != nil && !(value is String) { return [stat(label, value)] }
        if let s = value as? String { return [text(s, style: s.contains("\n") ? "mono" : "body")] }
        if let a = value as? [Any] {
            if a.isEmpty { return [text("Empty list", style: "caption")] }
            if let c = chart(a, label: depth > 0 ? label : nil) { return [c] }
            return [list(a, label: depth > 0 ? label : nil)]
        }
        if let d = value as? [String: Any] {
            var out = statsFromDict(d, fields: fields)
            guard depth < 2 else { return out }
            for (k, v) in d.sorted(by: { $0.key < $1.key }) where (v is [Any] || v is [String: Any]) {
                if !fields.isEmpty && !fields.contains(k) { continue }
                if let sub = v as? [String: Any], sub.values.allSatisfy({ isScalar($0) }) {
                    out.append(WidgetItem(kind: .text(TextSpec(text: humanize(k), style: "caption"))))
                }
                out += infer(v, label: humanize(k), fields: [], depth: depth + 1)
            }
            return out
        }
        return [text(pretty(value), style: "mono")]
    }

    static func statsFromDict(_ d: [String: Any], fields: [String]) -> [WidgetItem] {
        let keys = fields.isEmpty ? d.keys.sorted() : fields.filter { d[$0] != nil }
        return keys.compactMap { k in
            guard let v = d[k], isScalar(v) else { return nil }
            return stat(humanize(k), v)
        }
    }

    static let dateKeys = ["date", "day", "time", "timestamp", "ts", "x", "period", "month", "created_at", "createdAt"]

    /// Arrays of numbers, [{date, n1, n2…}] or [[x, y]] become charts.
    static func chart(_ value: Any, label: String?) -> WidgetItem? {
        guard let a = value as? [Any], !a.isEmpty else { return nil }
        if a.allSatisfy({ number($0) != nil && !($0 is String) }) {
            let pts = a.enumerated().map { ChartPoint(label: "\($0.offset + 1)", y: number($0.element)!) }
            return WidgetItem(kind: .chart(ChartSpec(label: label, kind: "line", series: [ChartSeries(name: label ?? "", points: pts)])))
        }
        if let pairs = a as? [[Any]], pairs.allSatisfy({ $0.count == 2 && number($0[1]) != nil }) {
            return WidgetItem(kind: .chart(ChartSpec(label: label, series: [ChartSeries(name: label ?? "", points: points(pairs))])))
        }
        guard let rows = a as? [[String: Any]], let first = rows.first,
              let xKey = dateKeys.first(where: { first[$0] != nil }) ?? first.keys.sorted().first(where: { first[$0] is String && parseDate(first[$0]) != nil })
        else { return nil }
        let yKeys = first.keys.filter { $0 != xKey && number(first[$0]) != nil && !isBool(first[$0]!) }.sorted()
        guard !yKeys.isEmpty else { return nil }
        let series = yKeys.map { y in
            ChartSeries(name: humanize(y), points: rows.compactMap { r in
                guard let v = number(r[y]) else { return nil }
                let x = r[xKey].map(scalarText) ?? ""
                return ChartPoint(label: x, date: parseDate(r[xKey]), y: v)
            })
        }
        return WidgetItem(kind: .chart(ChartSpec(label: label, kind: rows.count > 40 ? "area" : "line", series: series)))
    }

    static func list(_ a: [Any], label: String?) -> WidgetItem {
        let titleKeys = ["title", "name", "label", "key", "id"]
        let rows: [ListRow] = a.map { el in
            guard let d = el as? [String: Any] else { return ListRow(title: scalarText(el)) }
            let tk = titleKeys.first { d[$0] != nil } ?? d.keys.sorted().first { d[$0] is String }
            let title = tk.flatMap { d[$0] }.map(scalarText) ?? "—"
            let sub = d.keys.sorted().first { $0 != tk && d[$0] is String && !(($0 == "url") || ($0 == "icon")) }
            let val = d.keys.sorted().first { $0 != tk && number(d[$0]) != nil && !(d[$0] is String) && !isBool(d[$0]!) }
            return ListRow(title: title, subtitle: sub.flatMap { d[$0] as? String },
                           value: val.flatMap { d[$0] }.map(scalarText),
                           icon: d.str("icon") ?? d.str("image") ?? d.str("avatar_url"),
                           url: d.str("url") ?? d.str("html_url") ?? d.str("link"))
        }
        return WidgetItem(kind: .list(ListSpec(label: label, rows: rows, limit: 10)))
    }

    // MARK: helpers

    static func points(_ raw: Any) -> [ChartPoint] {
        if let objs = raw as? [[String: Any]] {
            return objs.compactMap { o in
                let x = o["x"] ?? o["date"] ?? o["label"] ?? ""
                guard let y = number(o["y"] ?? o["value"]) else { return nil }
                return ChartPoint(label: scalarText(x), date: parseDate(x), y: y)
            }
        }
        if let pairs = raw as? [[Any]] {
            return pairs.compactMap { p in
                guard p.count >= 2, let y = number(p[1]) else { return nil }
                return ChartPoint(label: scalarText(p[0]), date: parseDate(p[0]), y: y)
            }
        }
        if let nums = raw as? [Any] {
            return nums.enumerated().compactMap { i, v in number(v).map { ChartPoint(label: "\(i + 1)", y: $0) } }
        }
        return []
    }

    static func stat(_ label: String, _ v: Any) -> WidgetItem {
        if let n = number(v) { return WidgetItem(kind: .stat(StatSpec(label: label, value: n))) }
        return WidgetItem(kind: .stat(StatSpec(label: label, text: scalarText(v))))
    }

    static func text(_ s: String, style: String) -> WidgetItem {
        WidgetItem(kind: .text(TextSpec(text: s, style: style)))
    }

    static func select(_ json: Any, path: String) -> Any {
        var cur = json
        for part in path.split(separator: ".").map(String.init) where !part.isEmpty {
            if let d = cur as? [String: Any], let next = d[part] { cur = next }
            else if let a = cur as? [Any], let i = Int(part), a.indices.contains(i) { cur = a[i] }
            else if let a = cur as? [Any], let i = Int(part), i < 0, a.count + i >= 0 { cur = a[a.count + i] }
            else { return NSNull() }
        }
        return cur
    }

    static func fieldList(_ c: WidgetConfig) -> [String] {
        c.fields.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func isScalar(_ v: Any) -> Bool { v is String || v is NSNumber || v is NSNull }

    static func number(_ v: Any?) -> Double? {
        guard let v else { return nil }
        if let n = v as? NSNumber, !isBool(n) { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func scalarText(_ v: Any) -> String {
        if isBool(v) { return (v as? Bool) == true ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if let s = v as? String { return s }
        if v is NSNull { return "—" }
        return pretty(v)
    }

    static let isoFull = ISO8601DateFormatter()
    static func parseDate(_ v: Any?) -> Date? {
        if let s = v as? String {
            if let d = isoFull.date(from: s) { return d }
            if s.count == 10, let d = DayFormat.date(s) { return d }
            if s.count == 7, let d = DayFormat.date(s + "-01") { return d }
            return nil
        }
        if let n = v as? NSNumber, !isBool(n) {
            let t = n.doubleValue
            if t > 1_000_000_000_000 { return Date(timeIntervalSince1970: t / 1000) }   // ms epoch
            if t > 1_000_000_000 { return Date(timeIntervalSince1970: t) }
        }
        return nil
    }

    static func humanize(_ key: String) -> String {
        var s = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        s = s.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func pretty(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) else {
            return "\(v)"
        }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Fetching

enum WidgetFetcher {
    /// Returns parsed JSON, or the raw string when the output isn't JSON.
    static func fetch(_ c: WidgetConfig, headers: String? = nil) async throws -> (payload: Any, raw: Data) {
        let (headerLines, secrets) = splitHeaders(headers ?? c.headers)
        let data: Data
        switch c.source {
        case .http:
            let url = expand(c.url.trimmingCharacters(in: .whitespaces), secrets: secrets, urlEncode: true)
            guard let u = URL(string: url), u.scheme != nil else { throw SideStatsError("Invalid URL") }
            var req = URLRequest(url: u)
            req.httpMethod = c.method
            req.timeoutInterval = 30
            if !c.body.isEmpty {
                req.httpBody = Data(expand(c.body, secrets: secrets).utf8)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            for (k, v) in headerLines { req.setValue(expand(v, secrets: secrets), forHTTPHeaderField: k) }
            (data, _) = try await HTTP.data(req)
        case .command:
            data = try await run(expand(c.command), env: secrets)
        case .push:
            // Push widgets get data from the local API / MCP; "fetch" returns the last pushed payload.
            guard let d = try? Data(contentsOf: Storage.dir.appendingPathComponent("widget-\(c.id).raw")) else {
                throw SideStatsError("No data pushed yet. Send it with the SideStats API or MCP (id: \(c.id)).")
            }
            data = d
        }
        return (decode(data), data)
    }

    /// Splits "Name: value" lines into real headers and secrets. Lines whose name starts with `$`
    /// (e.g. `$api_key: abc`) are secrets: `{{$api_key}}` in URLs/bodies/headers, `$api_key` in commands.
    static func splitHeaders(_ text: String) -> (headers: [(String, String)], secrets: [String: String]) {
        var headers: [(String, String)] = [], secrets: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            if parts[0].hasPrefix("$") { secrets[String(parts[0].dropFirst())] = parts[1] } else { headers.append((parts[0], parts[1])) }
        }
        return (headers, secrets)
    }

    static func expand(_ s: String, secrets: [String: String], urlEncode: Bool = false) -> String {
        var out = expand(s)
        for (k, v) in secrets where out.contains("{{$\(k)}}") {
            let value = urlEncode ? (v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? v) : v
            out = out.replacingOccurrences(of: "{{$\(k)}}", with: value)
        }
        return out
    }

    static func decode(_ data: Data) -> Any {
        if let j = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return j }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Placeholders usable in URLs, bodies and commands: {{today}}, {{daysAgo:30}}, {{monthStart}}.
    static func expand(_ s: String) -> String {
        guard s.contains("{{") else { return s }
        var out = s.replacingOccurrences(of: "{{today}}", with: DayFormat.daysAgo(0))
        out = out.replacingOccurrences(of: "{{monthStart}}", with: DateRangeOption.mtd.dates().start)
        while let r = out.range(of: #"\{\{daysAgo:(\d+)\}\}"#, options: .regularExpression) {
            let n = Int(out[r].filter(\.isNumber)) ?? 0
            out.replaceSubrange(r, with: DayFormat.daysAgo(n))
        }
        return out
    }

    static func run(_ command: String, env: [String: String] = [:]) async throws -> Data {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            if !env.isEmpty {
                p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let pid = p.processIdentifier
            let timer = DispatchWorkItem {
                guard p.isRunning else { return }
                let k = Process()   // children first, so the pipe closes
                k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                k.arguments = ["-TERM", "-P", "\(pid)"]
                try? k.run(); k.waitUntilExit()
                p.terminate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            if p.terminationStatus != 0 && data.isEmpty {
                let msg = String(decoding: errData.prefix(400), as: UTF8.self)
                throw SideStatsError("Command exited with \(p.terminationStatus): \(msg)")
            }
            return data
        }.value
    }
}

// MARK: - Store

struct WidgetState {
    var items: [WidgetItem] = []
    var loading = false
    var error: String?
    var updated: Date?
}

@MainActor
final class WidgetStore: ObservableObject {
    static let revenueModule = "builtin.revenue"
    static let tasksModule = "builtin.tasks"
    static let builtinModules = [revenueModule, tasksModule]
    static func builtinTitle(_ id: String) -> String? {
        switch id {
        case revenueModule: return "Apps & Revenue"
        case tasksModule: return "Tasks"
        default: return nil
        }
    }
    static func builtinIcon(_ id: String) -> String {
        id == tasksModule ? "checklist" : "dollarsign.circle"
    }

    @Published var widgets: [WidgetConfig] { didSet { save(); syncLayout(); if widgets != oldValue { reparse(changed: oldValue) } } }
    @Published var layout: [String] { didSet { UserDefaults.standard.set(layout, forKey: "layout") } }
    @Published var collapsed: Set<String> { didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") } }
    @Published var hidden: Set<String> { didSet { UserDefaults.standard.set(Array(hidden), forKey: "hiddenModules") } }
    @Published private(set) var states: [String: WidgetState] = [:]

    private var raw: [String: Data] = [:]
    private var timer: Timer?

    init() {
        let d = UserDefaults.standard
        widgets = (d.data(forKey: "widgets").flatMap { try? JSONDecoder().decode([WidgetConfig].self, from: $0) }) ?? []
        layout = d.stringArray(forKey: "layout") ?? [Self.revenueModule]
        collapsed = Set(d.stringArray(forKey: "collapsed") ?? [])
        hidden = Set(d.stringArray(forKey: "hiddenModules") ?? [])
        syncLayout()
        for w in widgets {
            if let data = try? Data(contentsOf: Storage.dir.appendingPathComponent("widget-\(w.id).raw")) {
                raw[w.id] = data
                states[w.id] = WidgetState(items: (try? WidgetParser.process(WidgetFetcher.decode(data), config: w)) ?? [])
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDue() }
        }
        refreshDue()
    }

    /// Modules in display order, excluding hidden and disabled ones.
    var visibleModules: [String] {
        layout.filter { id in
            !hidden.contains(id) && (Self.builtinModules.contains(id) || widgets.first { $0.id == id }?.enabled == true)
        }
    }

    func widget(_ id: String) -> WidgetConfig? { widgets.first { $0.id == id } }

    private func save() {
        if let d = try? JSONEncoder().encode(widgets) { UserDefaults.standard.set(d, forKey: "widgets") }
    }

    private func syncLayout() {
        let valid = Set(widgets.map(\.id) + Self.builtinModules)
        var l = layout.filter { valid.contains($0) }
        for id in Self.builtinModules + widgets.map(\.id) where !l.contains(id) { l.append(id) }
        if l != layout { layout = l }
    }

    /// When display settings change, re-render from the cached payload without refetching.
    private func reparse(changed old: [WidgetConfig]) {
        for w in widgets {
            guard let prev = old.first(where: { $0.id == w.id }), prev != w, let data = raw[w.id] else { continue }
            if w.source != .push && (prev.url != w.url || prev.command != w.command || prev.source != w.source || prev.body != w.body) {
                refresh(w.id); continue
            }
            do {
                states[w.id, default: .init()].items = try WidgetParser.process(WidgetFetcher.decode(data), config: w)
                states[w.id]?.error = nil
            } catch { states[w.id, default: .init()].error = error.localizedDescription }
        }
    }

    func refreshDue() {
        for w in widgets where w.enabled && w.source != .push && !(states[w.id]?.loading ?? false) {
            let last = states[w.id]?.updated ?? .distantPast
            if Date().timeIntervalSince(last) >= Double(max(w.refreshSeconds, 5)) { refresh(w.id) }
        }
    }

    func refreshAll() { for w in widgets where w.enabled { refresh(w.id) } }

    func refresh(_ id: String) {
        guard let w = widget(id), w.source != .push else { return }
        states[id, default: .init()].loading = true
        Task {
            do {
                let (payload, data) = try await WidgetFetcher.fetch(w)
                raw[id] = data
                try? data.write(to: Storage.dir.appendingPathComponent("widget-\(id).raw"))
                let current = widget(id) ?? w
                states[id] = WidgetState(items: try WidgetParser.process(payload, config: current), updated: Date())
            } catch {
                var s = states[id] ?? .init()
                s.loading = false; s.error = error.localizedDescription; s.updated = Date()
                states[id] = s
            }
        }
    }

    /// Push data into a widget (used by the local API / MCP for `.push` widgets, but works for any).
    /// `payload` is any JSON value: SideStats format or plain data.
    func push(_ id: String, payload: Any) throws {
        guard let w = widget(id) else { throw SideStatsError("No widget with id \(id)") }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let items = try WidgetParser.process(payload, config: w)
        raw[id] = data
        try? data.write(to: Storage.dir.appendingPathComponent("widget-\(id).raw"))
        states[id] = WidgetState(items: items, updated: Date())
    }

    /// Adds a widget and returns it (fresh id unless one is given and unused).
    @discardableResult
    func add(_ w: WidgetConfig) -> WidgetConfig {
        var w = w
        if w.id.isEmpty || widgets.contains(where: { $0.id == w.id }) { w.id = UUID().uuidString }
        widgets.append(w)
        if w.source != .push { refresh(w.id) }
        return w
    }

    func remove(_ id: String) {
        widgets.removeAll { $0.id == id }
        Keychain.set("widget.headers.\(id)", nil)
        Storage.remove("widget-\(id).raw")
        states[id] = nil
    }

    func move(_ id: String, by offset: Int) {
        guard let i = layout.firstIndex(of: id) else { return }
        let j = min(max(i + offset, 0), layout.count - 1)
        guard i != j else { return }
        layout.swapAt(i, j)
    }

    // MARK: sharing

    /// Shareable JSON (headers are secrets and are never exported).
    func export(_ id: String) -> String? {
        guard var w = widget(id) else { return nil }
        w.id = ""
        guard let d = try? JSONEncoder().encode(w),
              var obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        obj["id"] = nil
        obj["sidestats"] = 1
        return WidgetParser.pretty(obj)
    }

    /// Parses one widget or an array of widgets from JSON text. Fresh ids are assigned.
    static func decodeImport(_ text: String) throws -> [WidgetConfig] {
        let data = Data(text.utf8)
        var list: [WidgetConfig]
        if let arr = try? JSONDecoder().decode([WidgetConfig].self, from: data) { list = arr }
        else { list = [try JSONDecoder().decode(WidgetConfig.self, from: data)] }
        for i in list.indices { list[i].id = UUID().uuidString }
        return list
    }
}
