import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// Today's cost, the last 14 days as a sparkline, how today compares with the 30-day mean
/// and where the month is heading.
struct TodayCostTile: View {
    @Environment(CockpitStore.self) private var store
    @State private var hovered: Date?

    private var overview: UsageOverview? { store.usage?.overview }

    var body: some View {
        OverviewTile(
            title: String(localized: "Today's cost"),
            icon: "banknote",
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TileValue(text: store.money(overview.today.estimatedCostUSD), tint: Theme.blue)
                    .layoutPriority(1)
                sparkline(overview.recentDailyCost(14))
            }
            if let delta = delta(overview) {
                TileCaption(text: deltaText(delta), tint: delta >= 0 ? .orange : Theme.emerald)
            } else {
                TileCaption(text: String(localized: "No spend in the last 30 days"))
            }
            if let projection = overview.monthProjectionUSD {
                TileCaption(text: String(localized: "Month on track for \(store.money(projection))", locale: AppFormat.locale))
            } else {
                TileCaption(text: String(localized: "\(store.money(overview.monthToDateCostUSD)) this month", locale: AppFormat.locale))
            }
        }
    }

    private func sparkline(_ days: [UsageOverview.DayCost]) -> some View {
        Chart {
            ForEach(days) { day in
                LineMark(x: .value("Day", day.day, unit: .day), y: .value("Cost", day.costUSD))
                    .foregroundStyle(Theme.blue)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            if let hovered, let point = days.first(where: { Calendar.current.isDate($0.day, inSameDayAs: hovered) }) {
                PointMark(x: .value("Day", point.day, unit: .day), y: .value("Cost", point.costUSD))
                    .foregroundStyle(Theme.blue)
                    .symbolSize(24)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(lines: [AppFormat.shortDate(point.day), store.money(point.costUSD)])
                    }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartHover(Date.self) { hovered = $0 }
        .frame(height: 30)
        .accessibilityLabel(String(localized: "Cost over the last 14 days"))
    }

    /// Today against the 30-day mean, as a fraction; `nil` without a mean to compare with.
    private func delta(_ overview: UsageOverview) -> Double? {
        guard overview.meanDailyCostUSD > 0 else { return nil }
        return (overview.today.estimatedCostUSD - overview.meanDailyCostUSD) / overview.meanDailyCostUSD
    }

    private func deltaText(_ delta: Double) -> String {
        let percent = AppFormat.percent(abs(delta))
        return delta >= 0
            ? String(localized: "▲ \(percent) vs 30-day average", locale: AppFormat.locale)
            : String(localized: "▼ \(percent) vs 30-day average", locale: AppFormat.locale)
    }

    private var summary: String {
        guard let overview else { return "" }
        var parts = [store.money(overview.today.estimatedCostUSD)]
        if let delta = delta(overview) { parts.append(deltaText(delta)) }
        if let projection = overview.monthProjectionUSD {
            parts.append(String(localized: "Month on track for \(store.money(projection))", locale: AppFormat.locale))
        }
        return parts.joined(separator: ", ")
    }
}
