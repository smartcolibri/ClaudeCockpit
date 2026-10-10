import Foundation

/// One piece of advice for the Overview. The core says *what* it noticed, as values; the app
/// words it in the user's language and decides where a tap leads from `target`.
public struct Recommendation: Identifiable, Hashable, Sendable {
    /// Severity, in display order: the engine ranks critical first and good news last.
    public enum Level: Int, CaseIterable, Comparable, Hashable, Sendable {
        case critical, warning, info, good

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Kind: Hashable, Sendable {
        /// This week so far costs this fraction more (0.35 == +35 %) than the same stretch of last week.
        case costUp(fraction: Double)
        /// This week so far costs this fraction less (positive value) than the same stretch of last week.
        case costDown(fraction: Double)
        /// Opus takes this share of the last 30 days' cost; `project` spends the most on it.
        case opusHeavy(share: Double, project: String?)
        /// Sessions that hit a tool or API error today.
        case sessionsWithErrors(count: Int)
        /// Sessions graded D or F today.
        case lowHealthSessions(count: Int)
        /// One hour (0…23) carries this share of today's cost.
        case peakHour(hour: Int, share: Double)
        /// Cache read rate over the last 30 days, when low.
        case lowCacheRate(Double)
        /// Cache read rate over the last 30 days, when high: nothing to do.
        case goodCacheRate(Double)
        /// No rtk database was found: shell output reaches the model unfiltered.
        case rtkMissing
        /// rtk saved only this fraction of the tokens it filtered over seven days.
        case rtkLowSavings(Double)
        /// This model id has no pricing tier of its own and is costed at the Sonnet rate.
        case unpricedModel(String)
        /// The month's linear projection exceeds last month's whole cost.
        case projectionAboveLastMonth(projectionUSD: Double, lastMonthUSD: Double)
    }

    /// The screen that explains or fixes what the recommendation is about.
    public enum Target: Hashable, Sendable {
        case usage, sessions, sessionsWithErrors, rtk
    }

    public var id: String { "\(level.rawValue)-\(kind)" }
    public let level: Level
    public let kind: Kind
    public let target: Target

    public init(level: Level, kind: Kind, target: Target) {
        self.level = level
        self.kind = kind
        self.target = target
    }
}

/// Everything the engine looks at, as plain values the app gathers from each source. A source
/// that is unavailable is `nil` (or `.unknown`) and its rules simply stay silent.
public struct RecommendationInput: Hashable, Sendable {
    public struct Usage: Hashable, Sendable {
        public var costThisWeekToDateUSD: Double
        /// Last week up to the same weekday and time.
        public var costLastWeekToDateUSD: Double
        public var elapsedThisWeek: TimeInterval
        public var cost30DaysUSD: Double
        public var opusShare30Days: Double
        public var topOpusProject: String?
        /// Today's cost per hour of the day, 24 values.
        public var hourlyCostToday: [Double]
        public var cacheHitRate30Days: Double?
        public var cacheableTokens30Days: Int
        public var unpricedModels: [String]
        public var monthProjectionUSD: Double?
        public var monthElapsedDays: Double
        public var lastMonthCostUSD: Double

        public init(
            costThisWeekToDateUSD: Double = 0,
            costLastWeekToDateUSD: Double = 0,
            elapsedThisWeek: TimeInterval = 0,
            cost30DaysUSD: Double = 0,
            opusShare30Days: Double = 0,
            topOpusProject: String? = nil,
            hourlyCostToday: [Double] = [],
            cacheHitRate30Days: Double? = nil,
            cacheableTokens30Days: Int = 0,
            unpricedModels: [String] = [],
            monthProjectionUSD: Double? = nil,
            monthElapsedDays: Double = 0,
            lastMonthCostUSD: Double = 0
        ) {
            self.costThisWeekToDateUSD = costThisWeekToDateUSD
            self.costLastWeekToDateUSD = costLastWeekToDateUSD
            self.elapsedThisWeek = elapsedThisWeek
            self.cost30DaysUSD = cost30DaysUSD
            self.opusShare30Days = opusShare30Days
            self.topOpusProject = topOpusProject
            self.hourlyCostToday = hourlyCostToday
            self.cacheHitRate30Days = cacheHitRate30Days
            self.cacheableTokens30Days = cacheableTokens30Days
            self.unpricedModels = unpricedModels
            self.monthProjectionUSD = monthProjectionUSD
            self.monthElapsedDays = monthElapsedDays
            self.lastMonthCostUSD = lastMonthCostUSD
        }
    }

    public struct Sessions: Hashable, Sendable {
        public var withErrorsToday: Int
        public var lowHealthToday: Int

        public init(withErrorsToday: Int = 0, lowHealthToday: Int = 0) {
            self.withErrorsToday = withErrorsToday
            self.lowHealthToday = lowHealthToday
        }
    }

    public enum RTK: Hashable, Sendable {
        /// Not read yet, not allowed, or failing: no advice either way.
        case unknown
        /// No database found.
        case missing
        /// Seven days of rtk: the share of filtered tokens it saved, and how many commands.
        case active(savedFraction: Double, commands: Int)
    }

    public var usage: Usage?
    public var sessions: Sessions?
    public var rtk: RTK

    public init(usage: Usage? = nil, sessions: Sessions? = nil, rtk: RTK = .unknown) {
        self.usage = usage
        self.sessions = sessions
        self.rtk = rtk
    }
}
