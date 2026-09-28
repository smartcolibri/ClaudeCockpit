import Foundation

/// Derives automatic signals from the currently filtered usage — cost trend versus last week,
/// pricing gaps, cache efficiency. A pure function of its inputs.
public enum InsightEngine {
    /// Cost swings below this magnitude aren't called out — avoids noisy "+3 % vs last week"
    /// insights on ordinary day-to-day variance.
    public static let notableCostChange = 0.20
    public static let notableCacheHitRate = 0.50
    /// The week-over-week trend waits for this much of the week to have elapsed: early on
    /// Monday last week's matching stretch is only minutes long, and any spend reads as a
    /// huge jump.
    public static let minimumElapsedForCostTrend: TimeInterval = 24 * 3600
    /// Below this last-week baseline the trend is skipped: a few cents last week would turn
    /// ordinary spend into "+4900 %".
    public static let minimumBaselineCostUSD = 1.0

    /// - Parameters:
    ///   - thisWeekCostUSD: cost of the current week so far.
    ///   - lastWeekCostUSD: cost of last week up to the same point in the week, so the two
    ///     figures cover comparable stretches of time.
    ///   - elapsedThisWeek: time since the start of the current week.
    public static func derive(
        events: [UsageEvent],
        thisWeekCostUSD: Double,
        lastWeekCostUSD: Double,
        elapsedThisWeek: TimeInterval,
        pricingSettings: PricingSettings
    ) -> [Insight] {
        var insights: [Insight] = []

        if elapsedThisWeek >= minimumElapsedForCostTrend, lastWeekCostUSD >= minimumBaselineCostUSD {
            let change = (thisWeekCostUSD - lastWeekCostUSD) / lastWeekCostUSD
            if change >= notableCostChange {
                insights.append(Insight(
                    level: .critical,
                    kind: .costUp(fraction: change),
                    text: "Cost is up \(percent(change)) vs the same point last week."))
            } else if change <= -notableCostChange {
                insights.append(Insight(
                    level: .good,
                    kind: .costDown(fraction: abs(change)),
                    text: "Cost is down \(percent(abs(change))) vs the same point last week."))
            }
        }

        let unpricedModels = Set(events.map(\.model)).filter { !pricingSettings.hasDedicatedTier(forModel: $0) }
        for model in unpricedModels.sorted() {
            insights.append(Insight(
                level: .warning,
                kind: .unpricedModel(model),
                text: "\(model) has no dedicated pricing tier — using the Sonnet default rate."))
        }

        let cacheReadTokens = events.reduce(0) { $0 + $1.cacheReadTokens }
        let cacheableTokens = cacheReadTokens + events.reduce(0) { $0 + $1.inputTokens }
        if cacheableTokens > 0 {
            let hitRate = Double(cacheReadTokens) / Double(cacheableTokens)
            if hitRate >= notableCacheHitRate {
                insights.append(Insight(
                    level: .good,
                    kind: .cacheHitRate(hitRate),
                    text: "Cache hit rate at \(percent(hitRate)) — keeping costs down."))
            }
        }

        if insights.isEmpty {
            insights.append(Insight(
                level: .info,
                kind: .noNotableChange,
                text: "No notable changes in this range."))
        }
        return insights
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
