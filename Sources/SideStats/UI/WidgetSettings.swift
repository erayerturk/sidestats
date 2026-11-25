import SwiftUI
import UniformTypeIdentifiers

struct WidgetSettings: View {
    @EnvironmentObject var widgets: WidgetStore
    @State private var selection: String?
    @State private var showImport = false
    @State private var showGallery = false
    @State private var showExamples = false
    @AppStorage("settingsTab") private var tab = SettingsTab.widgets.rawValue

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(widgets.layout, id: \.self) { id in
                        row(id).tag(id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 2) {
                    Menu {
                        Button("Browse integrations…") { showGallery = true }
                        Button("JSON examples…") { showExamples = true }
                        Divider()
                        Button("HTTP API") { add(.http) }
                        Button("Shell command") { add(.command) }
                        Button("Push (API / MCP)") { add(.push) }
                        Divider()
                        Button("Import JSON…") { showImport = true }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().frame(width: 30)
                    Button { if let s = selection { widgets.move(s, by: -1) } } label: { Image(systemName: "arrow.up") }
                        .disabled(selection == nil)
                    Button { if let s = selection { widgets.move(s, by: 1) } } label: { Image(systemName: "arrow.down") }
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 200, idealWidth: 210, maxWidth: 260)

            Group {
                if let id = selection, id == WidgetStore.revenueModule {
                    revenueInfo
                } else if let id = selection, id == WidgetStore.tasksModule {
                    TasksSettingsView()
                } else if let id = selection, let w = widgets.widget(id) {
                    WidgetEditor(original: w).id(w.id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Modules").font(.title3.weight(.semibold))
                        Text("Add any API or shell command as a sidebar module. Return the SideStats format for full control, or plain JSON and SideStats picks stats, charts or lists for you.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
                        HStack {
                            Button("Browse integrations…") { showGallery = true }.buttonStyle(.borderedProminent)
                            Button("JSON examples…") { showExamples = true }
                        }
                        Text("Grafana, Prometheus, Uptime Kuma, Docker, SSH servers, GitHub, Stripe and \(max(WidgetPresets.all.count - 7, 0)) more.")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("Widget format reference ↗", destination: URL(string: Links.repo + "/blob/main/WIDGETS.md")!)
                    }
                    .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showImport) { ImportSheet { selection = $0 } }
        .sheet(isPresented: $showGallery) { PresetGallery { selection = $0 } }
        .sheet(isPresented: $showExamples) { FormatExamplesSheet { selection = $0 } }
    }

    private func row(_ id: String) -> some View {
        let builtinTitle = WidgetStore.builtinTitle(id)
        let isRevenue = builtinTitle != nil   // any built-in module
        let w = widgets.widget(id)
        let hidden = widgets.hidden.contains(id) || (w?.enabled == false)
        return HStack {
            Image(systemName: isRevenue ? WidgetStore.builtinIcon(id) : (w?.icon ?? "square"))
                .frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(builtinTitle ?? w?.name ?? id).lineLimit(1)
                Text(isRevenue ? "Built-in" : (w?.source.title ?? "")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if isRevenue {
                    if widgets.hidden.contains(id) { widgets.hidden.remove(id) } else { widgets.hidden.insert(id) }
                } else if var w {
                    w.enabled.toggle()
                    if let i = widgets.widgets.firstIndex(where: { $0.id == id }) { widgets.widgets[i] = w }
                }
            } label: { Image(systemName: hidden ? "eye.slash" : "eye") }
            .buttonStyle(.borderless).foregroundStyle(hidden ? .tertiary : .secondary)
            .help(hidden ? "Show in sidebar" : "Hide from sidebar")
        }
        .opacity(hidden ? 0.55 : 1)
    }

    private var revenueInfo: some View {
        Form {
            Section("Apps & Revenue") {
                Text("Built-in module that merges App Store Connect, Google Play, AdMob, Apple Search Ads and Meta Ads data per app. Configure the sources in their own tabs.")
                    .foregroundStyle(.secondary)
                LabeledContent("Other ad networks & apps") {
                    Button("Custom sources…") { tab = SettingsTab.custom.rawValue }
                }
                Text("AppLovin MAX, LevelPlay, your own backend, a script or pushed JSON — anything that returns daily rows.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show in sidebar", isOn: Binding(
                    get: { !widgets.hidden.contains(WidgetStore.revenueModule) },
                    set: { if $0 { widgets.hidden.remove(WidgetStore.revenueModule) } else { widgets.hidden.insert(WidgetStore.revenueModule) } }))
            }
        }
        .formStyle(.grouped)
    }

    private func add(_ source: WidgetSourceType) {
        var w = WidgetConfig()
        w.source = source
        switch source {
        case .http: w.name = "New API widget"; w.icon = "network"
        case .command: w.name = "New command widget"; w.icon = "terminal"
        case .push: w.name = "Pushed data"; w.icon = "arrow.down.circle"
        }
        if source == .command {
            w.command = #"echo '{"items":[{"type":"stat","label":"Hello","value":42}]}'"#
            w.refreshSeconds = 60
        }
        widgets.widgets.append(w)
        selection = w.id
    }
}

// MARK: - Editor

struct WidgetEditor: View {
    @EnvironmentObject var widgets: WidgetStore
    let original: WidgetConfig
    @State private var draft: WidgetConfig
    @State private var showExamples = false
    @State private var headers: String
    @State private var originalHeaders: String
    @State private var preview: [WidgetItem] = []
    @State private var raw = ""
    @State private var error: String?
    @State private var testing = false
    @State private var copied = false

    static let intervals: [(Int, String)] = [(5, "5 sec"), (10, "10 sec"), (30, "30 sec"), (60, "1 min"),
                                             (300, "5 min"), (900, "15 min"), (3600, "1 hour"), (21600, "6 hours")]

    init(original: WidgetConfig) {
        self.original = original
        _draft = State(initialValue: original)
        let h = original.headers
        _headers = State(initialValue: h)
        _originalHeaders = State(initialValue: h)
    }

    private var dirty: Bool { draft != original || headers != originalHeaders }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("Icon (SF Symbol)", text: $draft.icon)
                    Picker("Source", selection: $draft.source) {
                        ForEach(WidgetSourceType.allCases) { Text($0.title).tag($0) }
                    }
                    if draft.source != .push { Picker("Refresh every", selection: $draft.refreshSeconds) {
                        ForEach(Self.intervals, id: \.0) { Text($0.1).tag($0.0) }
                        if !Self.intervals.contains(where: { $0.0 == draft.refreshSeconds }) {
                            Text("\(draft.refreshSeconds) sec").tag(draft.refreshSeconds)
                        }
                    } }
                    if !draft.preset.isEmpty, let p = WidgetPresets.preset(draft.preset) {
                        LabeledContent("Integration") {
                            HStack(spacing: 6) {
                                Text(p.name).foregroundStyle(.secondary)
                                if let u = URL(string: p.docs), !p.docs.isEmpty { Link("Docs ↗", destination: u) }
                            }
                        }
                    }
                }
                if draft.source == .http {
                    Section {
                        TextField("URL", text: $draft.url, prompt: Text("https://api.example.com/stats"))
                        Picker("Method", selection: $draft.method) {
                            ForEach(["GET", "POST", "PUT"], id: \.self) { Text($0).tag($0) }
                        }
                        LabeledContent("Headers") {
                            code($headers, placeholder: "Authorization: Bearer …", height: 44)
                        }
                        if draft.method != "GET" {
                            LabeledContent("Body") { code($draft.body, placeholder: "{\"from\":\"{{daysAgo:7}}\"}", height: 54) }
                        }
                    } header: { Text("Request") } footer: {
                        Text("Headers are stored in the Keychain and never exported. Placeholders: {{today}}, {{daysAgo:N}}, {{monthStart}}.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if draft.source == .push {
                    pushSection
                } else {
                    Section {
                        code($draft.command, placeholder: "curl -s … | jq …", height: 70)
                    } header: { Text("Command (zsh)") } footer: {
                        Text("Runs with your login shell environment, 30 s timeout. Print JSON for structured output; anything else is shown as text.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("JSON path", text: $draft.jsonPath, prompt: Text("e.g. data.items or results.0"))
                    TextField("Fields", text: $draft.fields, prompt: Text("e.g. stars, forks (optional)"))
                    Picker("Display", selection: $draft.display) {
                        Text("Auto").tag(WidgetDisplay.auto)
                        Text("Stats").tag(WidgetDisplay.stat)
                        Text("Chart").tag(WidgetDisplay.chart)
                        Text("List").tag(WidgetDisplay.list)
                        Text("Text / raw").tag(WidgetDisplay.text)
                    }
                } header: { Text("Data") } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Auto renders the SideStats format as-is; plain JSON becomes stats (numbers/objects), charts (number arrays or rows with a date) or lists (other arrays).")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("JSON examples…") { showExamples = true }.controlSize(.small)
                    }
                }
                Section {
                    code($draft.transform, placeholder: "data => ({ items: [ item.stat('Users', data.users) ] })", height: draft.transform.isEmpty ? 44 : 150)
                } header: { Text("Transform (JavaScript)") } footer: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Optional. Receives the response as `data` and returns SideStats items or JSON. Helpers: `item.stat/chart/list/status…`, `fmt.num/money/pct/bytes/ago`, `sum`, `avg`, `groupBy`, `sortBy`, `lines`. Runs before JSON path.")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("Reference ↗", destination: URL(string: Links.repo + "/blob/main/WIDGETS.md#transforms-javascript")!).font(.caption)
                    }
                }
                Section {
                    if testing { ProgressView().controlSize(.small) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if !preview.isEmpty {
                        WidgetItemsView(items: preview)
                            .padding(10)
                            .frame(width: EdgePanelController.width - 48)
                            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            .frame(maxWidth: .infinity)
                    }
                    if !raw.isEmpty {
                        DisclosureGroup("Raw response") {
                            ScrollView { Text(raw).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(height: 140)
                        }
                    }
                } header: {
                    HStack {
                        Text("Preview")
                        Spacer()
                        Button("Test") { test() }.controlSize(.small).disabled(testing)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button(role: .destructive) { widgets.remove(original.id) } label: { Text("Delete") }
                Button(copied ? "Copied ✓" : "Export") {
                    guard let json = widgets.export(original.id) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                    copied = true
                }
                .help("Copy this widget's JSON definition (without headers) to share it")
                Spacer()
                if dirty { Button("Revert") { draft = original; headers = originalHeaders } }
                Button("Save") { save() }.keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(!dirty)
            }
            .padding(10)
        }
        .onAppear {
            if let s = widgets.states[original.id], !s.items.isEmpty { preview = s.items } else { test() }
        }
        .sheet(isPresented: $showExamples) { FormatExamplesSheet() }
    }

    private var pushExample: String {
        "curl -X POST \(LocalAPIServer.baseURL)/v1/widgets/\(draft.id)/data \\\n" +
        "  -H 'Authorization: Bearer <token from Settings → API & MCP>' \\\n" +
        "  -H 'Content-Type: application/json' \\\n" +
        "  -d '{\"items\":[{\"type\":\"stat\",\"label\":\"Signups\",\"value\":42}]}'"
    }

    private var pushSection: some View {
        Section {
            LabeledContent("Widget ID") {
                HStack(spacing: 6) {
                    Text(draft.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                    Button { copy(draft.id) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy ID")
                }
            }
            Text(pushExample).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy example") { copy(pushExample) }
                Button("Copy with my token") {
                    let token = LocalAPIServer.shared?.token ?? ""
                    copy(pushExample.replacingOccurrences(of: "<token from Settings → API & MCP>", with: token.isEmpty ? "<token>" : token))
                }
                .help("Copies the command with your local API token filled in")
            }
            .controlSize(.small)
        } header: { Text("Push") } footer: {
            Text("Nothing is fetched: scripts, cron jobs, CI or AI agents (through the SideStats MCP server) send data whenever they like. Any JSON works: the SideStats format, or plain JSON shaped with a transform below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func code(_ text: Binding<String>, placeholder: String, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11, design: .monospaced))
            .scrollContentBackground(.hidden)
            .frame(minHeight: height)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
    }

    private func save() {
        if headers != originalHeaders { original.headers = headers; originalHeaders = headers }
        if let i = widgets.widgets.firstIndex(where: { $0.id == original.id }) { widgets.widgets[i] = draft }
        widgets.refresh(draft.id)
        copied = false
    }

    private func test() {
        testing = true; error = nil
        let cfg = draft, h = headers
        Task {
            do {
                let (payload, data) = try await WidgetFetcher.fetch(cfg, headers: h)
                preview = try WidgetParser.process(payload, config: cfg)
                raw = String(decoding: data.prefix(8000), as: UTF8.self)
            } catch {
                self.error = error.localizedDescription
                preview = []
            }
            testing = false
        }
    }
}

// MARK: - Import

struct ImportSheet: View {
    @EnvironmentObject var widgets: WidgetStore
    @Environment(\.dismiss) private var dismiss
    var onImported: (String) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import widgets").font(.headline)
            Text("Paste a widget definition (one JSON object or an array).").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 11, design: .monospaced))
                .frame(width: 520, height: 260)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Open file…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.json]
                    if p.runModal() == .OK, let u = p.url, let s = try? String(contentsOf: u, encoding: .utf8) { text = s }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") { doImport() }.buttonStyle(.borderedProminent).disabled(text.isEmpty)
            }
        }
        .padding(16)
    }

    private func doImport() {
        do {
            let list = try WidgetStore.decodeImport(text)
            let commands = list.filter { $0.source == .command }
            if !commands.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "This import runs shell commands on your Mac"
                alert.informativeText = commands.map { "• \($0.name):\n\($0.command.prefix(400))" }.joined(separator: "\n\n")
                    + "\n\nOnly continue if you trust where this came from."
                alert.addButton(withTitle: "Import")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            widgets.widgets.append(contentsOf: list)
            if let first = list.first { onImported(first.id) }
            dismiss()
        } catch {
            self.error = "Not a valid widget definition: \(error.localizedDescription)"
        }
    }
}
