import Foundation

/// The Usage screen's series over the filtered period: every figure follows the model,
/// project and range filters, and nothing is plotted past now.
public struct UsagePeriod: Hashable, Sendable {
    /// How long each bar of the period chart lasts.
    public enum Granularity: String, Hashable, Sendable {
        case hour, day, week, month
    }

    /// One bar of the period chart: an hour, a day, an ISO week or a month, clipped to the
    /// period. `end` is exclusive and is the next bucket's `start`.
    public struct Bucket: Identifiable, Hashable, Sendable {
        public var id: Int { index }
        public let index: Int
        public let start: Date
        public let end: Date
        public var costByFamily: [ModelFamily: Double] = [:]
        public var inputTokens = 0
        public var outputTokens = 0
        public var cacheReadTokens = 0
        public var cacheCreationTokens = 0
        public var sessionCount = 0

        public init(index: Int, start: Date, end: Date) {
            self.index = index
            self.start = start
            self.end = end
        }

        public var costUSD: Double { costByFamily.values.reduce(0, +) }
        public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    }

    /// Up to this many days the chart has one bar per day.
    public static let maxDailyBuckets = 62
    /// Up to this many weeks it has one bar per ISO week, then one per month.
    public static let maxWeeklyBuckets = 30

    /// The start of each day of the period, oldest first, ending today at the latest. For
    /// `.all`, from the first filtered event; empty without one.
    public let days: [Date]
    /// How many of `days` the scanned history covers. Claude Code deletes old transcripts, so
    /// the history can start inside the period: the days before it are unknown, not idle, and
    /// every per-day mean divides by this rather than by `days.count`.
    public let coveredDays: Int
    public let granularity: Granularity
    public let buckets: [Bucket]
    /// Totals per hour of day (0...23) summed over the period.
    public let hourly: [HourlyUsage]
    /// Sessions per weekday, Monday first. Each session counts once, on the day of its first
    /// turn in the period, so the counts add up to the Sessions figure.
    public let sessionsByWeekday: [Int]
    /// How many of each weekday the covered days contain, Monday first: 0 for a weekday "this
    /// week" has not reached yet.
    public let weekdayDays: [Int]
    /// Cost of the previous period of equal length (see `DateRangeFilter.previousBounds`),
    /// same model and project filters. `nil` for `.all`, and when the scanned history starts
    /// more than a day after that window does: a comparison with unknown days means nothing.
    public let previousCostUSD: Double?

    public init(
        days: [Date],
        coveredDays: Int,
        granularity: Granularity,
        buckets: [Bucket],
        hourly: [HourlyUsage],
        sessionsByWeekday: [Int],
        weekdayDays: [Int],
        previousCostUSD: Double?
    ) {
        self.days = days
        self.coveredDays = coveredDays
        self.granularity = granularity
        self.buckets = buckets
        self.hourly = hourly
        self.sessionsByWeekday = sessionsByWeekday
        self.weekdayDays = weekdayDays
        self.previousCostUSD = previousCostUSD
    }

    public static let empty = UsagePeriod(
        days: [], coveredDays: 0, granularity: .day, buckets: [],
        hourly: (0..<24).map { HourlyUsage(hour: $0) },
        sessionsByWeekday: Array(repeating: 0, count: 7),
        weekdayDays: Array(repeating: 0, count: 7),
        previousCostUSD: nil)

    /// Hour bars for Today, day bars up to two months, then weeks, then months. Another range
    /// on its first day ("this week" on a Monday) stays one daily bar.
    public static func granularity(range: DateRangeFilter, dayCount count: Int) -> Granularity {
        if range == .today { return .hour }
        if count <= maxDailyBuckets { return .day }
        if count <= maxWeeklyBuckets * 7 { return .week }
        return .month
    }

    /// Mean cost per hour of day over the covered days, idle days counted as zero.
    public var meanCostPerHour: [Double] {
        let count = Double(max(1, coveredDays))
        return hourly.map { $0.estimatedCostUSD / count }
    }

    /// The hour of day with the most cost, `nil` without any.
    public var peakHour: Int? {
        guard let peak = hourly.max(by: { $0.estimatedCostUSD < $1.estimatedCostUSD }),
              peak.estimatedCostUSD > 0 else { return nil }
        return peak.hour
    }

    /// The peak hour's share of the period's cost, 0 without any.
    public var peakHourShare: Double {
        let total = hourly.reduce(0) { $0 + $1.estimatedCostUSD }
        guard let peakHour, total > 0 else { return 0 }
        return hourly[peakHour].estimatedCostUSD / total
    }

    /// Share of the sessions started Monday to Friday, `nil` without sessions.
    public var weekdayShare: Double? {
        let total = sessionsByWeekday.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(sessionsByWeekday.prefix(5).reduce(0, +)) / Double(total)
    }
}

