import Foundation
import CockpitShared

/// Turns a flat event list into everything the usage screens display. A pure function of its
/// inputs — the computation the source app's `UsageViewModel` did in `recomputeFiltered` and
/// `recomputeFixedWindows`, with no observable state of its own.
public enum UsageAggregator {
    public static func snapshot(
        events scannedEvents: [UsageEvent],
        sessionInfo: [String: SessionInfo] = [:],
        filters: UsageFilters = UsageFilters(),
        pricing: PricingSettings = .default,
        now: Date = Date(),
        calendar: Calendar = .current,
        home: URL = ClaudePaths.realHome,
        overview precomputed: UsageOverview? = nil
    ) -> UsageSnapshot {
        // Placeholder turns go before anything is counted, so every figure, chip and list agree.
        let allEvents = scannedEvents.filter { !$0.isSynthetic }
        // Model/project filtering only: the previous period needs the events before the range.
        let unranged = allEvents.filter(filters.matchesModelAndProject)

        let filtered = rangedEvents(unranged, range: filters.range, now: now, calendar: calendar)

        // MARK: Totals

        var totals = UsageSummary()
        totals.turnCount = filtered.count
        totals.sessionCount = Set(filtered.map(\.sessionId)).count
        for event in filtered {
            totals.inputTokens += event.inputTokens
            totals.outputTokens += event.outputTokens
            totals.cacheReadTokens += event.cacheReadTokens
            totals.cacheCreationTokens += event.cacheCreationTokens
        }
        totals.estimatedCostUSD = PricingCalculator.estimatedCostUSD(for: filtered, pricing: pricing)

        // MARK: Sessions

        var eventsBySession: [String: [UsageEvent]] = [:]
        for event in filtered {
            eventsBySession[event.sessionId, default: []].append(event)
        }
        let sessions = eventsBySession
            .compactMap { sessionId, sessionEvents in
                SessionSummary(
                    sessionId: sessionId,
                    events: sessionEvents,
                    info: sessionInfo[sessionId],
                    pricing: pricing)
            }
            .sorted { $0.lastSeen > $1.lastSeen }

        // MARK: Cost by family and breakdowns

        var costByFamilyMap: [ModelFamily: Double] = [:]
        // Accumulates cost per key rather than collecting each key's events into an array
        // first: a growing `[UsageEvent]` inside a dictionary value forces a full array copy
        // on every append, an O(n²) blowup once one key absorbs most events. Each dimension
        // gets its own flat local dictionary for the same reason — a nested
        // `[Dimension: [String: …]]` would copy the inner dictionary on every write.
        var projectBuckets: [String: Bucket] = [:]
        var modelBuckets: [String: Bucket] = [:]
        var agentBuckets: [String: Bucket] = [:]
        var skillBuckets: [String: Bucket] = [:]
        // Project labels repeat heavily, so the `~`-shortening is memoized per `cwd`.
        var shortenedPaths: [String: String] = [:]

        for event in filtered {
            let cost = pricing.pricing(forModel: event.model).cost(for: event)
            costByFamilyMap[ModelFamily.detect(from: event.model), default: 0] += cost
            let tokens = event.totalTokens

            let projectKey: String
            if let cached = shortenedPaths[event.cwd] {
                projectKey = cached
            } else {
                projectKey = UsagePath.shorten(event.cwd, home: home)
                shortenedPaths[event.cwd] = projectKey
            }
            let session = event.sessionId
            projectBuckets[projectKey, default: Bucket()].add(tokens: tokens, cost: cost, session: session)
            modelBuckets[event.model, default: Bucket()].add(tokens: tokens, cost: cost, session: session)
            agentBuckets[event.attributionAgent ?? BreakdownDimension.directLabel, default: Bucket()]
                .add(tokens: tokens, cost: cost, session: session)
            skillBuckets[event.attributionSkill ?? BreakdownDimension.directLabel, default: Bucket()]
                .add(tokens: tokens, cost: cost, session: session)
        }

        let costByFamily = ModelFamily.allCases.compactMap { family -> ModelCostRow? in
            guard let cost = costByFamilyMap[family], cost > 0 else { return nil }
            return ModelCostRow(family: family, costUSD: cost)
        }
        let breakdowns: [BreakdownDimension: [BreakdownRow]] = [
            .project: rows(from: projectBuckets),
            .model: rows(from: modelBuckets),
            .agent: rows(from: agentBuckets),
            .skill: rows(from: skillBuckets),
        ]

        // MARK: Headline weeks (no filter at all)

        // The menu bar's weekly context lines must not move with the Usage screen's pickers.
        var isoCalendar = Calendar(identifier: .iso8601)
        isoCalendar.timeZone = calendar.timeZone
        let todayStart = calendar.startOfDay(for: now)
        let thisWeekStart = isoCalendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        let lastWeekStart = isoCalendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let allTodayEvents = allEvents.filter { $0.timestamp >= todayStart && $0.timestamp < todayEnd }
        let costTodayUnfilteredUSD = PricingCalculator.estimatedCostUSD(for: allTodayEvents, pricing: pricing)
        let tokensTodayUnfiltered = allTodayEvents.reduce(0) { $0 + $1.totalTokens }
        let sessionsThisWeekUnfiltered = weeklySessionTotal(events: allEvents, weekStart: thisWeekStart, calendar: isoCalendar)
        let sessionsLastWeekUnfiltered = weeklySessionTotal(events: allEvents, weekStart: lastWeekStart, calendar: isoCalendar)

        // MARK: Picker options (whole event set, before any filter)

        let availableProjects = Array(Set(allEvents.map(\.cwd))).sorted()
        let presentFamilies = Set(allEvents.map { ModelFamily.detect(from: $0.model) })
        let availableModelFamilies = ModelFamily.allCases.filter(presentFamilies.contains)

        return UsageSnapshot(
            generatedAt: now,
            filters: filters,
            pricing: pricing,
            filteredEventCount: filtered.count,
            totals: totals,
            costByFamily: costByFamily,
            sessions: sessions,
            breakdowns: breakdowns,
            costTodayUnfilteredUSD: costTodayUnfilteredUSD,
            tokensTodayUnfiltered: tokensTodayUnfiltered,
            sessionsThisWeekUnfilteredTotal: sessionsThisWeekUnfiltered,
            sessionsLastWeekUnfilteredTotal: sessionsLastWeekUnfiltered,
            overview: precomputed ?? overview(events: scannedEvents, pricing: pricing, now: now, calendar: calendar, home: home),
            period: period(ranged: filtered, unranged: unranged, horizon: allEvents.lazy.map(\.timestamp).min(),
                           range: filters.range, pricing: pricing, now: now, calendar: calendar),
            availableProjects: availableProjects,
            availableModelFamilies: availableModelFamilies)
    }

