import Foundation
import CockpitShared

/// Turns a flat event list into everything the usage screens display. A pure function of its
/// inputs — the computation the source app's `UsageViewModel` did in `recomputeFiltered` and
/// `recomputeFixedWindows`, with no observable state of its own.
public enum UsageAggregator {
    public static func snapshot(
        events allEvents: [UsageEvent],
        sessionInfo: [String: SessionInfo] = [:],
        filters: UsageFilters = UsageFilters(),
        pricing: PricingSettings = .default,
        now: Date = Date(),
        calendar: Calendar = .current,
        home: URL = ClaudePaths.realHome,
        overview precomputed: UsageOverview? = nil
    ) -> UsageSnapshot {
        // Model/project filtering only: the fixed day/week comparisons deliberately ignore
        // the range filter.
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

        // MARK: Daily series

        var byDay: [Date: DailyUsage] = [:]
        for event in filtered {
            let day = calendar.startOfDay(for: event.timestamp)
            var daily = byDay[day] ?? DailyUsage(day: day)
            daily.inputTokens += event.inputTokens
            daily.outputTokens += event.outputTokens
            daily.cacheReadTokens += event.cacheReadTokens
            daily.cacheCreationTokens += event.cacheCreationTokens
            daily.estimatedCostUSD += pricing.pricing(forModel: event.model).cost(for: event)
            byDay[day] = daily
        }
        let daily = byDay.values.sorted { $0.day < $1.day }

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
            // `<synthetic>` placeholders name no model, as on the Overview.
            if event.model != "<synthetic>" {
                modelBuckets[event.model, default: Bucket()].add(tokens: tokens, cost: cost, session: session)
            }
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

        // MARK: Fixed windows

        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let hourlyToday = hourly(events: unranged, dayStart: todayStart, calendar: calendar, pricing: pricing)
        let hourlyYesterday = hourly(events: unranged, dayStart: yesterdayStart, calendar: calendar, pricing: pricing)

        var isoCalendar = Calendar(identifier: .iso8601)
        isoCalendar.timeZone = calendar.timeZone
        let thisWeekStart = isoCalendar.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        let lastWeekStart = isoCalendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart

        let sessionsThisWeekByWeekday = weeklySessionCounts(events: unranged, weekStart: thisWeekStart, calendar: isoCalendar)
        let sessionsLastWeekByWeekday = weeklySessionCounts(events: unranged, weekStart: lastWeekStart, calendar: isoCalendar)
        let sessionsThisWeekTotal = weeklySessionTotal(events: unranged, weekStart: thisWeekStart, calendar: isoCalendar)
        let sessionsLastWeekTotal = weeklySessionTotal(events: unranged, weekStart: lastWeekStart, calendar: isoCalendar)
        let costThisWeek = weeklyCost(events: unranged, weekStart: thisWeekStart, calendar: isoCalendar, pricing: pricing)
        let costLastWeek = weeklyCost(events: unranged, weekStart: lastWeekStart, calendar: isoCalendar, pricing: pricing)
        // The trend insight compares this week so far with the same elapsed stretch of last
        // week: against the whole previous week, Monday would always read as "cost is down".
        // The end is `now` moved back seven calendar days, which keeps the wall-clock time
        // across a DST switch; adding the elapsed seconds (or hour components, which Foundation
        // also adds as absolute durations) would land an hour off. Clamped to the week boundary.
        let lastWeekToDateEnd = min(
            isoCalendar.date(byAdding: .day, value: -7, to: now) ?? thisWeekStart,
            thisWeekStart)
        let costLastWeekToDate = PricingCalculator.estimatedCostUSD(
            for: unranged.filter { $0.timestamp >= lastWeekStart && $0.timestamp < lastWeekToDateEnd },
            pricing: pricing)

        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart
        let todayEvents = unranged.filter { $0.timestamp >= todayStart && $0.timestamp < todayEnd }
        let costTodayUSD = PricingCalculator.estimatedCostUSD(for: todayEvents, pricing: pricing)
        let tokensToday = todayEvents.reduce(0) { $0 + $1.totalTokens }
        let allTodayEvents = allEvents.filter { $0.timestamp >= todayStart && $0.timestamp < todayEnd }
        let costTodayUnfilteredUSD = PricingCalculator.estimatedCostUSD(for: allTodayEvents, pricing: pricing)
        let tokensTodayUnfiltered = allTodayEvents.reduce(0) { $0 + $1.totalTokens }
        let costThisWeekUnfiltered = weeklyCost(events: allEvents, weekStart: thisWeekStart, calendar: isoCalendar, pricing: pricing)
        let sessionsThisWeekUnfiltered = weeklySessionTotal(events: allEvents, weekStart: thisWeekStart, calendar: isoCalendar)
        let sessionsLastWeekUnfiltered = weeklySessionTotal(events: allEvents, weekStart: lastWeekStart, calendar: isoCalendar)

        let insights = InsightEngine.derive(
            events: filtered,
            thisWeekCostUSD: costThisWeek,
            lastWeekCostUSD: costLastWeekToDate,
            elapsedThisWeek: now.timeIntervalSince(thisWeekStart),
            pricingSettings: pricing)

        // MARK: Picker options (whole event set, before any filter)

        let availableProjects = Array(Set(allEvents.map(\.cwd))).sorted()
        let availableModels = Array(Set(allEvents.map(\.model))).sorted()
        let presentFamilies = Set(allEvents.map { ModelFamily.detect(from: $0.model) })
        let availableModelFamilies = ModelFamily.allCases.filter(presentFamilies.contains)

        return UsageSnapshot(
            generatedAt: now,
            filters: filters,
            pricing: pricing,
            filteredEventCount: filtered.count,
            totals: totals,
            daily: daily,
            costByFamily: costByFamily,
            sessions: sessions,
            breakdowns: breakdowns,
            hourlyToday: hourlyToday,
            hourlyYesterday: hourlyYesterday,
            sessionsThisWeekByWeekday: sessionsThisWeekByWeekday,
            sessionsLastWeekByWeekday: sessionsLastWeekByWeekday,
            sessionsThisWeekTotal: sessionsThisWeekTotal,
            sessionsLastWeekTotal: sessionsLastWeekTotal,
            costThisWeekUSD: costThisWeek,
            costLastWeekUSD: costLastWeek,
            monthly: monthlyUsage(events: unranged, calendar: calendar, pricing: pricing),
            yearly: yearlyUsage(events: unranged, calendar: calendar, pricing: pricing),
            insights: insights,
            costTodayUSD: costTodayUSD,
            tokensToday: tokensToday,
            costTodayUnfilteredUSD: costTodayUnfilteredUSD,
            tokensTodayUnfiltered: tokensTodayUnfiltered,
            costThisWeekUnfilteredUSD: costThisWeekUnfiltered,
            sessionsThisWeekUnfilteredTotal: sessionsThisWeekUnfiltered,
            sessionsLastWeekUnfilteredTotal: sessionsLastWeekUnfiltered,
            overview: precomputed ?? overview(events: allEvents, pricing: pricing, now: now, calendar: calendar, home: home),
            period: period(ranged: filtered, unranged: unranged, range: filters.range, pricing: pricing, now: now, calendar: calendar),
            availableProjects: availableProjects,
            availableModels: availableModels,
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

    private static func hourly(
        events: [UsageEvent],
        dayStart: Date,
        calendar: Calendar,
        pricing: PricingSettings
    ) -> [HourlyUsage] {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        var buckets = (0..<24).map { HourlyUsage(hour: $0) }
        for event in events where event.timestamp >= dayStart && event.timestamp < dayEnd {
            let hour = calendar.component(.hour, from: event.timestamp)
            buckets[hour].inputTokens += event.inputTokens
            buckets[hour].outputTokens += event.outputTokens
            buckets[hour].cacheReadTokens += event.cacheReadTokens
            buckets[hour].cacheCreationTokens += event.cacheCreationTokens
            buckets[hour].estimatedCostUSD += pricing.pricing(forModel: event.model).cost(for: event)
        }
        return buckets
    }

    private static func weeklySessionCounts(
        events: [UsageEvent],
        weekStart: Date,
        calendar: Calendar
    ) -> [Int] {
        (0..<7).map { offset in
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: weekStart),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { return 0 }
            var ids = Set<String>()
            for event in events where event.timestamp >= dayStart && event.timestamp < dayEnd {
                ids.insert(event.sessionId)
            }
            return ids.count
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

    private static func weeklyCost(
        events: [UsageEvent],
        weekStart: Date,
        calendar: Calendar,
        pricing: PricingSettings
    ) -> Double {
        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return 0 }
        let weekEvents = events.filter { $0.timestamp >= weekStart && $0.timestamp < weekEnd }
        return PricingCalculator.estimatedCostUSD(for: weekEvents, pricing: pricing)
    }

    private static func yearlyUsage(
        events: [UsageEvent],
        calendar: Calendar,
        pricing: PricingSettings
    ) -> [YearlyUsage] {
        var byYear: [Int: (ids: Set<String>, cost: Double)] = [:]
        for event in events {
            let year = calendar.component(.year, from: event.timestamp)
            var bucket = byYear[year] ?? (Set<String>(), 0)
            bucket.ids.insert(event.sessionId)
            bucket.cost += pricing.pricing(forModel: event.model).cost(for: event)
            byYear[year] = bucket
        }
        return byYear.keys.sorted().compactMap { year in
            guard let bucket = byYear[year] else { return nil }
            return YearlyUsage(year: year, sessionCount: bucket.ids.count, estimatedCostUSD: bucket.cost)
        }
    }

    private static func monthlyUsage(
        events: [UsageEvent],
        calendar: Calendar,
        pricing: PricingSettings
    ) -> [MonthlyUsage] {
        var byMonth: [Date: Double] = [:]
        for event in events {
            let components = calendar.dateComponents([.year, .month], from: event.timestamp)
            guard let monthStart = calendar.date(from: components) else { continue }
            byMonth[monthStart, default: 0] += pricing.pricing(forModel: event.model).cost(for: event)
        }
        return byMonth.keys.sorted().compactMap { month in
            guard let cost = byMonth[month] else { return nil }
            return MonthlyUsage(monthStart: month, estimatedCostUSD: cost)
        }
    }
}
