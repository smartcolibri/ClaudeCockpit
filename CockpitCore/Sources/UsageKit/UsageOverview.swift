import Foundation
import CockpitShared

/// What the Overview screen reads from the usage: every figure is computed from all events,
/// so the Usage screen's project, model and range pickers never move it.
///
/// "Last 30 days" always means the 30 calendar days ending with today, today included; the
/// 30-day mean is the exception and is spelled out on `meanDailyCostUSD`.
public struct UsageOverview: Hashable, Sendable {
    /// One model family's cost on one day.
    public struct FamilyDayCost: Identifiable, Hashable, Sendable {
        public var id: String { "\(day.timeIntervalSince1970)-\(family.rawValue)" }
        public let day: Date
        public let family: ModelFamily
        public let costUSD: Double

        public init(day: Date, family: ModelFamily, costUSD: Double) {
            self.day = day
            self.family = family
            self.costUSD = costUSD
        }
    }

    /// One day's cost, all models together.
    public struct DayCost: Identifiable, Hashable, Sendable {
        public var id: Date { day }
        public let day: Date
        public let costUSD: Double

        public init(day: Date, costUSD: Double) {
            self.day = day
            self.costUSD = costUSD
        }
    }

    /// How many weeks the activity window spans, the current one included.
    public static let activityWeeks = 12
    /// How many projects the top-projects list keeps.
    public static let topProjectCount = 5

    /// The start of each of the last 30 days, oldest first, ending with today.
    public let last30Days: [Date]
    /// Cost per day and family over `last30Days`. Days or families without spend are left out.
    public let costByDayAndFamily: [FamilyDayCost]
    /// Monday of the week `activityWeeks - 1` weeks before this one: where the activity
    /// window starts.
    public let activityStart: Date
    /// One entry per day from `activityStart` to today, oldest first, idle days at zero.
    public let dailyCost: [DayCost]

    public let hourlyToday: [HourlyUsage]
    public let hourlyYesterday: [HourlyUsage]

    /// The `topProjectCount` costliest projects over the last 30 days, costliest first.
    public let topProjects: [BreakdownRow]
    /// Cost per family over the last 30 days, in `ModelFamily` order, zero families left out.
    public let modelMix: [ModelCostRow]
    public let cost30DaysUSD: Double
    /// The project that spent the most on Opus over the last 30 days, `~`-shortened.
    public let topOpusProject: String?
    /// Cache read tokens over cacheable tokens (cache read + input) for the last 30 days —
    /// the same ratio `InsightEngine` reports, so the two screens never disagree. `nil`
    /// when nothing cacheable was sent.
    public let cacheHitRate: Double?
    /// The ratio's denominator: a rate over a handful of tokens means little.
    public let cacheableTokens30Days: Int
    /// Model ids seen over the last 30 days that have no pricing tier of their own.
    public let unpricedModels: [String]

    /// Mean daily cost of the 30 full days before today, idle days counted as zero. Today is
    /// left out: it is the figure being compared with the mean, and it is not over yet.
    public let meanDailyCostUSD: Double
    /// Today's tokens by kind and cost.
    public let today: UsageSummary

    public let monthToDateCostUSD: Double
    /// Month-to-date cost extrapolated linearly over the whole month. `nil` before a full day
    /// of the month has elapsed: a few hours of spend multiplied by thirty means nothing.
    public let monthProjectionUSD: Double?
    /// Calendar days of the current month elapsed so far, today counted by the fraction gone.
    public let monthElapsedDays: Double
    public let lastMonthCostUSD: Double

    /// This week so far, and last week up to the same weekday and wall-clock time.
    public let costThisWeekToDateUSD: Double
    public let costLastWeekToDateUSD: Double
    public let elapsedThisWeek: TimeInterval

    public init(
        last30Days: [Date],
        costByDayAndFamily: [FamilyDayCost],
        activityStart: Date,
        dailyCost: [DayCost],
        hourlyToday: [HourlyUsage],
        hourlyYesterday: [HourlyUsage],
        topProjects: [BreakdownRow],
        modelMix: [ModelCostRow],
        cost30DaysUSD: Double,
        topOpusProject: String?,
        cacheHitRate: Double?,
        cacheableTokens30Days: Int,
        unpricedModels: [String],
        meanDailyCostUSD: Double,
        today: UsageSummary,
        monthToDateCostUSD: Double,
        monthProjectionUSD: Double?,
        monthElapsedDays: Double,
        lastMonthCostUSD: Double,
        costThisWeekToDateUSD: Double,
        costLastWeekToDateUSD: Double,
        elapsedThisWeek: TimeInterval
    ) {
        self.last30Days = last30Days
        self.costByDayAndFamily = costByDayAndFamily
        self.activityStart = activityStart
        self.dailyCost = dailyCost
        self.hourlyToday = hourlyToday
        self.hourlyYesterday = hourlyYesterday
        self.topProjects = topProjects
        self.modelMix = modelMix
        self.cost30DaysUSD = cost30DaysUSD
        self.topOpusProject = topOpusProject
        self.cacheHitRate = cacheHitRate
        self.cacheableTokens30Days = cacheableTokens30Days
        self.unpricedModels = unpricedModels
        self.meanDailyCostUSD = meanDailyCostUSD
        self.today = today
        self.monthToDateCostUSD = monthToDateCostUSD
        self.monthProjectionUSD = monthProjectionUSD
        self.monthElapsedDays = monthElapsedDays
        self.lastMonthCostUSD = lastMonthCostUSD
        self.costThisWeekToDateUSD = costThisWeekToDateUSD
        self.costLastWeekToDateUSD = costLastWeekToDateUSD
        self.elapsedThisWeek = elapsedThisWeek
    }

