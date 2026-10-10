import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// Cost per day over 30 days, each bar stacked by model family.
struct CostPerDayTile: View {
    @Environment(CockpitStore.self) private var store
    @State private var hovered: Date?

    private var overview: UsageOverview? { store.usage?.overview }

    var body: some View {
        OverviewTile(
            title: String(localized: "Cost per day, 30 days"),
            icon: "chart.bar.fill",
            summary: summary,
            destination: CockpitSection.usage.title,
            action: { store.show(.usage) }
        ) {
            TileSource(
                state: store.usageState, ready: overview != nil,
                unauthorized: String(localized: "the transcripts cannot be read."),
                retry: { Task { await store.refreshUsage() } }
            ) {
                if let overview { content(overview) }
            }
        }
    }

    private func content(_ overview: UsageOverview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(verbatim: store.money(overview.cost30DaysUSD))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                ForEach(overview.modelMix) { row in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(row.family.color).frame(width: 7, height: 7)
                        Text(verbatim: row.family.label).font(.system(size: 10)).foregroundStyle(Theme.slate)
                    }
                }
            }
            chart(overview)
        }
    }

    private func chart(_ overview: UsageOverview) -> some View {
        let money = { (value: Double) in store.money(value) }
        return Chart {
            ForEach(overview.costByDayAndFamily) { point in
                BarMark(x: .value("Day", point.day, unit: .day), y: .value("Cost", point.costUSD))
                    .foregroundStyle(by: .value("Model", point.family.label))
                    .opacity(hovered == nil || Calendar.current.isDate(point.day, inSameDayAs: hovered!) ? 1 : 0.5)
            }
            if let day = hoveredDay(overview) {
                RuleMark(x: .value("Day", day, unit: .day))
                    .foregroundStyle(Theme.slate.opacity(0.25))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartTooltip(lines: tooltip(day, overview))
                    }
            }
        }
        .chartForegroundStyleScale(domain: ModelFamily.allCases.map(\.label), range: ModelFamily.allCases.map(\.color))
        .chartLegend(.hidden)
        .chartXScale(domain: (overview.last30Days.first ?? Date())...(overview.last30Days.last.flatMap {
            Calendar.current.date(byAdding: .day, value: 1, to: $0)
        } ?? Date()))
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: false)
                    .foregroundStyle(Theme.slate)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.cardStroke)
                AxisValueLabel {
                    if let cost = value.as(Double.self) { Text(verbatim: money(cost)).foregroundStyle(Theme.slate) }
                }
            }
        }
        .chartHover(Date.self) { hovered = $0 }
        .frame(minHeight: 110)
    }

    private func hoveredDay(_ overview: UsageOverview) -> Date? {
        guard let hovered else { return nil }
        return overview.last30Days.first { Calendar.current.isDate($0, inSameDayAs: hovered) }
    }

    private func tooltip(_ day: Date, _ overview: UsageOverview) -> [String] {
        let rows = overview.costByDayAndFamily.filter { $0.day == day }
        let total = rows.reduce(0) { $0 + $1.costUSD }
        return ["\(AppFormat.shortDate(day)) · \(store.money(total))"]
            + rows.reversed().map { "\($0.family.label) \(store.money($0.costUSD))" }
    }

    private var summary: String {
        guard let overview else { return "" }
        return ([store.money(overview.cost30DaysUSD)]
            + overview.modelMix.map { "\($0.family.label) \(store.money($0.costUSD))" }).joined(separator: ", ")
    }
}
