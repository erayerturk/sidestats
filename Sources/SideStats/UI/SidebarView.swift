import Charts
import SwiftUI

enum Fmt {
    static func money(_ v: Double, _ currency: String, compact: Bool = false) -> String {
        if compact && abs(v) >= 10_000 {
            let (div, suffix): (Double, String) = abs(v) >= 1_000_000 ? (1_000_000, "M") : (1_000, "K")
            let s = (v / div).formatted(.currency(code: currency).precision(.fractionLength(0...1)))
            // put the suffix right after the number, before any trailing currency symbol
            if let r = s.range(of: #"\d(?!.*\d)"#, options: .regularExpression) {
                return s.replacingCharacters(in: r, with: s[r] + suffix)
            }
            return s + suffix
        }
        return v.formatted(.currency(code: currency).precision(.fractionLength(abs(v) >= 1000 ? 0 : 2)))
    }
    static func axis(_ v: Double, _ currency: String) -> String {
        v >= 10_000 ? money(v, currency, compact: true)
            : v.formatted(.currency(code: currency).precision(.fractionLength(0)))
    }
    static func count(_ v: Int) -> String { v.formatted(.number.notation(.compactName)) }
}

extension Color {
    static let revenue = Color(red: 0.20, green: 0.70, blue: 0.45)
    static let spend = Color(red: 0.93, green: 0.40, blue: 0.35)
}

