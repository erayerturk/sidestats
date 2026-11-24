import Foundation

/// A ready-made integration (Grafana, Prometheus, Uptime Kuma, …) that becomes a widget after
/// the user fills a few parameters. (Contract — catalog to be completed.)
struct PresetParam: Identifiable, Codable {
    var id: String              // used as {{id}} in the template
    var label: String
    var placeholder = ""
    var help = ""
    var secret = false          // secret params are only allowed in headers (stored in Keychain)
    var optional = false
    var defaultValue = ""
}

struct WidgetPreset: Identifiable {
    var id: String
    var name: String
    var category: String        // e.g. "Monitoring", "Dev", "Business", "System"
    var icon: String            // SF Symbol
    var summary: String
    var params: [PresetParam]
    var template: WidgetConfig  // fields may contain {{param}}
    var headers = ""            // header template, may contain {{param}}
    var docs = ""
}

enum WidgetPresets {
    static let all: [WidgetPreset] = []

    static func preset(_ id: String) -> WidgetPreset? { all.first { $0.id == id } }

    /// Fills a preset's template. Returns the widget and its header lines (to store in the Keychain).
    static func make(_ id: String, params: [String: String]) throws -> (config: WidgetConfig, headers: String) {
        guard let p = preset(id) else { throw SideStatsError("Unknown preset \(id)") }
        var values: [String: String] = [:]
        for param in p.params {
            let v = params[param.id] ?? param.defaultValue
            if v.isEmpty && !param.optional { throw SideStatsError("Missing parameter \(param.id)") }
            values[param.id] = v
        }
        func fill(_ s: String) -> String {
            values.reduce(s) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
        }
        var c = p.template
        c.id = UUID().uuidString
        c.name = fill(c.name); c.url = fill(c.url); c.body = fill(c.body)
        c.command = fill(c.command); c.jsonPath = fill(c.jsonPath); c.fields = fill(c.fields)
        c.transform = fill(c.transform)
        c.preset = p.id
        return (c, fill(p.headers))
    }
}