    // MARK: - Helpers

    /// Applies the range filter and sorts the survivors oldest first. Split out of
    /// `snapshot(…)` so the ordering the series and breakdowns rely on stays directly
    /// testable now that the snapshot only carries the filtered *count*.
    static func rangedEvents(
        _ events: [UsageEvent],
        range: DateRangeFilter,
        now: Date,
        calendar: Calendar
    ) -> [UsageEvent] {
        let (start, end) = range.bounds(now: now, calendar: calendar)
        var filtered = events.filter { event in
            if let start, event.timestamp < start { return false }
            if let end, event.timestamp >= end { return false }
            return true
        }
        filtered.sort { $0.timestamp < $1.timestamp }
        return filtered
    }

    /// One breakdown key's running totals. A struct mutated in place through the dictionary's
    /// `default:` subscript, so no copy happens per event.
    private struct Bucket {
        var turns = 0
        var tokens = 0
        var cost = 0.0
        var sessions = Set<String>()

        mutating func add(tokens newTokens: Int, cost newCost: Double, session: String) {
            turns += 1
            tokens += newTokens
            cost += newCost
            sessions.insert(session)
        }
    }

    private static func rows(from buckets: [String: Bucket]) -> [BreakdownRow] {
        buckets
            .map { key, bucket in
                BreakdownRow(
                    label: key,
                    turnCount: bucket.turns,
                    totalTokens: bucket.tokens,
                    estimatedCostUSD: bucket.cost,
                    sessionCount: bucket.sessions.count)
            }
            .sorted { lhs, rhs in
                // Cost descending, then label ascending so the order is stable.
                if lhs.estimatedCostUSD != rhs.estimatedCostUSD {
                    return lhs.estimatedCostUSD > rhs.estimatedCostUSD
                }
                return lhs.label < rhs.label
            }
    }

    /// Distinct sessions across the whole week, deduped once over the 7-day window — summing
    /// the per-weekday counts instead would count a session spanning midnight twice.
    private static func weeklySessionTotal(
        events: [UsageEvent],
        weekStart: Date,
        calendar: Calendar
    ) -> Int {
        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return 0 }
        var ids = Set<String>()
        for event in events where event.timestamp >= weekStart && event.timestamp < weekEnd {
            ids.insert(event.sessionId)
        }
        return ids.count
    }
}
