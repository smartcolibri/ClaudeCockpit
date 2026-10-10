import XCTest
@testable import UsageKit

/// The Usage screen's period series, on a Paris clock straddling the 2026-10-25 DST switch so
/// that every day, hour and comparison window is checked against local wall-clock times.
final class UsagePeriodTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()
    private let home = URL(fileURLWithPath: "/Users/test")
    private let projA = "/Users/test/DevApps/ProjA"
    private let projB = "/Users/test/DevApps/ProjB"

    /// Wednesday 2026-10-28, 15:00 in Paris (UTC+1, three days after the switch back).
    private var now: Date { local("2026-10-28 15:00") }

    private func local(_ text: String, in calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? self.calendar
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = text.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.date(from: text)!
    }

    /// $3 under the default rates (1 M Sonnet input tokens).
    private func sonnet(_ time: String, cwd: String? = nil, session: String = "s") -> UsageEvent {
        EventFactory.make(sessionId: session, model: "claude-sonnet-5", timestamp: local(time),
                          cwd: cwd ?? projA, inputTokens: 1_000_000)
    }

    /// $5 under the default rates (1 M Opus input tokens).
    private func opus(_ time: String, cwd: String? = nil, session: String = "s") -> UsageEvent {
        EventFactory.make(sessionId: session, model: "claude-opus-5", timestamp: local(time),
                          cwd: cwd ?? projA, inputTokens: 1_000_000)
    }

    private func snapshot(
        _ events: [UsageEvent],
        range: DateRangeFilter,
        models: Set<ModelFamily>? = nil,
        project: String? = nil,
        at date: Date? = nil
    ) -> UsageSnapshot {
        UsageAggregator.snapshot(
            events: events,
            filters: UsageFilters(models: models, project: project, range: range),
            pricing: .default, now: date ?? now, calendar: calendar, home: home)
    }

    // MARK: Previous period

    private func assertPrevious(
        _ range: DateRangeFilter, at date: Date? = nil, _ start: String, _ end: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let bounds = range.previousBounds(now: date ?? now, calendar: calendar)
        XCTAssertEqual(bounds?.start, local(start), "\(range) start", file: file, line: line)
        XCTAssertEqual(bounds?.end, local(end), "\(range) end", file: file, line: line)
    }

    func testPreviousPeriodOfEachRange() {
        assertPrevious(.today, "2026-10-27 00:00", "2026-10-27 15:00")
        assertPrevious(.thisWeek, "2026-10-19 00:00", "2026-10-21 15:00")
        assertPrevious(.thisMonth, "2026-09-01 00:00", "2026-09-28 15:00")
        assertPrevious(.prevMonth, "2026-08-01 00:00", "2026-09-01 00:00")
        // Same length, same wall-clock end: the previous window crosses the DST switch.
        assertPrevious(.last7Days, "2026-10-15 00:00", "2026-10-21 15:00")
        assertPrevious(.last30Days, "2026-08-30 00:00", "2026-09-28 15:00")
        assertPrevious(.last90Days, "2026-05-02 00:00", "2026-07-30 15:00")
        XCTAssertNil(DateRangeFilter.all.previousBounds(now: now, calendar: calendar))
    }

    func testPreviousMonthToDateIsClampedToTheShorterMonth() {
        assertPrevious(.thisMonth, at: local("2026-03-31 10:00"), "2026-02-01 00:00", "2026-02-28 10:00")
        assertPrevious(.thisMonth, at: local("2028-03-31 10:00"), "2028-02-01 00:00", "2028-02-29 10:00")
    }

    func testPreviousCostKeepsModelAndProjectFiltersButNotTheRange() {
        let events = [
            sonnet("2026-10-27 10:00"),               // yesterday, before 15:00: counted
            opus("2026-10-27 11:00"),                 // filtered out by model
            sonnet("2026-10-27 12:00", cwd: projB),   // filtered out by project
            sonnet("2026-10-27 16:00"),               // after the same clock time
            sonnet("2026-10-28 09:00"),               // today
        ]
        let snap = snapshot(events, range: .today, models: [.sonnet], project: projA)
        XCTAssertEqual(snap.totals.estimatedCostUSD, 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snap.period.previousCostUSD), 3, accuracy: 1e-9)
        XCTAssertNil(snapshot(events, range: .all).period.previousCostUSD)
    }

    // MARK: Days

    func testDaysEndTodayAndStayAtLocalMidnights() {
        let days = snapshot([], range: .last30Days).period.days
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days.first, local("2026-09-29"))
        XCTAssertEqual(days.last, local("2026-10-28"))
        XCTAssertTrue(days.allSatisfy { calendar.startOfDay(for: $0) == $0 })
        XCTAssertTrue(days.contains(local("2026-10-25")))
    }

    func testOpenRangesNeverReachFutureDays() {
        XCTAssertEqual(snapshot([], range: .thisMonth).period.days.count, 28)
        XCTAssertEqual(snapshot([], range: .thisWeek).period.days.count, 3)
        XCTAssertEqual(snapshot([], range: .today).period.days, [local("2026-10-28")])
        let previous = snapshot([], range: .prevMonth).period.days
        XCTAssertEqual(previous.count, 30)
        XCTAssertEqual(previous.last, local("2026-09-30"))
    }

    func testAllStartsAtTheFirstFilteredEvent() {
        let events = [opus("2026-10-01 10:00"), sonnet("2026-10-20 10:00")]
        XCTAssertEqual(snapshot(events, range: .all).period.days.first, local("2026-10-01"))
        XCTAssertEqual(snapshot(events, range: .all, models: [.sonnet]).period.days.first, local("2026-10-20"))
        XCTAssertEqual(snapshot([], range: .all).period.days, [])
        XCTAssertEqual(snapshot([], range: .all).period.buckets, [])
    }

    // MARK: Buckets

    func testGranularityThresholds() {
        XCTAssertEqual(UsagePeriod.granularity(forDayCount: 1), .hour)
        XCTAssertEqual(UsagePeriod.granularity(forDayCount: 2), .day)
        XCTAssertEqual(UsagePeriod.granularity(forDayCount: UsagePeriod.maxDailyBuckets), .day)
        XCTAssertEqual(UsagePeriod.granularity(forDayCount: UsagePeriod.maxDailyBuckets + 1), .week)
        XCTAssertEqual(UsagePeriod.granularity(forDayCount: UsagePeriod.maxWeeklyBuckets * 7), .week)
        XCTAssertEqual(UsagePeriod.granularity(forDayCount: UsagePeriod.maxWeeklyBuckets * 7 + 1), .month)
    }

    func testThirtyDaysAreDailyBucketsSplitByFamily() {
        let events = [sonnet("2026-10-25 01:30"), opus("2026-10-25 23:30"), sonnet("2026-10-28 09:00", session: "t")]
        let period = snapshot(events, range: .last30Days).period
        XCTAssertEqual(period.granularity, .day)
        XCTAssertEqual(period.buckets.count, 30)
        let switchDay = try! XCTUnwrap(period.buckets.first { $0.start == local("2026-10-25") })
        XCTAssertEqual(switchDay.end, local("2026-10-26"))
        XCTAssertEqual(switchDay.costUSD, 8, accuracy: 1e-9)
        XCTAssertEqual(switchDay.costByFamily[.opus] ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(switchDay.costByFamily[.sonnet] ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(switchDay.inputTokens, 2_000_000)
        XCTAssertEqual(switchDay.sessionCount, 1)
        XCTAssertEqual(period.buckets.last?.end, local("2026-10-29"))
        XCTAssertEqual(period.buckets.map(\.index), Array(0..<30))
    }

    func testNinetyDaysAreIsoWeeksClippedToTheRange() {
        let events = [sonnet("2026-07-31 10:00"), sonnet("2026-08-03 10:00"), sonnet("2026-10-28 10:00")]
        let period = snapshot(events, range: .last90Days).period
        XCTAssertEqual(period.granularity, .week)
        XCTAssertEqual(period.buckets.first?.start, local("2026-07-31"))
        XCTAssertEqual(period.buckets.first?.end, local("2026-08-03"))
        XCTAssertEqual(period.buckets.dropFirst().first?.start, local("2026-08-03"))
        XCTAssertEqual(period.buckets.last?.start, local("2026-10-26"))
        XCTAssertEqual(period.buckets.last?.end, local("2026-10-29"))
        XCTAssertEqual(period.buckets.count, 14)
        for (a, b) in zip(period.buckets, period.buckets.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        XCTAssertEqual(period.buckets.reduce(0) { $0 + $1.costUSD }, 9, accuracy: 1e-9)
        XCTAssertEqual(period.buckets[0].costUSD, 3, accuracy: 1e-9)
    }

    func testLongHistoryIsMonthly() {
        let events = [sonnet("2025-06-15 10:00"), sonnet("2026-10-28 10:00")]
        let period = snapshot(events, range: .all).period
        XCTAssertEqual(period.granularity, .month)
        XCTAssertEqual(period.buckets.first?.start, local("2025-06-15"))
        XCTAssertEqual(period.buckets.dropFirst().first?.start, local("2025-07-01"))
        XCTAssertEqual(period.buckets.last?.start, local("2026-10-01"))
        XCTAssertEqual(period.buckets.last?.end, local("2026-10-29"))
        XCTAssertEqual(period.buckets.count, 17)
        XCTAssertEqual(period.buckets.reduce(0) { $0 + $1.costUSD }, 6, accuracy: 1e-9)
    }

    func testTodayIsHourlyUpToTheCurrentHour() {
        let events = [sonnet("2026-10-28 00:10"), sonnet("2026-10-28 15:00")]
        let period = snapshot(events, range: .today).period
        XCTAssertEqual(period.granularity, .hour)
        XCTAssertEqual(period.buckets.count, 16)
        XCTAssertEqual(period.buckets.first?.start, local("2026-10-28 00:00"))
        XCTAssertEqual(period.buckets.last?.start, local("2026-10-28 15:00"))
        XCTAssertEqual(period.buckets.last?.costUSD ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(period.buckets[0].costUSD, 3, accuracy: 1e-9)
    }

    func testTokensPerBucketByKind() {
        let event = EventFactory.make(timestamp: local("2026-10-27 10:00"), inputTokens: 1, outputTokens: 2,
                                      cacheCreationTokens: 3, cacheReadTokens: 4)
        let bucket = try! XCTUnwrap(snapshot([event], range: .last7Days).period.buckets.first { $0.start == local("2026-10-27") })
        XCTAssertEqual([bucket.inputTokens, bucket.outputTokens, bucket.cacheReadTokens, bucket.cacheCreationTokens], [1, 2, 4, 3])
        XCTAssertEqual(bucket.totalTokens, 10)
    }

    // MARK: Rhythm

    func testHourOfDayIsMeanOverElapsedDaysIncludingTheRepeatedHour() {
        // 2026-10-25 02:30 happens twice in Paris: once in summer time, once in winter time.
        let summer = EventFactory.make(model: "claude-sonnet-5", timestamp: local("2026-10-25 00:30").addingTimeInterval(2 * 3600),
                                       inputTokens: 1_000_000)
        let winter = EventFactory.make(model: "claude-sonnet-5", timestamp: local("2026-10-25 00:30").addingTimeInterval(3 * 3600),
                                       inputTokens: 1_000_000)
        XCTAssertEqual(calendar.component(.hour, from: summer.timestamp), 2)
        XCTAssertEqual(calendar.component(.hour, from: winter.timestamp), 2)
        let period = snapshot([summer, winter, sonnet("2026-10-27 10:00")], range: .last7Days).period
        XCTAssertEqual(period.hourly[2].estimatedCostUSD, 6, accuracy: 1e-9)
        XCTAssertEqual(period.meanCostPerHour[2], 6.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(period.meanCostPerHour[10], 3.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(period.peakHour, 2)
        XCTAssertEqual(period.peakHourShare, 6.0 / 9, accuracy: 1e-9)
    }

    func testNoPeakWithoutSpend() {
        let period = snapshot([], range: .last7Days).period
        XCTAssertNil(period.peakHour)
        XCTAssertNil(period.weekdayShare)
    }

    func testWeekdaysCountEachSessionOnceFromMonday() {
        let events = [
            sonnet("2026-10-25 23:00", session: "a"),   // Sunday, runs past midnight
            sonnet("2026-10-26 01:00", session: "a"),
            sonnet("2026-10-26 10:00", session: "b"),   // Monday
            sonnet("2026-10-27 10:00", session: "c"),   // Tuesday
        ]
        let period = snapshot(events, range: .last7Days).period
        XCTAssertEqual(period.sessionsByWeekday, [1, 1, 0, 0, 0, 0, 1])
        XCTAssertEqual(period.sessionsByWeekday.reduce(0, +), snapshot(events, range: .last7Days).totals.sessionCount)
        XCTAssertEqual(period.weekdayDays, [1, 1, 1, 1, 1, 1, 1])
        XCTAssertEqual(try XCTUnwrap(period.weekdayShare), 2.0 / 3, accuracy: 1e-9)
    }

    func testThisWeekKnowsWhichWeekdaysAreStillToCome() {
        XCTAssertEqual(snapshot([], range: .thisWeek).period.weekdayDays, [1, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(snapshot([], range: .last30Days).period.weekdayDays, [4, 5, 5, 4, 4, 4, 4])
    }

    // MARK: Midnight DST

    /// Where summer time starts at midnight the day begins at 01:00: every day and bucket must
    /// still be the calendar's own start of day, and every event must find its bucket.
    func testDaysStayAtStartOfDayWhereDSTStartsAtMidnight() {
        var santiago = Calendar(identifier: .gregorian)
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!
        let at = { (text: String) in self.local(text, in: santiago) }
        let events = [
            EventFactory.make(model: "claude-sonnet-5", timestamp: at("2025-09-07 12:00"), inputTokens: 1_000_000),
            EventFactory.make(model: "claude-sonnet-5", timestamp: at("2025-09-20 10:00"), inputTokens: 1_000_000),
        ]
        for range in [DateRangeFilter.last30Days, .thisMonth, .all, .last90Days] {
            let snap = UsageAggregator.snapshot(
                events: events, filters: UsageFilters(range: range), pricing: .default,
                now: at("2025-09-20 15:00"), calendar: santiago, home: home)
            let period = snap.period
            XCTAssertTrue(period.days.allSatisfy { santiago.startOfDay(for: $0) == $0 }, "\(range)")
            XCTAssertEqual(period.buckets.reduce(0) { $0 + $1.costUSD }, 6, accuracy: 1e-9, "\(range)")
            XCTAssertEqual(Set(period.days).count, period.days.count, "\(range)")
            if period.granularity == .day {
                XCTAssertTrue(period.buckets.allSatisfy { santiago.startOfDay(for: $0.start) == $0.start }, "\(range)")
            }
        }
    }

    // MARK: Breakdown

    func testBreakdownByModelIdWithSessions() {
        let events = [
            opus("2026-10-27 10:00", session: "a"),
            opus("2026-10-27 11:00", session: "a"),
            opus("2026-10-27 12:00", cwd: projB, session: "b"),
            sonnet("2026-10-27 13:00", session: "c"),
        ]
        let snap = snapshot(events, range: .last7Days)
        let byModel = snap.breakdown(for: .model)
        XCTAssertEqual(byModel.map(\.label), ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(byModel[0].sessionCount, 2)
        XCTAssertEqual(byModel[0].turnCount, 3)
        XCTAssertEqual(byModel[0].estimatedCostUSD, 15, accuracy: 1e-9)
        let byProject = snap.breakdown(for: .project)
        XCTAssertEqual(byProject.map(\.sessionCount), [2, 1])
    }
}