extension UsageAggregator {
    /// The period series for `ranged` (filtered, range applied, oldest first). `unranged`
    /// carries the same model and project filters without the range, for the previous period.
    /// `horizon` is the first scanned event whatever the filters: where the history starts.
    static func period(
        ranged: [UsageEvent],
        unranged: [UsageEvent],
        horizon: Date?,
        range: DateRangeFilter,
        pricing: PricingSettings,
        now: Date,
        calendar: Calendar
    ) -> UsagePeriod {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now)
        let (rangeStart, rangeEnd) = range.bounds(now: now, calendar: calendar)
        guard let first = rangeStart ?? ranged.first?.timestamp else { return .empty }
        let periodEnd = min(rangeEnd ?? tomorrowStart, tomorrowStart)

        // Days, each normalised to the calendar's start of day: where summer time starts at
        // midnight, adding a day to the day before lands at 01:00.
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: first)
        while cursor < periodEnd, days.count < 20_000 {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = calendar.startOfDay(for: next)
        }

        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        // Monday = 0 … Sunday = 6, whatever the calendar's first weekday.
        func weekdayIndex(_ date: Date) -> Int { (calendar.component(.weekday, from: date) + 5) % 7 }

        let horizonDay = horizon.map(calendar.startOfDay(for:))
        let covered = horizonDay.map { start in days.filter { $0 >= start } } ?? []
        var weekdayDays = Array(repeating: 0, count: 7)
        for day in covered { weekdayDays[weekdayIndex(day)] += 1 }

        // Buckets, and where each day (or hour) falls.
        let granularity = UsagePeriod.granularity(range: range, dayCount: days.count)
        var starts: [Date] = []
        var bucketOfDay: [Date: Int] = [:]
        switch granularity {
        case .hour:
            let hourNow = calendar.dateInterval(of: .hour, for: min(now, periodEnd.addingTimeInterval(-1)))?.start ?? now
            var hour = days.first ?? todayStart
            while hour <= hourNow, starts.count < 26 {
                starts.append(hour)
                guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
                hour = next
            }
        case .day:
            starts = days
        case .week, .month:
            let component: Calendar.Component = granularity == .week ? .weekOfYear : .month
            for day in days {
                let unit = (granularity == .week ? iso : calendar).dateInterval(of: component, for: day)?.start ?? day
                let start = max(calendar.startOfDay(for: unit), days[0])
                if starts.last != start { starts.append(start) }
            }
        }
        if granularity != .hour {
            var index = 0
            for day in days {
                while index + 1 < starts.count, starts[index + 1] <= day { index += 1 }
                bucketOfDay[day] = index
            }
        }
        var buckets = starts.enumerated().map { index, start in
            UsagePeriod.Bucket(index: index, start: start, end: index + 1 < starts.count ? starts[index + 1] : periodEnd)
        }

        var bucketSessions = Array(repeating: Set<String>(), count: buckets.count)
        var hourly = (0..<24).map { HourlyUsage(hour: $0) }
        var sessionsByWeekday = Array(repeating: 0, count: 7)
        var seenSessions = Set<String>()

        for event in ranged {
            let family = ModelFamily.detect(from: event.model)
            let cost = pricing.pricing(for: family).cost(for: event)
            let index: Int?
            if granularity == .hour, let first = starts.first {
                // Hour buckets are whole-hour steps from midnight, so the offset is the index
                // (a 25-hour day has 25 of them).
                let offset = Int(event.timestamp.timeIntervalSince(first) / 3600)
                index = starts.indices.contains(offset) ? offset : nil
            } else {
                index = bucketOfDay[calendar.startOfDay(for: event.timestamp)]
            }
            if let index {
                buckets[index].costByFamily[family, default: 0] += cost
                buckets[index].inputTokens += event.inputTokens
                buckets[index].outputTokens += event.outputTokens
                buckets[index].cacheReadTokens += event.cacheReadTokens
                buckets[index].cacheCreationTokens += event.cacheCreationTokens
                bucketSessions[index].insert(event.sessionId)
            }
            let hour = calendar.component(.hour, from: event.timestamp)
            hourly[hour].inputTokens += event.inputTokens
            hourly[hour].outputTokens += event.outputTokens
            hourly[hour].cacheReadTokens += event.cacheReadTokens
            hourly[hour].cacheCreationTokens += event.cacheCreationTokens
            hourly[hour].estimatedCostUSD += cost
            if seenSessions.insert(event.sessionId).inserted {
                sessionsByWeekday[weekdayIndex(event.timestamp)] += 1
            }
        }
        for index in buckets.indices { buckets[index].sessionCount = bucketSessions[index].count }

        // A day of tolerance: history that starts on the window's first day still covers it.
        let previousCost = range.previousBounds(now: now, calendar: calendar).flatMap { window -> Double? in
            guard let horizon,
                  let latestStart = calendar.date(byAdding: .day, value: 1, to: window.start),
                  horizon < latestStart
            else { return nil }
            return PricingCalculator.estimatedCostUSD(
                for: unranged.filter { $0.timestamp >= window.start && $0.timestamp < window.end },
                pricing: pricing)
        }

        return UsagePeriod(
            days: days,
            coveredDays: covered.count,
            granularity: granularity,
            buckets: buckets,
            hourly: hourly,
            sessionsByWeekday: sessionsByWeekday,
            weekdayDays: weekdayDays,
            previousCostUSD: previousCost)
    }
}
