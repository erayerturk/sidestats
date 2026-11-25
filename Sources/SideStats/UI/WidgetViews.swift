import Charts
import SwiftUI

extension Color {
    /// Named colors or #RRGGBB.
    static func named(_ s: String?, default d: Color = .accentColor) -> Color {
        guard let s = s?.lowercased(), !s.isEmpty else { return d }
        switch s {
        case "green": return .revenue
        case "red": return .spend
        case "blue": return .blue
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "pink": return .pink
        case "teal": return .teal
        case "gray", "grey": return .gray
        case "primary": return .primary
        case "secondary": return .secondary
        default: break
        }
        let hex = s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return d }
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

enum ValueFormat {
    static func string(_ v: Double, format: String, currency: String, decimals: Int? = nil, unit: String? = nil) -> String {
        var out: String
        switch format {
        case "currency": out = Fmt.money(v, currency, compact: true)
        case "percent": out = v.formatted(.percent.precision(.fractionLength(decimals ?? 1)))
        case "bytes": out = ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file)
        case "duration":
            let f = DateComponentsFormatter()
            f.unitsStyle = .abbreviated; f.maximumUnitCount = 2
            out = f.string(from: v) ?? "\(v)s"
        default:
            if let decimals { out = v.formatted(.number.precision(.fractionLength(decimals))) }
            else if abs(v) >= 100_000 { out = Fmt.count(Int(v)) }
            else { out = v.formatted(.number.precision(.fractionLength(0...2))) }
        }
        if let unit, !unit.isEmpty { out += " " + unit }
        return out
    }
}

/// Renders a widget's items. Consecutive stats are laid out in a grid.
struct WidgetItemsView: View {
    var items: [WidgetItem]

    private enum Block: Identifiable {
        case stats([StatSpec], UUID)
        case single(WidgetItem)
        var id: UUID { if case .stats(_, let id) = self { return id }; if case .single(let i) = self { return i.id }; return UUID() }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var pending: [StatSpec] = []
        func flush() { if !pending.isEmpty { out.append(.stats(pending, UUID())); pending = [] } }
        for item in items {
            if case .stat(let s) = item.kind { pending.append(s) } else { flush(); out.append(.single(item)) }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .stats(let stats, _):
                    let cols = stats.count == 1 ? 1 : stats.count == 3 ? 3 : 2
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: cols),
                              alignment: .leading, spacing: 10) {
                        ForEach(Array(stats.enumerated()), id: \.offset) { StatView(spec: $0.element, large: cols == 1) }
                    }
                case .single(let item):
                    switch item.kind {
                    case .chart(let c): ChartItemView(spec: c)
                    case .list(let l): ListItemView(spec: l)
                    case .text(let t): TextItemView(spec: t)
                    case .progress(let p): ProgressItemView(spec: p)
                    case .status(let s): StatusItemView(spec: s)
                    case .stat: EmptyView()
                    }
                }
            }
        }
    }
}

struct StatView: View {
    var spec: StatSpec
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(spec.label).sfont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(valueText)
                    .sfont(large ? .title2 : .callout, weight: .semibold, design: .rounded)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(Color.named(spec.color, default: .primary))
                    .contentTransition(.numericText())
                    .animation(.default, value: valueText)
                if let delta = spec.delta {
                    let good = (delta >= 0) == spec.positiveIsGood
                    Text((delta >= 0 ? "▲ " : "▼ ") + abs(delta).formatted(.percent.precision(.fractionLength(0...1))))
                        .sfont(.caption2, weight: .medium).foregroundStyle(good ? Color.revenue : Color.spend)
                }
            }
            if !spec.sparkline.isEmpty {
                Chart(Array(spec.sparkline.enumerated()), id: \.offset) { p in
                    LineMark(x: .value("i", p.offset), y: .value("v", p.element))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Color.named(spec.color, default: .accentColor))
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 20)
            }
            if let caption = spec.caption { Text(caption).sfont(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
        }
    }

    private var valueText: String {
        if let v = spec.value {
            return ValueFormat.string(v, format: spec.format, currency: spec.currency, decimals: spec.decimals, unit: spec.unit)
        }
        return (spec.text ?? "—") + (spec.unit.map { " " + $0 } ?? "")
    }
}

