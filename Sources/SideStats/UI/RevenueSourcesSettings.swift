import SwiftUI

/// Settings → Custom: any API / script / pushed JSON as a revenue & ad spend source for Apps & Revenue.
struct RevenueSourcesSettings: View {
    @EnvironmentObject var store: MetricsStore
    @State private var selection: String?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.config.revenueSources) { s in
                        HStack {
                            Image(systemName: RevenuePreset.preset(s.preset)?.icon ?? s.icon).frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name).lineLimit(1)
                                Text(s.source.title).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !s.enabled { Image(systemName: "pause.circle").foregroundStyle(.tertiary) }
                        }
                        .tag(s.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Menu {
                        ForEach(RevenuePreset.all) { p in
                            Button { add(p) } label: { Label(p.name, systemImage: p.icon) }
                        }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().frame(width: 30)
                    Spacer()
                }
                .padding(6)
            }
            .frame(minWidth: 190, idealWidth: 200, maxWidth: 240)

            Group {
                if let id = selection, let s = store.config.revenueSources.first(where: { $0.id == id }) {
                    RevenueSourceEditor(original: s, onDelete: { selection = nil }).id(s.id)
                } else {
                    intro
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Custom revenue sources").font(.title3.weight(.semibold))
                Text("Bring any ad network, store, backend or spreadsheet into Apps & Revenue. A source returns daily rows; rows with the same app name are merged with App Store, Play, AdMob and ad spend data.")
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(RevenuePreset.all) { p in
                        Button { add(p) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(p.name, systemImage: p.icon).font(.callout.weight(.semibold))
                                Text(p.summary).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                            .padding(10)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                RevenueFormatBox()
            }
            .padding(16)
        }
    }

    private func add(_ p: RevenuePreset) {
        let s = p.make()
        if !p.headers.isEmpty { s.headers = p.headers }
        store.config.revenueSources.append(s)
        selection = s.id
    }
}

