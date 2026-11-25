import SwiftUI

/// Monospaced text editor with a placeholder, used for JSON / code fields in Settings.
struct CodeField: View {
    @Binding var text: String
    var placeholder = ""
    var minHeight: CGFloat = 60

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .autocorrectionDisabled()
            .frame(minHeight: minHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Ready-to-copy JSON examples for every widget item type, with a live preview.
struct FormatExample: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var icon: String
    var note: String
    var json: String

    static let all: [FormatExample] = [
        FormatExample(name: "Stats", icon: "number", note: "Numbers with format, change (delta) and sparkline. 2–4 stats look best.", json: """
        {
          "items": [
            { "type": "stat", "label": "MRR", "value": 12840, "format": "currency", "currency": "USD",
              "delta": 0.12, "sparkline": [9800, 10400, 11500, 12840] },
            { "type": "stat", "label": "Churn", "value": 0.031, "format": "percent", "positiveIsGood": false, "delta": -0.004 },
            { "type": "stat", "label": "Active users", "value": 1284 },
            { "type": "stat", "label": "Latency", "value": 182, "unit": "ms", "caption": "p95" }
          ]
        }
        """),
        FormatExample(name: "Line / area chart", icon: "chart.xyaxis.line", note: "Dates on x become a time axis. Several series = several lines.", json: """
        {
          "items": [
            { "type": "chart", "label": "Revenue vs spend", "kind": "line", "format": "currency",
              "series": [
                { "name": "Revenue", "color": "green",
                  "points": [["2026-11-18", 120], ["2026-11-19", 160], ["2026-11-20", 140], ["2026-11-21", 210], ["2026-11-22", 190]] },
                { "name": "Spend", "color": "red",
                  "points": [["2026-11-18", 60], ["2026-11-19", 70], ["2026-11-20", 90], ["2026-11-21", 80], ["2026-11-22", 75]] }
              ] }
          ]
        }
        """),
        FormatExample(name: "Bar chart", icon: "chart.bar", note: "Points can be [x, y] pairs, {x, y} objects or plain numbers.", json: """
        {
          "items": [
            { "type": "chart", "label": "Installs per store", "kind": "bar",
              "points": [ { "x": "App Store", "y": 420 }, { "x": "Google Play", "y": 610 }, { "x": "Web", "y": 95 } ] }
          ]
        }
        """),
        FormatExample(name: "Pie / donut", icon: "chart.pie", note: "Share of a whole; uses the first series.", json: """
        {
          "items": [
            { "type": "chart", "label": "Revenue by network", "kind": "donut", "format": "currency",
              "points": [ ["AdMob", 820], ["AppLovin", 540], ["Unity", 210], ["IAP", 390] ] }
          ]
        }
        """),
        FormatExample(name: "List", icon: "list.bullet", note: "Rows with title, subtitle, value, icon (sf:name or image URL) and a click URL.", json: """
        {
          "items": [
            { "type": "list", "label": "Top apps today", "rows": [
              { "title": "Puzzle Pop", "subtitle": "iOS · 1.2k installs", "value": "$214", "valueColor": "green", "icon": "sf:puzzlepiece.fill" },
              { "title": "Habit Owl", "subtitle": "Android", "value": "$96", "icon": "sf:bird.fill" },
              { "title": "Open dashboard", "subtitle": "example.com", "icon": "sf:link", "url": "https://example.com" }
            ] }
          ]
        }
        """),
        FormatExample(name: "Status", icon: "checkmark.circle", note: "Health lights: ok, warn, error, info (also up/down/true/false).", json: """
        {
          "items": [
            { "type": "status", "label": "API", "state": "ok", "detail": "99.98% · 120 ms" },
            { "type": "status", "label": "Worker queue", "state": "warn", "detail": "1.2k jobs waiting" },
            { "type": "status", "label": "Backup", "state": "error", "detail": "failed 2h ago" }
          ]
        }
        """),
        FormatExample(name: "Progress", icon: "gauge.with.dots.needle.33percent", note: "value 0…1, or a raw value with max. Turns red above 90%.", json: """
        {
          "items": [
            { "type": "progress", "label": "Monthly goal", "value": 7400, "max": 10000, "caption": "$7,400 of $10,000" },
            { "type": "progress", "label": "Disk", "value": 0.93 }
          ]
        }
        """),
        FormatExample(name: "Text", icon: "text.alignleft", note: "Markdown text in title, body, caption or mono style.", json: """
        {
          "items": [
            { "type": "text", "text": "Release 2.4 is live 🎉", "style": "title" },
            { "type": "text", "text": "**Crash-free:** 99.7% · [changelog](https://example.com)" },
            { "type": "text", "text": "build 2411 · main@4e81970", "style": "mono" }
          ]
        }
        """),
        FormatExample(name: "Plain JSON (auto)", icon: "wand.and.stars", note: "Any JSON works: objects become stats, arrays with dates become charts, other arrays become lists.", json: """
        {
          "users": 1284,
          "plan": "pro",
          "conversion": "0.043",
          "daily": [
            { "date": "2026-11-20", "signups": 12, "trials": 30 },
            { "date": "2026-11-21", "signups": 18, "trials": 41 },
            { "date": "2026-11-22", "signups": 15, "trials": 37 }
          ]
        }
        """),
    ]
}

/// Sheet: pick an example, edit the JSON, see it rendered, copy it or add it as a module.
struct FormatExamplesSheet: View {
    @EnvironmentObject var widgets: WidgetStore
    @Environment(\.dismiss) private var dismiss
    var onAdd: (String) -> Void = { _ in }

