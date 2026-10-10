import SwiftUI
import Charts
import CockpitShared
import RTKKit

/// Tokens rtk kept out of the context over seven days, day by day, and the share of what it
/// filtered that this represents.
struct RTKWeekTile: View {
    @Environment(CockpitStore.self) private var store
    @State private var hovered: Date?

    private var days: [DayStat] { store.rtk?.last7Days ?? [] }
    private var saved: Int { days.reduce(0) { $0 + $1.savedTokens } }
    private var input: Int { days.reduce(0) { $0 + $1.inputTokens } }

    var body: some View {
        OverviewTile(
            title: String(localized: "RTK, 7 days"),
            icon: "leaf.fill",
            tint: Theme.emerald,
            summary: summary,
            destination: "RTK",
            action: { store.show(.rtk) }
        ) {
            TileSource(
                state: store.rtkState, ready: store.rtk != nil,
                unauthorized: String(localized: "the RTK database is outside the allowed folders."),
                retry: { Task { await store.refreshRTK() } }
            ) {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                TileValue(text: AppFormat.tokens(saved), tint: Theme.emerald)
                    .layoutPriority(1)
                bars
            }
            TileCaption(text: input > 0
                ? String(localized: "\(AppFormat.percent(Double(saved) / Double(input))) of filtered tokens saved", locale: AppFormat.locale)
                : String(localized: "No filtered commands in the last seven days."))
        }
    }

    private var bars: some View {
        Chart {
            ForEach(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Tokens", day.savedTokens))
                    .foregroundStyle(day.savedTokens > 0 ? Theme.emerald : Theme.track)
                    .opacity(hovered == nil || sameDay(hovered, day.date) ? 1 : 0.45)
            }
            if let day = days.first(where: { sameDay(hovered, $0.date) }) {
                RuleMark(x: .value("Day", day.date, unit: .day))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip(lines: [AppFormat.weekday(day.date), AppFormat.tokens(day.savedTokens)])
                    }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartHover(Date.self) { hovered = $0 }
        .frame(height: 30)
    }

    /// rtk buckets by UTC day, so the comparison is made in UTC too.
    private func sameDay(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else { return false }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.isDate(lhs, inSameDayAs: rhs)
    }

    private var summary: String {
        guard store.rtk != nil else { return "" }
        var text = String(localized: "\(AppFormat.tokens(saved)) tokens saved", locale: AppFormat.locale)
        if input > 0 { text += ", " + AppFormat.percent(Double(saved) / Double(input)) }
        return text
    }
}