/// The rows format with copy buttons, shown in the intro and the editor.
struct RevenueFormatBox: View {
    @State private var showFields = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Format").font(.headline)
                Spacer()
                Button("Copy example") { Pasteboard.copy(RevenueFormat.example) }.controlSize(.small)
            }
            Text(RevenueFormat.example)
                .font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            DisclosureGroup("Field names & aliases", isExpanded: $showFields) {
                Text(RevenueFormat.fieldHelp).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            Text("Also accepted: a bare array of rows, or {data|results|items: [...]}. Different shapes? Map them with a JavaScript transform, e.g. `data => data.report.map(r => ({date: r.day, app: r.title, adRevenue: r.usd}))`.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct RevenueSourceEditor: View {
    @EnvironmentObject var store: MetricsStore
    let original: WidgetConfig
    var onDelete: () -> Void
    @State private var draft: WidgetConfig
    @State private var headers: String
    @State private var originalHeaders: String
    @State private var testing = false
    @State private var error: String?
    @State private var result: ProviderResult?
    @State private var raw = ""

    init(original: WidgetConfig, onDelete: @escaping () -> Void) {
        self.original = original
        self.onDelete = onDelete
        _draft = State(initialValue: original)
        let h = original.headers
        _headers = State(initialValue: h)
        _originalHeaders = State(initialValue: h)
    }

    private var dirty: Bool { draft != original || headers != originalHeaders }
    private var preset: RevenuePreset? { RevenuePreset.preset(draft.preset) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Toggle("Enabled", isOn: $draft.enabled)
                    Picker("Source", selection: $draft.source) {
                        ForEach(WidgetSourceType.allCases) { Text($0.title).tag($0) }
                    }
                    if let p = preset {
                        LabeledContent("Integration") {
                            HStack(spacing: 6) {
                                Text(p.name).foregroundStyle(.secondary)
                                if let u = URL(string: p.docs), !p.docs.isEmpty { Link("Docs ↗", destination: u) }
                            }
                        }
                    }
                } footer: {
                    if let p = preset { Text(p.summary).font(.caption).foregroundStyle(.secondary) }
                }

                switch draft.source {
                case .http:
                    Section {
                        TextField("URL", text: $draft.url, prompt: Text("https://api.example.com/revenue?from={{daysAgo:89}}"))
                        Picker("Method", selection: $draft.method) {
                            ForEach(["GET", "POST", "PUT"], id: \.self) { Text($0).tag($0) }
                        }
                        LabeledContent("Headers & secrets") { CodeField(text: $headers, placeholder: "Authorization: Bearer …\n$api_key: …", minHeight: 44) }
                        if draft.method != "GET" {
                            LabeledContent("Body") { CodeField(text: $draft.body, placeholder: "{\"from\":\"{{daysAgo:89}}\"}", minHeight: 54) }
                        }
                    } header: { Text("Request") } footer: { secretsHelp }
                case .command:
                    Section {
                        CodeField(text: $draft.command, placeholder: "python3 ~/scripts/revenue.py", minHeight: 80)
                        LabeledContent("Secrets") { CodeField(text: $headers, placeholder: "$api_key: …", minHeight: 36) }
                    } header: { Text("Command (zsh)") } footer: {
                        Text("Print the rows JSON to stdout. Secret lines `$name: value` become environment variables ($name). Placeholders: {{today}}, {{daysAgo:N}}, {{monthStart}}. 30 s timeout.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .push:
                    pushSection
                }

                Section {
                    CodeField(text: $draft.transform, placeholder: "data => data.report.map(r => ({ date: r.day, app: r.title, adRevenue: r.usd }))",
                              minHeight: draft.transform.isEmpty ? 40 : 110)
                    TextField("JSON path", text: $draft.jsonPath, prompt: Text("optional, e.g. data.rows"))
                } header: { Text("Mapping") } footer: {
                    Text("Optional. The transform (JavaScript) gets the response as `data` and returns rows; the JSON path then picks the rows array. Many APIs work without either thanks to the field aliases below.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    if testing { ProgressView().controlSize(.small) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if let result { ResultSummary(result: result, base: store.config.baseCurrency) }
                    if !raw.isEmpty {
                        DisclosureGroup("Raw response") {
                            ScrollView { Text(raw).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(height: 140)
                        }
                    }
                } header: {
                    HStack {
                        Text("Test")
                        Spacer()
                        Button("Test") { test() }.controlSize(.small).disabled(testing)
                    }
                }

                Section { RevenueFormatBox() }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(role: .destructive) {
                    store.config.revenueSources.removeAll { $0.id == original.id }
                    original.headers = ""
                    try? FileManager.default.removeItem(at: CustomRevenue.pushPath(original.id))
                    onDelete()
                    Task { await store.refresh(only: [.custom]) }
                } label: { Text("Delete") }
                Spacer()
                if dirty { Button("Revert") { draft = original; headers = originalHeaders } }
                Button("Save") { save() }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(!dirty)
            }
            .padding(10)
        }
        .onAppear { if draft.source != .push || FileManager.default.fileExists(atPath: CustomRevenue.pushPath(draft.id).path) { test() } }
    }

    private var secretsHelp: some View {
        Text("Stored in the Keychain. `Name: value` lines are sent as headers; `$name: value` lines are secrets you can use as {{$name}} in the URL or body (for APIs that take keys in the query). Placeholders: {{today}}, {{daysAgo:N}}, {{monthStart}}.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var pushExample: String {
        """
        curl -X POST \(LocalAPIServer.baseURL)/v1/revenue/data \\
          -H 'Authorization: Bearer <token>' -H 'Content-Type: application/json' \\
          -d '{"source":"\(draft.id)","rows":[{"date":"\(DayFormat.daysAgo(0))","app":"My App","platform":"ios","adRevenue":12.5,"spend":4}]}'
        """
    }

    private var pushSection: some View {
        Section {
            LabeledContent("Source ID") {
                HStack(spacing: 6) {
                    Text(draft.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                    Button { Pasteboard.copy(draft.id) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                }
            }
            Text(pushExample).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy with my token") {
                    Pasteboard.copy(pushExample.replacingOccurrences(of: "<token>", with: LocalAPIServer.shared?.token ?? "<token>"))
                }
            }
            .controlSize(.small)
        } header: { Text("Push") } footer: {
            Text("Each push replaces this source's rows. From Claude: \"push my revenue rows to SideStats\" (MCP tool push_revenue_data).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        if headers != originalHeaders { original.headers = headers; originalHeaders = headers }
        if let i = store.config.revenueSources.firstIndex(where: { $0.id == original.id }) {
            store.config.revenueSources[i] = draft
        }
        Task { await store.refresh(only: [.custom]) }
    }

    private func test() {
        testing = true; error = nil
        let cfg = draft, h = headers
        Task {
            do {
                let (r, data) = try await CustomRevenue.load(cfg, headers: h)
                result = r
                raw = String(decoding: data.prefix(8000), as: UTF8.self)
            } catch {
                self.error = error.localizedDescription
                result = nil
            }
            testing = false
        }
    }
}

/// What a test fetch produced: row count, date span and per-app totals (in the source currency).
private struct ResultSummary: View {
    let result: ProviderResult
    let base: String

    private struct AppLine: Identifiable {
        var id: String; var name: String; var platform: Platform; var currency: String
        var revenue: Double; var spend: Double; var downloads: Int
    }

    private var lines: [AppLine] {
        let names = Dictionary(result.names.map { ($0.app, $0.name) }, uniquingKeysWith: { a, _ in a })
        var m: [String: AppLine] = [:]
        for r in result.rows {
            let k = r.app.id + r.currency
            var l = m[k] ?? AppLine(id: k, name: names[r.app] ?? r.app.storeId, platform: r.app.platform, currency: r.currency, revenue: 0, spend: 0, downloads: 0)
            l.revenue += r.adRevenue + r.iapRevenue; l.spend += r.spend; l.downloads += r.downloads
            m[k] = l
        }
        return m.values.sorted { $0.revenue > $1.revenue }
    }

    var body: some View {
        let dates = result.rows.map(\.date).sorted()
        VStack(alignment: .leading, spacing: 6) {
            Label("\(result.rows.count) rows · \(lines.count) apps · \(dates.first ?? "") → \(dates.last ?? "")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    Text("App"); Text("Revenue"); Text("Spend"); Text("Installs")
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(lines.prefix(12)) { l in
                    GridRow {
                        HStack(spacing: 4) {
                            Text(l.platform.short).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                            Text(l.name).lineLimit(1)
                        }
                        Text(Fmt.money(l.revenue, l.currency)).monospacedDigit()
                        Text(l.spend == 0 ? "—" : Fmt.money(l.spend, l.currency)).monospacedDigit()
                        Text(l.downloads == 0 ? "—" : "\(l.downloads)").monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            Text("Totals are in each row's currency here; the sidebar converts them to \(base).")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