struct ChartItemView: View {
    @Environment(\.uiScale) private var uiScale
    var spec: ChartSpec
    private static let palette: [Color] = [.revenue, .blue, .orange, .purple, .pink, .teal, .spend, .yellow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = spec.label, !label.isEmpty { Text(label).sfont(.caption, weight: .medium) }
            chart
                .chartLegend(spec.series.count > 1 || isPie ? .visible : .hidden)
                .frame(height: spec.height * uiScale)
        }
    }

    private var isPie: Bool { spec.kind == "pie" || spec.kind == "donut" }

    private var colors: [Color] {
        spec.series.enumerated().map { i, s in Color.named(s.color, default: Self.palette[i % Self.palette.count]) }
    }

    @ViewBuilder private var chart: some View {
        if isPie, let s = spec.series.first {
            Chart(s.points) { p in
                SectorMark(angle: .value("v", p.y), innerRadius: .ratio(spec.kind == "donut" ? 0.55 : 0), angularInset: 1)
                    .foregroundStyle(by: .value("Label", p.label))
            }
            .chartForegroundStyleScale(domain: s.points.map(\.label),
                                       range: s.points.indices.map { Self.palette[$0 % Self.palette.count] })
        } else {
            Chart {
                ForEach(spec.series) { s in
                    ForEach(s.points) { p in mark(s, p) }
                }
            }
            .chartForegroundStyleScale(domain: spec.series.map(\.name), range: colors)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(ValueFormat.string(d, format: spec.format, currency: spec.currency)).sfont(.caption2)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel().font(.system(size: 10 * uiScale)) }
            }
        }
    }

    @ChartContentBuilder private func mark(_ s: ChartSeries, _ p: ChartPoint) -> some ChartContent {
        if spec.usesDates, let d = p.date {
            switch spec.kind {
            case "bar": BarMark(x: .value("x", d, unit: .day), y: .value("y", p.y)).foregroundStyle(by: .value("Series", s.name))
            case "area": AreaMark(x: .value("x", d), y: .value("y", p.y)).foregroundStyle(by: .value("Series", s.name)).interpolationMethod(.monotone)
            default: LineMark(x: .value("x", d), y: .value("y", p.y)).foregroundStyle(by: .value("Series", s.name)).interpolationMethod(.monotone)
            }
        } else {
            switch spec.kind {
            case "bar": BarMark(x: .value("x", p.label), y: .value("y", p.y)).foregroundStyle(by: .value("Series", s.name))
            case "area": AreaMark(x: .value("x", p.label), y: .value("y", p.y)).foregroundStyle(by: .value("Series", s.name)).interpolationMethod(.monotone)
            default: LineMark(x: .value("x", p.label), y: .value("y", p.y)).foregroundStyle(by: .value("Series", s.name)).interpolationMethod(.monotone)
            }
        }
    }
}