    /// Opus's share of the last 30 days' cost, 0 when nothing was spent.
    public var opusShare: Double {
        guard cost30DaysUSD > 0 else { return 0 }
        let opus = modelMix.first { $0.family == .opus }?.costUSD ?? 0
        return opus / cost30DaysUSD
    }

    /// The last `count` days of `dailyCost`, for the cost sparkline.
    public func recentDailyCost(_ count: Int) -> [DayCost] {
        Array(dailyCost.suffix(count))
    }

    /// Monday of the week `weeks - 1` weeks before the one containing `now`, in the
    /// calendar's time zone — the first day of an activity grid `weeks` columns wide.
    public static func activityStart(now: Date, weeks: Int = activityWeeks, calendar: Calendar) -> Date {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let thisWeek = iso.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return calendar.startOfDay(for: iso.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek)
    }
}

extension UsageAggregator {
    /// Computes the Overview's figures from every event, ignoring any filter.
    public static func overview(
        events: [UsageEvent],
        pricing: PricingSettings = .default,
        now: Date = Date(),
        calendar: Calendar = .current,
        home: URL = ClaudePaths.realHome
    ) -> UsageOverview {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let yesterdayStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart)
        let last30Start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart)
        let meanStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -30, to: todayStart) ?? todayStart)
        let activityStart = UsageOverview.activityStart(now: now, calendar: calendar)

        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? todayStart
        let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart

        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let thisWeekStart = iso.dateInterval(of: .weekOfYear, for: now)?.start ?? todayStart
        let lastWeekStart = iso.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart
        // Same rule as the snapshot's trend: `now` moved back seven calendar days keeps the
        // wall-clock time across a DST switch.
        let lastWeekToDateEnd = min(iso.date(byAdding: .day, value: -7, to: now) ?? thisWeekStart, thisWeekStart)

        // Every day any window needs, so each event is placed with one dictionary lookup.
        let firstDay = [activityStart, meanStart, lastMonthStart, lastWeekStart, yesterdayStart].min() ?? todayStart
        var dayStarts: [Date] = []
        var cursor = firstDay
        while cursor < tomorrowStart, dayStarts.count < 800 {
            dayStarts.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            // Normalised: where summer time starts at midnight, adding a day to the day before
            // lands at 01:00 and every later step would stay off the calendar's day starts.
            cursor = calendar.startOfDay(for: next)
        }
        var costPerDay = [Date: Double](minimumCapacity: dayStarts.count)
        var familyCostPerDay: [Date: [ModelFamily: Double]] = [:]

        var today = UsageSummary()
        var hourlyToday = (0..<24).map { HourlyUsage(hour: $0) }
        var hourlyYesterday = (0..<24).map { HourlyUsage(hour: $0) }
        var projectBuckets: [String: (turns: Int, tokens: Int, cost: Double)] = [:]
        var opusByProject: [String: Double] = [:]
        var familyCost: [ModelFamily: Double] = [:]
        var shortened: [String: String] = [:]
        var models = Set<String>()
        var cost30 = 0.0
        var cacheRead30 = 0
        var input30 = 0
        var monthToDate = 0.0
        var lastMonth = 0.0
        var thisWeek = 0.0
        var lastWeekToDate = 0.0

        for event in events where event.timestamp >= firstDay && event.timestamp < tomorrowStart {
            let family = ModelFamily.detect(from: event.model)
            let cost = pricing.pricing(for: family).cost(for: event)
            let time = event.timestamp
            let day = calendar.startOfDay(for: time)
            costPerDay[day, default: 0] += cost

            if time >= monthStart { monthToDate += cost } else if time >= lastMonthStart { lastMonth += cost }
            if time >= thisWeekStart { thisWeek += cost }
            if time >= lastWeekStart, time < lastWeekToDateEnd { lastWeekToDate += cost }

            if time >= todayStart {
                today.turnCount += 1
                today.inputTokens += event.inputTokens
                today.outputTokens += event.outputTokens
                today.cacheReadTokens += event.cacheReadTokens
                today.cacheCreationTokens += event.cacheCreationTokens
                today.estimatedCostUSD += cost
                add(event, cost: cost, to: &hourlyToday[calendar.component(.hour, from: time)])
            } else if time >= yesterdayStart {
                add(event, cost: cost, to: &hourlyYesterday[calendar.component(.hour, from: time)])
            }

            guard time >= last30Start else { continue }
            familyCostPerDay[day, default: [:]][family, default: 0] += cost
            familyCost[family, default: 0] += cost
            cost30 += cost
            cacheRead30 += event.cacheReadTokens
            input30 += event.inputTokens
            models.insert(event.model)
            let project: String
            if let cached = shortened[event.cwd] {
                project = cached
            } else {
                project = UsagePath.shorten(event.cwd, home: home)
                shortened[event.cwd] = project
            }
            var bucket = projectBuckets[project] ?? (0, 0, 0)
            bucket.turns += 1
            bucket.tokens += event.totalTokens
            bucket.cost += cost
            projectBuckets[project] = bucket
            if family == .opus { opusByProject[project, default: 0] += cost }
        }
        today.sessionCount = Set(events.lazy.filter { $0.timestamp >= todayStart && $0.timestamp < tomorrowStart }.map(\.sessionId)).count

        let last30Days = dayStarts.filter { $0 >= last30Start }
        let costByDayAndFamily = last30Days.flatMap { day in
            ModelFamily.allCases.compactMap { family -> UsageOverview.FamilyDayCost? in
                guard let cost = familyCostPerDay[day]?[family], cost > 0 else { return nil }
                return UsageOverview.FamilyDayCost(day: day, family: family, costUSD: cost)
            }
        }
        let dailyCost = dayStarts.filter { $0 >= activityStart }
            .map { UsageOverview.DayCost(day: $0, costUSD: costPerDay[$0] ?? 0) }
        let meanDays = dayStarts.filter { $0 >= meanStart && $0 < todayStart }
        let meanDaily = meanDays.reduce(0) { $0 + (costPerDay[$1] ?? 0) } / 30

        let topProjects = projectBuckets
            .map { BreakdownRow(label: $0.key, turnCount: $0.value.turns, totalTokens: $0.value.tokens, estimatedCostUSD: $0.value.cost) }
            .sorted { $0.estimatedCostUSD != $1.estimatedCostUSD ? $0.estimatedCostUSD > $1.estimatedCostUSD : $0.label < $1.label }
            .prefix(UsageOverview.topProjectCount)
        let topOpusProject = opusByProject
            .filter { $0.value > 0 }
            .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key

        // Calendar days, not 86 400-second chunks: a DST day is 23 or 25 hours long.
        let elapsedFullDays = calendar.dateComponents([.day], from: monthStart, to: todayStart).day ?? 0
        let todayLength = tomorrowStart.timeIntervalSince(todayStart)
        let monthElapsed = Double(elapsedFullDays) + (todayLength > 0 ? now.timeIntervalSince(todayStart) / todayLength : 0)
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let projection = monthElapsed >= 1 ? monthToDate / monthElapsed * Double(daysInMonth) : nil

        let cacheable = cacheRead30 + input30
        return UsageOverview(
            last30Days: last30Days,
            costByDayAndFamily: costByDayAndFamily,
            activityStart: activityStart,
            dailyCost: dailyCost,
            hourlyToday: hourlyToday,
            hourlyYesterday: hourlyYesterday,
            topProjects: Array(topProjects),
            modelMix: ModelFamily.allCases.compactMap { family in
                guard let cost = familyCost[family], cost > 0 else { return nil }
                return ModelCostRow(family: family, costUSD: cost)
            },
            cost30DaysUSD: cost30,
            topOpusProject: topOpusProject,
            cacheHitRate: cacheable > 0 ? Double(cacheRead30) / Double(cacheable) : nil,
            cacheableTokens30Days: cacheable,
            unpricedModels: models.filter { !pricing.hasDedicatedTier(forModel: $0) }.sorted(),
            meanDailyCostUSD: meanDaily,
            today: today,
            monthToDateCostUSD: monthToDate,
            monthProjectionUSD: projection,
            monthElapsedDays: monthElapsed,
            lastMonthCostUSD: lastMonth,
            costThisWeekToDateUSD: thisWeek,
            costLastWeekToDateUSD: lastWeekToDate,
            elapsedThisWeek: now.timeIntervalSince(thisWeekStart))
    }

    private static func add(_ event: UsageEvent, cost: Double, to bucket: inout HourlyUsage) {
        bucket.inputTokens += event.inputTokens
        bucket.outputTokens += event.outputTokens
        bucket.cacheReadTokens += event.cacheReadTokens
        bucket.cacheCreationTokens += event.cacheCreationTokens
        bucket.estimatedCostUSD += cost
    }
}
