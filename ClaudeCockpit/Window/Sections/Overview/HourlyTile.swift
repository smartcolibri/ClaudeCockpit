import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// Today's cost hour by hour as bars, yesterday's as a dashed line behind them.
struct HourlyTile: View {
    @Environment(CockpitStore.self) private var store
    @State private var hovered: Int?

    private var overview: UsageOverview? { store.usage?.overview }

    var body: some View {
        OverviewTile(
            title: String(localized: "By hour"),
            icon: "clock.fill",
            summary: summary,
            destination: CockpitSection.usage.title,
            action: { store.show(.usage) }
        ) {
            TileSource(
                state: store.usageState, ready: overview != nil,
                unauthorized: String(localized: "the transcripts cannot be read."),
                retry: { Task { await store.refreshUsage() } }
            ) {
                if let overview {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            legend(String(localized: "Today"), dashed: false)
                            legend(String(localized: "Yesterday"), dashed: true)
                        }
                        chart(overview)
                    }
                }
            }
        }
    }

    private func chart(_ overview: UsageOverview) -> some View {
        Chart {
            ForEach(overview.hourlyYesterday) { bucket in
                LineMark(x: .value("Hour", bucket.hour), y: .value("Cost", bucket.estimatedCostUSD),
                         series: .value("Day", "yesterday"))
                    .foregroundStyle(UsagePalette.context)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .interpolationMethod(.monotone)
            }
            ForEach(overview.hourlyToday) { bucket in
                BarMark(x: .value("Hour", bucket.hour), y: .value("Cost", bucket.estimatedCostUSD), width: .fixed(5))
                    .foregroundStyle(Theme.blue.opacity(hovered == nil || hovered == bucket.hour ? 1 : 0.5))
            }
            if let hour = hovered, (0..<24).contains(hour) {
                RuleMark(x: .value("Hour", hour))
                    .foregroundStyle(Theme.slate.opacity(0.25))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartTooltip(lines: [
                            String(localized: "\(hour) h – \(hour + 1) h", locale: AppFormat.locale),
                            String(localized: "Today \(store.money(overview.hourlyToday[hour].estimatedCostUSD))", locale: AppFormat.locale),
                            String(localized: "Yesterday \(store.money(overview.hourlyYesterday[hour].estimatedCostUSD))", locale: AppFormat.locale),
                        ])
                    }
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(String(localized: "\(hour) h", locale: AppFormat.locale)).foregroundStyle(Theme.slate)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartHover(Double.self) { value in hovered = value.map { Int($0.rounded()) } }
        .frame(minHeight: 52)
    }

    private func legend(_ title: String, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            if dashed {
                Text(verbatim: "┄").font(.system(size: 10, weight: .bold)).foregroundStyle(UsagePalette.context)
            } else {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.blue).frame(width: 7, height: 7)
            }
            Text(verbatim: title).font(.system(size: 10)).foregroundStyle(Theme.slate)
        }
    }

    private var summary: String {
        guard let overview else { return "" }
        let today = overview.hourlyToday.reduce(0) { $0 + $1.estimatedCostUSD }
        let yesterday = overview.hourlyYesterday.reduce(0) { $0 + $1.estimatedCostUSD }
        return [String(localized: "Today \(store.money(today))", locale: AppFormat.locale),
                String(localized: "Yesterday \(store.money(yesterday))", locale: AppFormat.locale)].joined(separator: ", ")
    }
}