    @State private var selected = FormatExample.all[0]
    @State private var json = FormatExample.all[0].json
    @State private var name = FormatExample.all[0].name

    private var parsed: (items: [WidgetItem], error: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else {
            return ([], "Invalid JSON")
        }
        var cfg = WidgetConfig(); cfg.name = name
        do { return (try WidgetParser.process(obj, config: cfg), nil) } catch { return ([], error.localizedDescription) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                List(FormatExample.all, selection: Binding(get: { selected }, set: {
                    if let e = $0 { selected = e; json = e.json; name = e.name }
                })) { e in
                    Label(e.name, systemImage: e.icon).tag(e)
                }
                .listStyle(.sidebar).frame(width: 170)

                VStack(alignment: .leading, spacing: 8) {
                    Text(selected.note).font(.callout).foregroundStyle(.secondary)
                    CodeField(text: $json, minHeight: 200)
                        .padding(6)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Copy JSON") { Pasteboard.copy(json) }
                        Button("Copy curl (push)") {
                            let compact = (try? JSONSerialization.jsonObject(with: Data(json.utf8)))
                                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                                .map { String(decoding: $0, as: UTF8.self) } ?? json
                            Pasteboard.copy("curl -X POST \(LocalAPIServer.baseURL)/v1/widgets/<WIDGET_ID>/data \\\n  -H 'Authorization: Bearer \(LocalAPIServer.shared?.token ?? "<token>")' \\\n  -H 'Content-Type: application/json' \\\n  -d '\(compact.replacingOccurrences(of: "'", with: "'\\''"))'")
                        }
                        .help("Copies a curl command with your local API token")
                        Spacer()
                        Link("Full reference ↗", destination: URL(string: Links.repo + "/blob/main/WIDGETS.md")!)
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: .infinity)

                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PREVIEW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        let p = parsed
                        if let e = p.error { Text(e).font(.caption).foregroundStyle(.red) }
                        else if p.items.isEmpty { Text("Nothing to show").font(.caption).foregroundStyle(.secondary) }
                        WidgetItemsView(items: p.items)
                            .padding(10)
                            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(12)
                }
                .frame(width: 300)
            }
            Divider()
            HStack {
                TextField("Module name", text: $name).frame(width: 200)
                Text("Adds a push module with this data; update it later via API / MCP.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add as module") { add() }.buttonStyle(.borderedProminent).disabled(parsed.items.isEmpty)
            }
            .padding(10)
        }
        .frame(width: 860, height: 520)
    }

    private func add() {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else { return }
        var w = WidgetConfig()
        w.name = name.isEmpty ? selected.name : name
        w.icon = selected.icon
        w.source = .push
        let added = widgets.add(w)
        try? widgets.push(added.id, payload: obj)
        onAdd(added.id)
        dismiss()
    }
}
