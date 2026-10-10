import SwiftUI
import CockpitShared
import UsageKit

/// The seven KPI tiles above the charts: volume, then the four token buckets, then cost.
struct UsageStatGrid: View {
    let totals: UsageSummary
    let range: DateRangeFilter
    let money: (Double) -> String

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)]

    private var rangeNote: String {
        range == .all ? String(localized: "over all history") : String(localized: "over “\(range.displayName.lowercased())”")
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                label: String(localized: "Sessions"),
                value: AppFormat.integer(totals.sessionCount),
                note: rangeNote,
                icon: "bubble.left.and.bubble.right")
            StatTile(
                label: String(localized: "Turns"),
                value: AppFormat.tokens(totals.turnCount),
                note: rangeNote,
                icon: "arrow.triangle.2.circlepath")
            StatTile(
                label: String(localized: "Input"),
                value: AppFormat.tokens(totals.inputTokens),
                note: String(localized: "tokens sent"),
                tint: UsagePalette.input,
                icon: "arrow.down.circle")
            StatTile(
                label: String(localized: "Output"),
                value: AppFormat.tokens(totals.outputTokens),
                note: String(localized: "tokens generated"),
                tint: UsagePalette.output,
                icon: "arrow.up.circle")
            StatTile(
                label: String(localized: "Cache read"),
                value: AppFormat.tokens(totals.cacheReadTokens),
                note: String(localized: "prompt cache reads"),
                tint: UsagePalette.cacheRead,
                icon: "arrow.clockwise.circle")
            StatTile(
                label: String(localized: "Cache written"),
                value: AppFormat.tokens(totals.cacheCreationTokens),
                note: String(localized: "cache writes"),
                tint: UsagePalette.cacheCreation,
                icon: "square.stack.3d.up")
            StatTile(
                label: String(localized: "Estimated cost"),
                value: money(totals.estimatedCostUSD),
                note: String(localized: "API rates, approximate"),
                tint: Theme.blue,
                icon: "creditcard")
        }
    }
}
