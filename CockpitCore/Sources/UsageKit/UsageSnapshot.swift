import Foundation

/// Everything the usage screens display, computed once per refresh by `UsageAggregator`.
/// Immutable and `Sendable`: the app stores it and reads it from the main actor.
public struct UsageSnapshot: Sendable {
    /// When the snapshot was computed — the "now" used by every fixed window below.
    public let generatedAt: Date
    public let filters: UsageFilters
    public let pricing: PricingSettings

    /// How many events survived the model/project/range filters. Only the count is kept:
    /// the UI just needs to know whether the filtered set is empty, and retaining the whole
    /// array would pin every event on the main actor for the snapshot's lifetime.
    public let filteredEventCount: Int
    public let totals: UsageSummary

    public let costByFamily: [ModelCostRow]
    public let sessions: [SessionSummary]
    private let breakdowns: [BreakdownDimension: [BreakdownRow]]

    /// Cost and tokens recorded since midnight, and distinct sessions this ISO week and last,
    /// with no filter at all: the menu bar's figures must not move when the Usage screen's
    /// pickers do.
    public let costTodayUnfilteredUSD: Double
    public let tokensTodayUnfiltered: Int
    public let sessionsThisWeekUnfilteredTotal: Int
    public let sessionsLastWeekUnfilteredTotal: Int
    /// The Overview screen's figures, from every event whatever the filters.
    public let overview: UsageOverview
    /// The Usage screen's series over the filtered period.
    public let period: UsagePeriod

    /// Options for the filter pickers, derived from the whole event set.
    public let availableProjects: [String]
    public let availableModelFamilies: [ModelFamily]

    public init(
        generatedAt: Date,
        filters: UsageFilters,
        pricing: PricingSettings,
        filteredEventCount: Int,
        totals: UsageSummary,
        costByFamily: [ModelCostRow],
        sessions: [SessionSummary],
        breakdowns: [BreakdownDimension: [BreakdownRow]],
        costTodayUnfilteredUSD: Double,
        tokensTodayUnfiltered: Int,
        sessionsThisWeekUnfilteredTotal: Int,
        sessionsLastWeekUnfilteredTotal: Int,
        overview: UsageOverview,
        period: UsagePeriod = .empty,
        availableProjects: [String],
        availableModelFamilies: [ModelFamily]
    ) {
        self.generatedAt = generatedAt
        self.filters = filters
        self.pricing = pricing
        self.filteredEventCount = filteredEventCount
        self.totals = totals
        self.costByFamily = costByFamily
        self.sessions = sessions
        self.breakdowns = breakdowns
        self.costTodayUnfilteredUSD = costTodayUnfilteredUSD
        self.tokensTodayUnfiltered = tokensTodayUnfiltered
        self.sessionsThisWeekUnfilteredTotal = sessionsThisWeekUnfilteredTotal
        self.sessionsLastWeekUnfilteredTotal = sessionsLastWeekUnfilteredTotal
        self.overview = overview
        self.period = period
        self.availableProjects = availableProjects
        self.availableModelFamilies = availableModelFamilies
    }

    /// Breakdown rows for one dimension, sorted by cost descending.
    public func breakdown(for dimension: BreakdownDimension) -> [BreakdownRow] {
        breakdowns[dimension] ?? []
    }

    /// An empty snapshot, for the app's initial state.
    public static func empty(
        filters: UsageFilters = UsageFilters(),
        pricing: PricingSettings = .default,
        now: Date = Date()
    ) -> UsageSnapshot {
        UsageAggregator.snapshot(events: [], filters: filters, pricing: pricing, now: now)
    }
}
