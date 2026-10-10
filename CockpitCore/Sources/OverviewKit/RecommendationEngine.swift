import Foundation

/// Turns the Overview's figures into a short ranked list of advice. A pure function: no
/// network, no clock, no randomness — the same input always gives the same list.
///
/// Each rule fires on its own thresholds, below. The list is then ordered by severity
/// (critical, warning, info, good), ties keeping the order the rules are written in, and cut
/// to `maximumCount`, so good news only shows when nothing more pressing needs the room.
///
/// Rules flag changes and anomalies, never a permanent state of the account: advice that
/// shows every day for months stops being read.
public enum RecommendationEngine {
    public static let maximumCount = 5

    public enum Threshold {
        /// Week-over-week change worth a line, either way. Same value as the Usage insights,
        /// so the two screens agree on what counts as a notable swing.
        public static let costChange = 0.20
        /// The trend waits for a full day of the week: early on Monday last week's matching
        /// stretch is only minutes long.
        public static let minimumElapsedForTrend: TimeInterval = 24 * 3600
        /// Below this last-week baseline, ordinary spend would read as "+4 900 %".
        public static let minimumTrendBaselineUSD = 1.0

        /// Opus at or above this share of the 30-day cost is worth questioning: Sonnet does
        /// most short tasks for about a third of Opus's input price…
        public static let opusShare = 0.60
        /// …when the share rose by at least this much on the 30 days before (0.15 == 15
        /// points): someone who settled on Opus long ago does not need telling every day…
        public static let opusShareRise = 0.15
        /// …and once the 30 days cost enough for the share to be worth acting on.
        public static let minimumOpusSpendUSD = 5.0

        /// Sessions with errors today: from one it is a warning, from this many critical.
        public static let criticalErrorSessions = 3

        /// One hour carrying this share of today's cost reads as a burst.
        public static let peakHourShare = 0.40
        /// …provided today cost at least this much, over at least this many active hours:
        /// with one or two hours of work, any of them "carries" the day.
        public static let minimumPeakDayCostUSD = 1.0
        public static let minimumActiveHours = 3

        /// Cache read rate below this is low: prompts rebuilt instead of reused. There is no
        /// "good cache" note — with Claude Code it would show on every account, every day.
        public static let lowCacheRate = 0.30
        /// A rate needs this many prompt tokens over 30 days to mean anything.
        public static let minimumCacheableTokens = 1_000_000

        /// rtk saving less than this share of what it filtered is not doing much…
        public static let lowRTKSavings = 0.30
        /// …judged over at least this many commands in seven days.
        public static let minimumRTKCommands = 20

        /// The month's projection is flagged at this multiple of last month's cost…
        public static let projectionRise = 1.25
        /// …from this many days into the month (a projection over two days is noise)…
        public static let minimumMonthElapsedDays = 3.0
        /// …against a last month that cost at least this much.
        public static let minimumLastMonthUSD = 5.0
    }

    public static func recommend(_ input: RecommendationInput, limit: Int = maximumCount) -> [Recommendation] {
        var found: [Recommendation] = []
        let usage = input.usage
        let sessions = input.sessions

        if let sessions, sessions.withErrorsToday > 0 {
            found.append(Recommendation(
                level: sessions.withErrorsToday >= Threshold.criticalErrorSessions ? .critical : .warning,
                kind: .sessionsWithErrors(count: sessions.withErrorsToday),
                target: .sessionsWithErrors))
        }

        if let usage, let trend = costTrend(usage) { found.append(trend) }

        if let sessions, sessions.lowHealthToday > 0 {
            found.append(Recommendation(
                level: .warning, kind: .lowHealthSessions(count: sessions.lowHealthToday), target: .sessions))
        }

        if let usage, usage.cost30DaysUSD >= Threshold.minimumOpusSpendUSD,
           usage.opusShare30Days >= Threshold.opusShare,
           usage.opusShare30Days - usage.opusSharePrevious30Days >= Threshold.opusShareRise {
            found.append(Recommendation(
                level: .info,
                kind: .opusShareRose(
                    share: usage.opusShare30Days, previous: usage.opusSharePrevious30Days,
                    project: usage.topOpusProject),
                target: .usage))
        }

        if let usage, let peak = peakHour(usage.hourlyCostToday) { found.append(peak) }

        if let usage, let rate = usage.cacheHitRate30Days,
           usage.cacheableTokens30Days >= Threshold.minimumCacheableTokens, rate < Threshold.lowCacheRate {
            found.append(Recommendation(level: .warning, kind: .lowCacheRate(rate), target: .usage))
        }

        switch input.rtk {
        case .missing:
            found.append(Recommendation(level: .info, kind: .rtkMissing, target: .rtk))
        case .active(let saved, let commands) where commands >= Threshold.minimumRTKCommands && saved < Threshold.lowRTKSavings:
            found.append(Recommendation(level: .info, kind: .rtkLowSavings(saved), target: .rtk))
        case .active, .unknown:
            break
        }

        if let usage {
            for model in usage.unpricedModels.sorted() {
                found.append(Recommendation(level: .warning, kind: .unpricedModel(model), target: .usage))
            }
            if let projection = usage.monthProjectionUSD,
               usage.monthElapsedDays >= Threshold.minimumMonthElapsedDays,
               usage.lastMonthCostUSD >= Threshold.minimumLastMonthUSD,
               projection >= usage.lastMonthCostUSD * Threshold.projectionRise {
                found.append(Recommendation(
                    level: .warning,
                    kind: .projectionAboveLastMonth(projectionUSD: projection, lastMonthUSD: usage.lastMonthCostUSD),
                    target: .usage))
            }
        }

        // Stable by construction: the rule order breaks ties between equal levels.
        let ranked = found.enumerated()
            .sorted { $0.element.level != $1.element.level ? $0.element.level < $1.element.level : $0.offset < $1.offset }
            .map(\.element)
        return Array(ranked.prefix(max(0, limit)))
    }

    private static func costTrend(_ usage: RecommendationInput.Usage) -> Recommendation? {
        guard usage.elapsedThisWeek >= Threshold.minimumElapsedForTrend,
              usage.costLastWeekToDateUSD >= Threshold.minimumTrendBaselineUSD
        else { return nil }
        let change = (usage.costThisWeekToDateUSD - usage.costLastWeekToDateUSD) / usage.costLastWeekToDateUSD
        if change >= Threshold.costChange {
            return Recommendation(level: .warning, kind: .costUp(fraction: change), target: .usage)
        }
        if change <= -Threshold.costChange {
            return Recommendation(level: .good, kind: .costDown(fraction: -change), target: .usage)
        }
        return nil
    }

    private static func peakHour(_ hourly: [Double]) -> Recommendation? {
        guard hourly.count == 24 else { return nil }
        let total = hourly.reduce(0, +)
        let active = hourly.filter { $0 > 0 }.count
        guard total >= Threshold.minimumPeakDayCostUSD, active >= Threshold.minimumActiveHours else { return nil }
        // The first of equal peaks, so the answer never depends on iteration order.
        var peak = 0
        for hour in 1..<24 where hourly[hour] > hourly[peak] { peak = hour }
        let share = hourly[peak] / total
        guard share >= Threshold.peakHourShare else { return nil }
        return Recommendation(level: .info, kind: .peakHour(hour: peak, share: share), target: .usage)
    }
}
