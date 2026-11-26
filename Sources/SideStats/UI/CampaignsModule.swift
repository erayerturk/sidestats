import Charts
import SwiftUI

/// Built-in "Ad Campaigns" module: spend & delivery KPIs, funnel, daily chart, spend share and
/// every tracked campaign (including ones that haven't started yet).
struct CampaignsModuleView: View {
    @EnvironmentObject var store: MetricsStore
    @AppStorage("campaignChartMetric") private var metricRaw = CampaignMetric.spend.rawValue
    @State private var expanded: String?

    private var metric: CampaignMetric { CampaignMetric(rawValue: metricRaw) ?? .spend }
    private var currency: String { store.config.baseCurrency }

    var body: some View {
        let campaigns = store.campaigns
        if campaigns.isEmpty {
            Text("Connect Google Ads, Apple Search Ads or Meta Ads in Settings to see your campaigns here.")
                .sfont(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
        } else {
            let colors = CampaignPalette.colors(for: campaigns)
            VStack(spacing: 8) {
                CampaignHero(campaigns: campaigns, currency: currency)
                CampaignFunnel(totals: campaigns.reduce(Totals()) { $0 + $1.totals })
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $metricRaw) {
                        ForEach(CampaignMetric.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    CampaignChart(campaigns: campaigns, metric: metric, currency: currency, colors: colors)
                    CampaignShare(campaigns: campaigns, metric: metric, currency: currency, colors: colors)
                }
                .padding(10)
                .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                ForEach(campaigns) { c in
                    CampaignRow(campaign: c, currency: currency, color: colors[c.id] ?? .gray, metric: metric,
                                expanded: expanded == c.id)
                        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded = expanded == c.id ? nil : c.id } }
                }
            }
        }
    }
}

enum CampaignMetric: String, CaseIterable, Identifiable {
    case spend = "Spend", views = "Views", clicks = "Clicks", installs = "Installs"
    var id: String { rawValue }
    func value(_ t: Totals) -> Double {
        switch self {
        case .spend: return t.spend
        case .views: return Double(t.adImpressions)
        case .clicks: return Double(t.clicks)
        case .installs: return t.installs
        }
    }
    func format(_ v: Double, _ currency: String) -> String {
        self == .spend ? Fmt.money(v, currency, compact: true) : Fmt.count(Int(v.rounded()))
    }
}

enum CampaignPalette {
    static let all: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo, .mint, .red, .cyan, .brown]
    /// Stable colour per campaign (by id), shared by the chart, the share bar and the rows.
    static func colors(for campaigns: [CampaignSummary]) -> [String: Color] {
        var out: [String: Color] = [:]
        for (i, c) in campaigns.sorted(by: { $0.id < $1.id }).enumerated() { out[c.id] = all[i % all.count] }
        return out
    }
}

private extension CampaignSummary {
    var dailyPoints: [(date: Date, totals: Totals)] { days }
}

/// Big spend number with a daily area chart and the key ratios.
struct CampaignHero: View {
    var campaigns: [CampaignSummary]
    var currency: String