struct SidebarView: View {
    @EnvironmentObject var store: MetricsStore
    @EnvironmentObject var edge: EdgePanelController
    @EnvironmentObject var widgets: WidgetStore
    var openSettings: (SettingsTab) -> Void
    @State private var expanded: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(widgets.visibleModules, id: \.self) { id in module(id) }
                    if widgets.visibleModules.isEmpty {
                        Text("All modules are hidden.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                    Button { openSettings(.widgets) } label: {
                        Label("Add module", systemImage: "plus.circle").font(.caption)
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(12)
            }
            if store.hasAnySource && widgets.visibleModules.contains(WidgetStore.revenueModule) {
                Divider().opacity(0.5)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func module(_ id: String) -> some View {
        if id == WidgetStore.revenueModule {
            ModuleCard(id: id, title: "Apps & Revenue", icon: "dollarsign.circle", status: nil) {
                if store.hasAnySource { sortMenu }
            } content: {
                if !store.hasAnySource {
                    emptyState
                } else {
                    SummaryCard(totals: store.totals, series: store.series, currency: store.config.baseCurrency)
                    LazyVStack(spacing: 6) {
                        ForEach(store.groups) { g in
                            AppRow(group: g, currency: store.config.baseCurrency, expanded: expanded == g.id)
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.2)) { expanded = expanded == g.id ? nil : g.id }
                                }
                                .contextMenu { rowMenu(g) }
                        }
                        if store.groups.isEmpty && !store.isLoading {
                            Text("No data for this period yet.")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                    }
                }
            }
        } else if id == WidgetStore.tasksModule {
            ModuleCard(id: id, title: "Tasks", icon: "checklist", status: nil) {
                EmptyView()
            } content: {
                TasksModuleView()
            }
        } else if let w = widgets.widget(id) {
            WidgetModuleView(config: w)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(Color.revenue)
                Text("SideStats").font(.headline)
                Spacer()
                Button { widgets.refreshAll(); Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                        .animation(store.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: store.isLoading)
                }
                .help("Refresh").disabled(store.isLoading)
                Button { edge.isPinned.toggle() } label: {
                    Image(systemName: edge.isPinned ? "pin.fill" : "pin")
                }
                .help(edge.isPinned ? "Unpin (auto-hide)" : "Pin open")
                Button { openSettings(.general) } label: { Image(systemName: "gearshape") }.help("Settings")
            }
            .buttonStyle(.borderless)
            if widgets.visibleModules.contains(WidgetStore.revenueModule) && store.hasAnySource {
                Picker("", selection: $store.range) {
                    ForEach(DateRangeOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $store.sort) {
                ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Label(store.sort.rawValue, systemImage: "arrow.up.arrow.down").font(.caption2)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    @ViewBuilder private func rowMenu(_ g: AppGroupSummary) -> some View {
        Button("Rename / merge…") { rename(g) }
        if g.keys.contains(where: { store.config.aliases[$0.id] != nil }) {
            Button("Reset name") { store.setAlias(nil, for: g.keys) }
        }
        Divider()
        ForEach(g.keys, id: \.self) { k in
            Text("\(k.platform.label): \(k.storeId)")
        }
    }

    private func rename(_ g: AppGroupSummary) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename \(g.name)"
        alert.informativeText = "Apps with the same name are shown as one row. Give two apps the same name to merge them."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = g.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            store.setAlias(field.stringValue.trimmingCharacters(in: .whitespaces), for: g.keys)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Connect App Store Connect, Google Play, AdMob, Apple Search Ads or Meta Ads. Keys stay in your Keychain.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Connect accounts") { openSettings(.appStore) }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Try demo data") {
                    store.config.useDemoData = true
                    Task { await store.refresh() }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !store.missingCurrencies.isEmpty {
                Label("No exchange rate for \(store.missingCurrencies.joined(separator: ", ")) — excluded",
                      systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            }
            FlowStatus()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowStatus: View {
    @EnvironmentObject var store: MetricsStore

    var body: some View {
        HStack(spacing: 10) {
            ForEach(store.configuredSources) { kind in
                let s = store.status[kind] ?? .init()
                HStack(spacing: 4) {
                    Circle().fill(s.loading ? .blue : s.error != nil ? .red : .green).frame(width: 6, height: 6)
                    Text(short(kind)).font(.caption2).foregroundStyle(.secondary)
                }
                .help(s.error ?? s.lastSuccess.map { "\(kind.title) — updated \($0.formatted(.relative(presentation: .named)))" } ?? kind.title)
            }
            Spacer()
        }
    }

    private func short(_ k: SourceKind) -> String {
        switch k {
        case .appStoreConnect: return "ASC"
        case .googlePlay: return "Play"
        case .admob: return "AdMob"
        case .appleSearchAds: return "ASA"
        case .metaAds: return "Meta"
        case .demo: return "Demo"
        }
    }
}

struct SummaryCard: View {
    var totals: Totals
    var series: [DailyPoint]
    var currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Net profit").font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.money(totals.net, currency, compact: true))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(totals.net >= 0 ? Color.primary : Color.spend)
                        .contentTransition(.numericText())
                }
                Spacer()
                if let roas = totals.roas {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("ROAS").font(.caption).foregroundStyle(.secondary)
                        Text(roas.formatted(.number.precision(.fractionLength(2))) + "×")
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                    }
                }
            }
            Chart(series) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Revenue", p.revenue))
                    .foregroundStyle(Color.revenue.gradient)
                BarMark(x: .value("Day", p.date, unit: .day), y: .value("Spend", -p.spend))
                    .foregroundStyle(Color.spend.gradient)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(Fmt.axis(abs(d), currency)).font(.caption2) }
                    }
                }
            }
            .frame(height: 90)

            HStack(spacing: 0) {
                Stat(title: "Revenue", value: Fmt.money(totals.revenue, currency, compact: true), color: .revenue)
                Stat(title: "Ad spend", value: Fmt.money(totals.spend, currency, compact: true), color: .spend)
                Stat(title: "Downloads", value: Fmt.count(totals.downloads), color: .secondary)
            }
            HStack(spacing: 12) {
                Text("Ads \(Fmt.money(totals.adRevenue, currency, compact: true))")
                Text("Store \(Fmt.money(totals.iapRevenue, currency, compact: true))")
                if totals.impressions > 0 { Text("\(Fmt.count(totals.impressions)) impr.") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Stat: View {
    var title: String
    var value: String
    var color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppRow: View {
    var group: AppGroupSummary
    var currency: String
    var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AppIcon(name: group.name, iosId: group.iosStoreId)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        ForEach(group.platforms, id: \.self) { p in
                            Text(p.short).font(.system(size: 8, weight: .semibold)).fixedSize()
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.secondary)
                        }
                        Text(Fmt.money(group.totals.revenue, currency, compact: true)).foregroundStyle(Color.revenue)
                            .fixedSize()
                        if group.totals.spend > 0 {
                            Text("−" + Fmt.money(group.totals.spend, currency, compact: true)).foregroundStyle(Color.spend)
                                .fixedSize()
                        }
                    }
                    .font(.caption2).monospacedDigit()
                }
                Spacer(minLength: 4)
                Sparkline(points: group.series)
                    .frame(width: 44, height: 22)
                Text(Fmt.money(group.totals.net, currency, compact: true))
                    .font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                    .foregroundStyle(group.totals.net >= 0 ? Color.primary : Color.spend)
                    .frame(minWidth: 62, alignment: .trailing)
            }
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        detail("Ad revenue", Fmt.money(group.totals.adRevenue, currency))
                        detail("Store revenue", Fmt.money(group.totals.iapRevenue, currency))
                    }
                    GridRow {
                        detail("Ad spend", Fmt.money(group.totals.spend, currency))
                        detail("ROAS", group.totals.roas.map { $0.formatted(.number.precision(.fractionLength(2))) + "×" } ?? "—")
                    }
                    GridRow {
                        detail("Downloads", group.totals.downloads.formatted())
                        detail("Impressions", group.totals.impressions.formatted())
                    }
                    if group.totals.downloads > 0 && group.totals.spend > 0 {
                        GridRow {
                            detail("Cost / download", Fmt.money(group.totals.spend / Double(group.totals.downloads), currency))
                            detail("Rev / download", Fmt.money(group.totals.revenue / Double(group.totals.downloads), currency))
                        }
                    }
                }
                .padding(.leading, 42)
                .transition(.opacity)
            }
        }
        .padding(8)
        .background(.background.opacity(expanded ? 0.55 : 0.3), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func detail(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.caption.weight(.medium)).monospacedDigit()
        }
    }
}

