import SwiftUI

/// Settings → Modules → + → Browse integrations…: pick a preset, fill its params, test, add.
struct PresetGallery: View {
    @EnvironmentObject var widgets: WidgetStore
    @Environment(\.dismiss) private var dismiss
    var onAdded: (String) -> Void

    @State private var search = ""
    @State private var category: String?
    @State private var selected: WidgetPreset?

    var body: some View {
        Group {
            if let p = selected {
                PresetForm(preset: p, onBack: { selected = nil }) { id in onAdded(id); dismiss() }
            } else {
                gallery
            }
        }
        .frame(width: 740, height: 600)
    }

    private var filtered: [WidgetPreset] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return WidgetPresets.all.filter { p in
            (category == nil || p.category == category) &&
            (q.isEmpty || [p.name, p.summary, p.id, p.category, p.requires].contains { $0.lowercased().contains(q) })
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Integrations").font(.title2.weight(.semibold))
                    Text("\(WidgetPresets.all.count) ready-made modules. Fill in a few fields and they appear in your sidebar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search Grafana, Docker, Stripe…", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 260)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("All", nil)
                        ForEach(WidgetPresets.categories, id: \.self) { chip($0, $0) }
                    }
                }
            }
            ScrollView {
                if filtered.isEmpty {
                    Text("No integration matches “\(search)”. You can still add any API or command with + → HTTP API / Shell command.")
                        .foregroundStyle(.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 10) {
                    ForEach(filtered) { p in
                        Button { selected = p } label: { PresetCard(preset: p) }.buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(18)
    }

    private func chip(_ title: String, _ value: String?) -> some View {
        let on = category == value
        let n = value.map { v in WidgetPresets.all.filter { $0.category == v }.count } ?? WidgetPresets.all.count
        return Button { category = value } label: {
            Text("\(title) \(Text("\(n)").foregroundStyle(on ? .white.opacity(0.75) : .secondary))")
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

extension WidgetPreset {
    var tint: Color {
        switch category {
        case "Monitoring": return .orange
        case "Servers": return .blue
        case "Dev": return .purple
        case "Business": return .green
        default: return .teal
        }
    }
}

private struct PresetCard: View {
    let preset: WidgetPreset
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: preset.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(preset.tint)
                    .frame(width: 30, height: 30)
                    .background(preset.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(preset.category).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Label(preset.requires, systemImage: preset.params.contains(where: \.secret) ? "key" : "checkmark.seal")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(.background.opacity(hover ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hover ? preset.tint.opacity(0.6) : Color.secondary.opacity(0.2)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Parameter form + live preview for one preset.
struct PresetForm: View {
    @EnvironmentObject var widgets: WidgetStore
    let preset: WidgetPreset
    var onBack: () -> Void
    var onAdded: (String) -> Void

    @State private var values: [String: String] = [:]
    @State private var preview: [WidgetItem] = []
    @State private var previewIsSample = true
    @State private var error: String?
    @State private var testing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { onBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Image(systemName: preset.icon).foregroundStyle(preset.tint)
                    .frame(width: 28, height: 28).background(preset.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 0) {
                    Text(preset.name).font(.headline)
                    Text(preset.category + " · " + preset.requires).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let u = URL(string: preset.docs), !preset.docs.isEmpty { Link("Docs ↗", destination: u).font(.callout) }
            }
            .padding(14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                Form {
                    Section {
                        Text(preset.summary).foregroundStyle(.secondary)
                    }
                    if !preset.params.isEmpty {
                        Section("Settings") {
                            ForEach(preset.params) { field($0) }
                        }
                    }
                    if preset.template.source == .command {
                        Section {
                            DisclosureGroup("Shell command") {
                                Text(filled?.command ?? preset.template.command)
                                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } footer: {
                            Text("Runs locally with your login shell (zsh) on every refresh. You can edit it after adding.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if preset.params.contains(where: \.secret) {
                        Section {} footer: {
                            Label("Keys and tokens are stored in the macOS Keychain as request headers and are never exported.", systemImage: "lock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity)

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Preview").font(.headline)
                        if previewIsSample && !preview.isEmpty {
                            Text("sample data").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if testing { ProgressView().controlSize(.small) }
                        Button("Test") { test() }.controlSize(.small).disabled(testing || missing != nil)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if let error {
                                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            }
                            if !preview.isEmpty {
                                WidgetItemsView(items: preview)
                                    .padding(10)
                                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                                    .opacity(previewIsSample ? 0.75 : 1)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(width: EdgePanelController.width - 10)
            }
            Divider()
            HStack {
                if let missing { Text("Fill in \(missing)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { onBack() }
                Button("Add to sidebar") { add() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(missing != nil)
            }
            .padding(12)
        }
        .onAppear {
            for p in preset.params where values[p.id] == nil { values[p.id] = p.defaultValue }
            showSample()
        }
    }

    private var missing: String? {
        preset.params.first { !$0.optional && (values[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty && $0.defaultValue.isEmpty }?.label
    }

    private var filled: WidgetConfig? { try? WidgetPresets.make(preset.id, params: values).config }

    @ViewBuilder private func field(_ p: PresetParam) -> some View {
        let binding = Binding(get: { values[p.id] ?? "" }, set: { values[p.id] = $0 })
        VStack(alignment: .leading, spacing: 3) {
            if !p.options.isEmpty {
                Picker(p.label, selection: binding) {
                    ForEach(p.options, id: \.self) { Text($0).tag($0) }
                }
            } else if p.secret {
                SecureField(p.label, text: binding, prompt: Text(p.placeholder.isEmpty ? (p.optional ? "optional" : "required") : p.placeholder))
            } else {
                TextField(p.label, text: binding, prompt: Text(p.placeholder.isEmpty ? (p.optional ? "optional" : "") : p.placeholder))
            }
            if !p.help.isEmpty {
                Text(p.help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func showSample() {
        guard !preset.sample.isEmpty else { return }
        var params = values
        for p in preset.params where (params[p.id] ?? "").isEmpty { params[p.id] = p.placeholder.isEmpty ? "x" : p.placeholder }
        guard let c = try? WidgetPresets.make(preset.id, params: params).config,
              let items = try? WidgetParser.process(WidgetFetcher.decode(Data(preset.sample.utf8)), config: c) else { return }
        preview = items
        previewIsSample = true
    }

    private func test() {
        error = nil
        let made: (config: WidgetConfig, headers: String)
        do { made = try WidgetPresets.make(preset.id, params: values) } catch { self.error = error.localizedDescription; return }
        testing = true
        Task {
            do {
                let (payload, _) = try await WidgetFetcher.fetch(made.config, headers: made.headers)
                preview = try WidgetParser.process(payload, config: made.config)
                previewIsSample = false
            } catch {
                self.error = error.localizedDescription
            }
            testing = false
        }
    }

    private func add() {
        do {
            let (config, headers) = try WidgetPresets.make(preset.id, params: values)
            // Headers are keyed by widget id, so store them before `add` starts the first fetch.
            if !headers.isEmpty { config.headers = headers }
            let added = widgets.add(config)
            if added.id != config.id { added.headers = headers }
            onAdded(added.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