    var body: some View {
        let t = campaigns.reduce(Totals()) { $0 + $1.totals }
        let daily = Self.daily(campaigns)
        let active = campaigns.filter { $0.state == .active }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ad spend").sfont(.caption2).foregroundStyle(.secondary)
                    Text(Fmt.money(t.spend, currency)).sfont(.title2, weight: .bold, design: .rounded)
                        .foregroundStyle(Color.spend).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(active) active").sfont(.caption, weight: .semibold).foregroundStyle(.green)
                    Text("\(campaigns.count) campaigns").sfont(.caption2).foregroundStyle(.secondary)
                }
            }
            if daily.contains(where: { $0.1.spend > 0 || $0.1.adImpressions > 0 }) {
                Chart {
                    ForEach(daily, id: \.0) { d in
                        AreaMark(x: .value("Day", d.0, unit: .day), y: .value("Spend", d.1.spend))
                            .foregroundStyle(.linearGradient(colors: [Color.spend.opacity(0.4), Color.spend.opacity(0.02)],
                                                             startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Day", d.0, unit: .day), y: .value("Spend", d.1.spend))
                            .foregroundStyle(Color.spend).lineStyle(StrokeStyle(lineWidth: 1.6))
                            .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { v in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.axis(d, currency)).font(.system(size: 8)) } }
                    }
                }
                .frame(height: 54)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    tile("Views", Fmt.count(t.adImpressions), "eye")
                    tile("Clicks", Fmt.count(t.clicks), "cursorarrow.click")
                    tile("Installs", Fmt.count(Int(t.installs.rounded())), "arrow.down.app")
                }
                GridRow {
                    tile("CTR", t.ctr.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "—", "percent")
                    tile("Cost / install", t.cpi.map { Fmt.money($0, currency) } ?? "—", "tag")
                    tile("CPC", t.clicks > 0 && t.spend > 0 ? Fmt.money(t.spend / Double(t.clicks), currency) : "—", "hand.tap")
                }
            }
        }
        .padding(12)
        .background(
            LinearGradient(colors: [Color.spend.opacity(0.14), Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 12))
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Daily totals, starting the day before the first delivery (at least the last week).
    static func daily(_ campaigns: [CampaignSummary]) -> [(Date, Totals)] {
        var m: [Date: Totals] = [:]
        for c in campaigns { for d in c.days { m[d.date] = (m[d.date] ?? Totals()) + d.totals } }
        let all = m.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        guard let last = all.last?.0,
              let first = all.first(where: { $0.1.spend > 0 || $0.1.adImpressions > 0 })?.0 else { return all }
        let from = min(Calendar.utc.date(byAdding: .day, value: -1, to: first) ?? first,
                       Calendar.utc.date(byAdding: .day, value: -6, to: last) ?? last)
        return all.filter { $0.0 >= from }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).sfont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value).sfont(.callout, weight: .semibold, design: .rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Views → clicks → installs, with step conversion rates. Bars use a log scale so small steps stay visible.
struct CampaignFunnel: View {
    var totals: Totals

    var body: some View {
        let steps: [(String, Double, Color)] = [
            ("Views", Double(totals.adImpressions), .blue),
            ("Clicks", Double(totals.clicks), .purple),
            ("Installs", totals.installs, .green),
        ]
        let maxLog = log10(max(steps[0].1, 10))
        if steps[0].1 > 0 {
            VStack(alignment: .leading, spacing: 5) {
                Text("Funnel").sfont(.caption, weight: .semibold)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 8) {
                        Text(s.0).sfont(.caption2).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                        GeometryReader { geo in
                            let w = s.1 > 0 ? max(0.06, log10(max(s.1, 1) + 1) / (maxLog + 0.0001)) : 0
                            RoundedRectangle(cornerRadius: 4)
                                .fill(s.2.gradient)
                                .frame(width: geo.size.width * min(w, 1))
                        }
                        .frame(height: 14)
                        Text(Fmt.count(Int(s.1.rounded()))).sfont(.caption, weight: .semibold).monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                        Text(i == 0 ? "" : rate(s.1, steps[i - 1].1)).sfont(.caption2).foregroundStyle(.secondary)
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding(10)
            .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func rate(_ a: Double, _ b: Double) -> String {
        b > 0 ? (a / b).formatted(.percent.precision(.fractionLength(1))) : "—"
    }
}

/// Daily stacked bars per campaign for the chosen metric.
struct CampaignChart: View {
    var campaigns: [CampaignSummary]
    var metric: CampaignMetric
    var currency: String
    var colors: [String: Color]

    private struct Point: Identifiable {
        var id: String { campaign + "\(date.timeIntervalSince1970)" }
        var date: Date; var campaign: String; var value: Double
    }

    private var points: [Point] {
        let shown = campaigns.filter { metric.value($0.totals) > 0 }
        // Start at the first day with data (but show at least a week) so new campaigns aren't squeezed to the edge.
        let allDays = shown.first?.days.map(\.date) ?? []
        let firstData = shown.flatMap { c in c.days.filter { metric.value($0.totals) > 0 }.map(\.date) }.min()
        var from = allDays.first ?? Date()
        if let firstData, let last = allDays.last {
            let weekBefore = Calendar.utc.date(byAdding: .day, value: -6, to: last) ?? last
            from = max(from, min(Calendar.utc.date(byAdding: .day, value: -1, to: firstData) ?? firstData, weekBefore))
        }
        return shown.flatMap { c in
            c.days.filter { $0.date >= from }.map { Point(date: $0.date, campaign: c.name, value: metric.value($0.totals)) }
        }
    }

    var body: some View {
        let pts = points
        if pts.isEmpty {
            Text("No \(metric.rawValue.lowercased()) in this period yet.")
                .sfont(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            let names = campaigns.filter { metric.value($0.totals) > 0 }
            Chart(pts) { p in
                BarMark(x: .value("Day", p.date, unit: .day), y: .value(metric.rawValue, p.value))
                    .foregroundStyle(by: .value("Campaign", p.campaign))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: names.map(\.name), range: names.map { colors[$0.id] ?? .gray })
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(metric.format(d, currency)).font(.system(size: 8)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 8))
                }
            }
            .frame(height: 150)
        }
    }
}

/// Donut + legend: each campaign's share of the chosen metric.
struct CampaignShare: View {
    var campaigns: [CampaignSummary]
    var metric: CampaignMetric
    var currency: String
    var colors: [String: Color]

    var body: some View {
        let shown = campaigns.filter { metric.value($0.totals) > 0 }
            .sorted { metric.value($0.totals) > metric.value($1.totals) }
        let total = shown.reduce(0) { $0 + metric.value($1.totals) }
        if total > 0 {
            HStack(spacing: 12) {
                Chart(shown) { c in
                    SectorMark(angle: .value("Share", metric.value(c.totals)), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(colors[c.id] ?? .gray)
                        .cornerRadius(3)
                }
                .frame(width: 70, height: 70)
                .overlay {
                    VStack(spacing: 0) {
                        Text(metric.format(total, currency)).sfont(size: 10, weight: .bold, design: .rounded).monospacedDigit()
                        Text(metric.rawValue.lowercased()).sfont(size: 8).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { c in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(colors[c.id] ?? .gray).frame(width: 8, height: 8)
                            Text(c.name).sfont(.caption2).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text((metric.value(c.totals) / total).formatted(.percent.precision(.fractionLength(0))))
                                .sfont(.caption2, weight: .semibold).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

struct CampaignRow: View {
    var campaign: CampaignSummary
    var currency: String
    var color: Color
    var metric: CampaignMetric
    var expanded: Bool

    private var stateColor: Color {
        switch campaign.state {
        case .active: return .green
        case .scheduled: return .orange
        case .paused, .ended: return .gray
        case .unknown: return .secondary
        }
    }

    var body: some View {
        let t = campaign.totals
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(campaign.name).sfont(.caption, weight: .semibold).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(t.spend > 0 ? Fmt.money(t.spend, currency, compact: true) : "—")
                        .sfont(.callout, weight: .bold, design: .rounded).monospacedDigit()
                        .foregroundStyle(t.spend > 0 ? Color.spend : Color.secondary)
                }
                HStack(spacing: 6) {
                    if !campaign.state.label.isEmpty {
                        Text(campaign.state.label).sfont(size: 9, weight: .semibold)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(stateColor.opacity(0.18), in: Capsule()).foregroundStyle(stateColor)
                    }
                    Text([campaign.appName, campaign.source.title].compactMap { $0 }.joined(separator: " · "))
                        .sfont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    MiniBars(values: campaign.days.suffix(14).map { metric.value($0.totals) }, color: color)
                        .frame(width: 52, height: 16)
                }
                if t.adImpressions > 0 || t.clicks > 0 || t.installs > 0 {
                    HStack(spacing: 10) {
                        metricText("eye", Fmt.count(t.adImpressions))
                        metricText("cursorarrow.click", Fmt.count(t.clicks))
                        metricText("arrow.down.app", Fmt.count(Int(t.installs.rounded())))
                        Spacer()
                        if let cpi = t.cpi { Text("CPI \(Fmt.money(cpi, currency))").sfont(.caption2).foregroundStyle(.secondary) }
                    }
                } else {
                    Text(campaign.state == .paused ? "Paused — no delivery in this period" : "No delivery yet")
                        .sfont(.caption2).foregroundStyle(.tertiary)
                }
                if expanded { detail(t) }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
        }
        .background(.background.opacity(expanded ? 0.55 : 0.35), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .help(campaign.name)
    }

    private func metricText(_ icon: String, _ v: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).sfont(size: 9)
            Text(v).monospacedDigit()
        }
        .sfont(.caption2).foregroundStyle(.secondary)
    }

    @ViewBuilder private func detail(_ t: Totals) -> some View {
        let days = campaign.days.filter { _ in true }
        if days.contains(where: { $0.totals.adImpressions > 0 || $0.totals.clicks > 0 }) {
            Chart {
                ForEach(days, id: \.date) { d in
                    LineMark(x: .value("Day", d.date, unit: .day), y: .value("Clicks", d.totals.clicks), series: .value("m", "Clicks"))
                        .foregroundStyle(.purple).interpolationMethod(.monotone)
                    LineMark(x: .value("Day", d.date, unit: .day), y: .value("Installs", d.totals.installs), series: .value("m", "Installs"))
                        .foregroundStyle(.green).interpolationMethod(.monotone)
                }
            }
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel().font(.system(size: 8)) } }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 8)) } }
            .frame(height: 70)
            HStack(spacing: 10) {
                Label("Clicks", systemImage: "circle.fill").foregroundStyle(.purple)
                Label("Installs", systemImage: "circle.fill").foregroundStyle(.green)
            }
            .sfont(size: 8).labelStyle(.titleAndIcon)
        }
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                cell("CTR", t.ctr.map { $0.formatted(.percent.precision(.fractionLength(2))) } ?? "—")
                cell("Install rate", t.clicks > 0 ? (t.installs / Double(t.clicks)).formatted(.percent.precision(.fractionLength(1))) : "—")
            }
            GridRow {
                cell("CPC", t.clicks > 0 && t.spend > 0 ? Fmt.money(t.spend / Double(t.clicks), currency) : "—")
                cell("CPM", t.adImpressions > 0 && t.spend > 0 ? Fmt.money(t.spend / Double(t.adImpressions) * 1000, currency) : "—")
            }
        }
        .padding(.top, 2)
    }

    private func cell(_ title: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).sfont(.caption2).foregroundStyle(.secondary)
            Text(v).sfont(.caption, weight: .medium).monospacedDigit()
        }
    }
}

/// Tiny bar sparkline.
struct MiniBars: View {
    var values: [Double]
    var color: Color
    var body: some View {
        let m = max(values.max() ?? 0, 0.000_001)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(v > 0 ? color : color.opacity(0.18))
                    .frame(height: v > 0 ? max(2, 16 * v / m) : 2)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}