struct ListItemView: View {
    var spec: ListSpec
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = spec.label, !label.isEmpty { Text(label).sfont(.caption, weight: .medium) }
            ForEach(showAll ? spec.rows : Array(spec.rows.prefix(spec.limit))) { row in
                HStack(spacing: 8) {
                    icon(row.icon)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).sfont(.callout).lineLimit(1)
                        if let s = row.subtitle { Text(s).sfont(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if let v = row.value {
                        Text(v).sfont(.callout, weight: .semibold).monospacedDigit()
                            .foregroundStyle(Color.named(row.valueColor, default: .primary))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if let u = row.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) } }
            }
            if spec.rows.count > spec.limit {
                Button(showAll ? "Show less" : "Show all \(spec.rows.count)") { showAll.toggle() }
                    .buttonStyle(.link).sfont(.caption)
            }
        }
    }

    @ViewBuilder private func icon(_ s: String?) -> some View {
        if let s, s.hasPrefix("sf:") {
            Image(systemName: String(s.dropFirst(3))).frame(width: 20, height: 20).foregroundStyle(.secondary)
        } else if let s, let u = URL(string: s), u.scheme?.hasPrefix("http") == true {
            AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

struct TextItemView: View {
    var spec: TextSpec
    var body: some View {
        Group {
            switch spec.style {
            case "title": Text(spec.text).sfont(.headline)
            case "caption": Text(spec.text).sfont(.caption).foregroundStyle(.secondary)
            case "mono":
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(spec.text).sfont(size: 10, design: .monospaced).fixedSize()
                }
                .frame(maxHeight: 220)
            default: Text((try? AttributedString(markdown: spec.text)) ?? AttributedString(spec.text)).sfont(.callout)
            }
        }
        .foregroundStyle(Color.named(spec.color, default: .primary))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProgressItemView: View {
    var spec: ProgressSpec
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spec.label).sfont(.caption)
                Spacer()
                Text(spec.caption ?? spec.value.formatted(.percent.precision(.fractionLength(0))))
                    .sfont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.named(spec.color, default: spec.value > 0.9 ? .spend : .accentColor))
                        .frame(width: g.size.width * spec.value)
                        .animation(.easeOut, value: spec.value)
                }
            }
            .frame(height: 6)
        }
    }
}

struct StatusItemView: View {
    var spec: StatusSpec
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: 3)
            Text(spec.label).sfont(.callout)
            Spacer()
            if let d = spec.detail { Text(d).sfont(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
    private var color: Color {
        switch spec.state.lowercased() {
        case "ok", "up", "green", "healthy", "true": return .revenue
        case "warn", "warning", "degraded", "yellow": return .orange
        case "error", "down", "red", "fail", "false": return .spend
        default: return .blue
        }
    }
}

/// Collapsible module container used for every sidebar section.
struct ModuleCard<Content: View, Actions: View>: View {
    var id: String
    var title: String
    var icon: String
    var status: String?
    var live = false
    var error: String?
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content
    @EnvironmentObject var widgets: WidgetStore

    var body: some View {
        let isCollapsed = widgets.collapsed.contains(id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").sfont(size: 9, weight: .bold).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Image(systemName: icon).sfont(.caption).foregroundStyle(.secondary)
                Text(title).sfont(.subheadline, weight: .semibold).lineLimit(1)
                if live { LiveDot() }
                Spacer()
                if let status { Text(status).sfont(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
                actions()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.2)) {
                    if isCollapsed { widgets.collapsed.remove(id) } else { widgets.collapsed.insert(id) }
                }
            }
            if !isCollapsed {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").sfont(.caption2).foregroundStyle(.orange)
                        .lineLimit(3).textSelection(.enabled)
                }
                content()
            }
        }
    }
}

struct LiveDot: View {
    var body: some View {
        Circle().fill(Color.revenue).frame(width: 6, height: 6)
            .shadow(color: Color.revenue.opacity(0.7), radius: 2)
            .help("Live")
    }
}

/// "8s" / "3m" label; only this tiny view re-renders every second.
struct AgoText: View {
    var date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(date)))
            Text(s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h")
                .sfont(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

/// One custom widget as a sidebar module.
struct WidgetModuleView: View {
    var config: WidgetConfig
    @EnvironmentObject var widgets: WidgetStore

    var body: some View {
        let state = widgets.states[config.id] ?? .init()
        ModuleCard(id: config.id, title: config.name, icon: config.icon,
                   status: state.loading && state.items.isEmpty ? "loading…" : nil,
                   live: config.refreshSeconds <= 60, error: state.error) {
            if let d = state.updated { AgoText(date: d) }
            Button { widgets.refresh(config.id) } label: {
                Image(systemName: "arrow.clockwise").sfont(.caption2)
            }
            .buttonStyle(.borderless).help("Refresh now")
        } content: {
            if state.items.isEmpty && state.error == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else {
                WidgetItemsView(items: state.items)
                    .padding(10)
                    .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
