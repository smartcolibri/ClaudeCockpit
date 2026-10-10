import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// Estimated cost over the period, its shape as a sparkline and how it compares with the
/// previous period of equal length.
struct UsageCostTile: View {
    @Environment(CockpitStore.self) private var store

    var body: some View {
        OverviewTile(title: String(localized: "Estimated cost"), icon: "creditcard", summary: summary) {
            UsageSource { usage in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .bottom, spacing: 8) {
                        TileValue(text: store.money(usage.totals.estimatedCostUSD), tint: Theme.blue)
                            .layoutPriority(1)
                        sparkline(usage.period.buckets)
                    }
                    let delta = deltaCaption(usage)
                    TileCaption(text: delta.text, tint: delta.tint)
                    TileCaption(text: String(localized: "API rates, approximate"))
                }
            }
        }
    }

    @ViewBuilder
    private func sparkline(_ buckets: [UsagePeriod.Bucket]) -> some View {
        if buckets.count > 1 {
            Chart(buckets) { bucket in
                LineMark(x: .value("Bucket", bucket.index), y: .value("Cost", bucket.costUSD))
                    .foregroundStyle(Theme.blue)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(buckets.map(\.costUSD).max() ?? 0, 0.0001))
            .frame(height: 28)
            .accessibilityHidden(true)
        }
    }

    /// The window the delta compares with, worded per range.
    static func comparison(_ range: DateRangeFilter) -> String? {
        switch range {
        case .today: String(localized: "vs yesterday at this time")
        case .thisWeek: String(localized: "vs last week at this point")
        case .thisMonth: String(localized: "vs last month at this point")
        case .prevMonth: String(localized: "vs the month before")
        case .last7Days: String(localized: "vs the previous 7 days")
        case .last30Days: String(localized: "vs the previous 30 days")
        case .last90Days: String(localized: "vs the previous 90 days")
        case .all: nil
        }
    }

    private func deltaCaption(_ usage: UsageSnapshot) -> (text: String, tint: Color) {
        guard let comparison = Self.comparison(usage.filters.range), let previous = usage.period.previousCostUSD else {
            return (String(localized: "All recorded history"), Theme.slate)
        }
        guard previous > 0 else { return (String(localized: "No spend in the previous period"), Theme.slate) }
        let delta = (usage.totals.estimatedCostUSD - previous) / previous
        // Arrows and the percentage are not words: the sentence is the comparison's.
        return ("\(delta >= 0 ? "▲" : "▼") \(AppFormat.percent(abs(delta))) \(comparison)",
                delta >= 0 ? .orange : Theme.emerald)
    }

    private var summary: String {
        guard let usage = store.usage else { return "" }
        return [store.money(usage.totals.estimatedCostUSD), deltaCaption(usage).text].joined(separator: ", ")
    }
}

/// Distinct sessions over the period and their mean per elapsed day.
struct UsageSessionsTile: View {
    @Environment(CockpitStore.self) private var store

    var body: some View {
        OverviewTile(title: String(localized: "Sessions"), icon: "bubble.left.and.bubble.right", summary: lines.joined(separator: ", ")) {
            UsageSource { usage in
                VStack(alignment: .leading, spacing: 4) {
                    TileValue(text: AppFormat.integer(usage.totals.sessionCount))
                    ForEach(captions(usage), id: \.self) { TileCaption(text: $0) }
                }
            }
        }
    }

    private func captions(_ usage: UsageSnapshot) -> [String] {
        let days = max(1, usage.period.elapsedDays)
        return [
            String(localized: "\(AppFormat.decimal(Double(usage.totals.sessionCount) / Double(days))) per day", locale: AppFormat.locale),
            String(localized: "over \(days) days", locale: AppFormat.locale),
        ]
    }

    private var lines: [String] {
        guard let usage = store.usage else { return [] }
        return [AppFormat.integer(usage.totals.sessionCount)] + captions(usage)
    }
}

/// Turns over the period, per session and per day.
struct UsageTurnsTile: View {
    @Environment(CockpitStore.self) private var store

    var body: some View {
        OverviewTile(title: String(localized: "Turns"), icon: "arrow.triangle.2.circlepath", summary: lines.joined(separator: ", ")) {
            UsageSource { usage in
                VStack(alignment: .leading, spacing: 4) {
                    TileValue(text: AppFormat.tokens(usage.totals.turnCount))
                    ForEach(captions(usage), id: \.self) { TileCaption(text: $0) }
                }
            }
        }
    }

    private func captions(_ usage: UsageSnapshot) -> [String] {
        let totals = usage.totals
        let perSession = totals.sessionCount > 0 ? Int((Double(totals.turnCount) / Double(totals.sessionCount)).rounded()) : 0
        let perDay = Double(totals.turnCount) / Double(max(1, usage.period.elapsedDays))
        return [
            String(localized: "\(AppFormat.integer(perSession)) per session", locale: AppFormat.locale),
            String(localized: "\(AppFormat.decimal(perDay)) per day", locale: AppFormat.locale),
        ]
    }

    private var lines: [String] {
        guard let usage = store.usage else { return [] }
        return [AppFormat.tokens(usage.totals.turnCount)] + captions(usage)
    }
}

/// Every token of the period, and how it splits between the four kinds.
struct UsageTokensTile: View {
    @Environment(CockpitStore.self) private var store

    var body: some View {
        OverviewTile(title: String(localized: "Tokens"), icon: "number.circle", summary: summary) {
            UsageSource { usage in
                VStack(alignment: .leading, spacing: 7) {
                    TileValue(text: AppFormat.tokens(usage.totals.totalTokens))
                    TokenSplitBar(parts: usage.totals.tokenParts)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 3) {
                        ForEach(usage.totals.tokenParts, id: \.0) { series, value in
                            HStack(spacing: 4) {
                                Circle().fill(series.color).frame(width: 6, height: 6)
                                Text(verbatim: "\(series.displayName) \(AppFormat.tokens(value))")
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.slate)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                }
            }
        }
    }

    private var summary: String {
        guard let totals = store.usage?.totals else { return "" }
        return ([AppFormat.tokens(totals.totalTokens)] + totals.tokenParts.map { "\($0.0.displayName) \(AppFormat.tokens($0.1))" })
            .joined(separator: ", ")
    }
}