struct Sparkline: View {
    var points: [DailyPoint]
    var body: some View {
        Chart(points) { p in
            AreaMark(x: .value("d", p.date), y: .value("net", p.net))
                .foregroundStyle(.linearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("d", p.date), y: .value("net", p.net))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.3))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
    }
    private var color: Color { (points.reduce(0) { $0 + $1.net }) >= 0 ? .revenue : .spend }
}

/// App Store icon via the public iTunes lookup API; monogram fallback for others.
struct AppIcon: View {
    var name: String
    var iosId: String?
    @State private var url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(monogramColor.gradient)
            Text(String(name.prefix(1)).uppercased()).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            if let url {
                AsyncImage(url: url) { img in img.resizable() } placeholder: { Color.clear }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .frame(width: 32, height: 32)
        .task(id: iosId) { url = await IconCache.shared.url(for: iosId) }
    }

    private var monogramColor: Color {
        let h = Double(name.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 9973 } % 360) / 360
        return Color(hue: h, saturation: 0.45, brightness: 0.75)
    }
}

actor IconCache {
    static let shared = IconCache()
    private var cache: [String: URL?] = Storage.load([String: URL?].self, "icons.json") ?? [:]

    func url(for id: String?) async -> URL? {
        guard let id, id.allSatisfy(\.isNumber) else { return nil }
        if let hit = cache[id] { return hit }
        let json = try? await HTTP.json(HTTP.request("https://itunes.apple.com/lookup?id=\(id)")) as? [String: Any]
        let u = (json?["results"] as? [[String: Any]])?.first?.str("artworkUrl100").flatMap(URL.init(string:))
        cache[id] = u
        Storage.save(cache, "icons.json")
        return u
    }
}
