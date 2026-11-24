import Foundation

/// A ready-made integration (Grafana, Prometheus, Uptime Kuma, …) that becomes a widget after
/// the user fills a few parameters. The catalog lives in `Preset*.swift`, one file per category.
///
/// Templates may reference parameters as `{{id}}` (raw), `{{id:url}}` (percent-encoded for a URL
/// query value), `{{id:sh}}` (single-quoted for the shell) or `{{id:js}}` (a JSON/JavaScript string
/// literal, for bodies and transforms). Anything else in braces (`{{today}}`, `{{daysAgo:7}}`,
/// Docker's `{{json .}}`) is left alone, so fetch-time placeholders keep working.
struct PresetParam: Identifiable, Codable {
    var id: String              // used as {{id}} in the template (snake/camel case, no spaces)
    var label: String
    var placeholder = ""
    var help = ""
    var secret = false          // secret params are only used in headers (stored in Keychain)
    var optional = false
    var defaultValue = ""
    var options: [String] = []  // when non-empty, the value must be one of these (shown as a picker)
}

extension PresetParam {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
        help = try c.decodeIfPresent(String.self, forKey: .help) ?? ""
        secret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
        optional = try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
    }
}

struct WidgetPreset: Identifiable {
    var id: String              // stable kebab-case, e.g. "grafana-alerts"
    var name: String
    var category: String        // one of WidgetPresets.categories
    var icon: String            // SF Symbol
    var summary: String
    var params: [PresetParam]
    var template: WidgetConfig  // fields may contain {{param}}
    var headers = ""            // header template, may contain {{param}}; lines with an empty param are dropped
    var docs = ""
    /// What credentials or tools it needs, one short line ("API token with read scope", "Docker CLI").
    var requires = "Nothing"
    /// Optional extra values computed from the filled params (e.g. a query-string fragment).
    var derive: (([String: String]) -> [String: String])? = nil
    /// A realistic raw response used for offline previews and tests (JSON or command text).
    var sample = ""
}

enum WidgetPresets {
    static let categories = ["Monitoring", "Servers", "Dev", "Business", "Other"]

    static let all: [WidgetPreset] = monitoring + servers + dev + business + other

    static func preset(_ id: String) -> WidgetPreset? { all.first { $0.id == id } }

    /// Fills a preset's template. Returns the widget and its header lines (to store in the Keychain).
    static func make(_ id: String, params: [String: String]) throws -> (config: WidgetConfig, headers: String) {
        guard let p = preset(id) else { throw SideStatsError("Unknown preset \(id)") }
        var values: [String: String] = [:]
        for param in p.params {
            var v = (params[param.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { v = param.defaultValue }
            if v.isEmpty && !param.optional { throw SideStatsError("Missing parameter “\(param.label)” (\(param.id))") }
            if !param.options.isEmpty, !v.isEmpty, !param.options.contains(v) {
                throw SideStatsError("“\(param.label)” must be one of: \(param.options.joined(separator: ", "))")
            }
            if v.hasPrefix("http://") || v.hasPrefix("https://") { while v.hasSuffix("/") { v.removeLast() } }
            values[param.id] = v
        }
        if let derive = p.derive { values.merge(derive(values)) { _, new in new } }

        var c = p.template
        c.id = UUID().uuidString
        c.name = fill(c.name, values); c.url = fill(c.url, values); c.body = fill(c.body, values)
        c.command = fill(c.command, values); c.jsonPath = fill(c.jsonPath, values); c.fields = fill(c.fields, values)
        c.transform = fill(c.transform, values)
        c.preset = p.id
        let headers = p.headers.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let line = String(line)
            let refs = references(in: line)
            if refs.contains(where: { (values[$0] ?? "").isEmpty }) { return nil }
            return fill(line, values)
        }.joined(separator: "\n")
        return (c, headers)
    }

    // MARK: template filling

    private static let token = try! NSRegularExpression(pattern: #"\{\{([A-Za-z0-9_]+)(?::(url|sh|js))?\}\}"#)

    /// Parameter ids referenced in a template string (only `{{id}}` / `{{id:filter}}` forms).
    static func references(in s: String) -> [String] {
        token.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    static func fill(_ s: String, _ values: [String: String]) -> String {
        guard s.contains("{{") else { return s }
        var out = ""
        var last = s.startIndex
        for m in token.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s), let keyR = Range(m.range(at: 1), in: s),
                  let value = values[String(s[keyR])] else { continue }   // unknown → leave as-is
            let filter = Range(m.range(at: 2), in: s).map { String(s[$0]) }
            out += s[last..<whole.lowerBound]
            out += encode(value, filter)
            last = whole.upperBound
        }
        out += s[last...]
        return out
    }

    static func encode(_ v: String, _ filter: String?) -> String {
        switch filter {
        case "url":
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
        case "sh":
            return "'" + v.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        case "js":
            let d = (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
            return String(decoding: d, as: UTF8.self)
        default:
            return v
        }
    }

    // MARK: building blocks for the catalog

    static func http(_ name: String, icon: String, url: String, method: String = "GET", body: String = "",
                     refresh: Int = 300, transform: String) -> WidgetConfig {
        var c = WidgetConfig()
        c.id = ""; c.name = name; c.icon = icon; c.source = .http
        c.url = url; c.method = method; c.body = body
        c.refreshSeconds = refresh; c.transform = transform
        return c
    }

    static func command(_ name: String, icon: String, command: String, refresh: Int = 60, transform: String) -> WidgetConfig {
        var c = WidgetConfig()
        c.id = ""; c.name = name; c.icon = icon; c.source = .command
        c.command = command; c.refreshSeconds = refresh; c.transform = transform
        return c
    }
}
