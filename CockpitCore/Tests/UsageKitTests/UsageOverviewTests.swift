import XCTest
@testable import UsageKit

/// The Overview's figures, on a Paris clock straddling the 2026-10-25 DST switch so that day
/// windows are checked against local midnights, not 86 400-second steps.
final class UsageOverviewTests: XCTestCase {
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

    private func local(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    /// $3 under the default rates (1 M Sonnet input tokens).
    private func sonnet(_ time: String, cwd: String? = nil, session: String = "s") -> UsageEvent {
        EventFactory.make(sessionId: session, model: "claude-sonnet-5", timestamp: local(time),
                          cwd: cwd ?? projA, inputTokens: 1_000_000)
    }

    /// $5 under the default rates (1 M Opus input tokens).
    private func opus(_ time: String, cwd: String? = nil) -> UsageEvent {
        EventFactory.make(model: "claude-opus-5", timestamp: local(time), cwd: cwd ?? projA, inputTokens: 1_000_000)
    }

    private func overview(_ events: [UsageEvent], at date: Date? = nil) -> UsageOverview {
        UsageAggregator.overview(events: events, pricing: .default, now: date ?? now, calendar: calendar, home: home)
    }

    // MARK: Day windows

    func testLastThirtyDaysEndTodayAtLocalMidnights() {
        let result = overview([])
        XCTAssertEqual(result.last30Days.count, 30)
        XCTAssertEqual(result.last30Days.first, local("2026-09-29 00:00"))
        XCTAssertEqual(result.last30Days.last, local("2026-10-28 00:00"))
        XCTAssertTrue(result.last30Days.contains(local("2026-10-25 00:00")), "the 25-hour day is one day")
    }

    func testCostPerDayIsSplitByFamilyOverThirtyDays() {
        let result = overview([
            sonnet("2026-10-28 09:00"), opus("2026-10-28 10:00"),
            sonnet("2026-09-29 00:30"),
            sonnet("2026-09-28 23:30"),  // 30 days back: outside the window
        ])
        XCTAssertEqual(result.costByDayAndFamily.map(\.day), [
            local("2026-09-29 00:00"), local("2026-10-28 00:00"), local("2026-10-28 00:00"),
        ])
        XCTAssertEqual(result.costByDayAndFamily.map(\.family), [.sonnet, .opus, .sonnet], "ModelFamily order within a day")
        XCTAssertEqual(result.costByDayAndFamily.map(\.costUSD), [3, 5, 3])
        XCTAssertEqual(result.cost30DaysUSD, 11, accuracy: 1e-9)
    }

    func testActivityWindowStartsOnAMondayElevenWeeksBack() {
        let result = overview([sonnet("2026-08-10 12:00"), sonnet("2026-08-09 12:00")])
        XCTAssertEqual(result.activityStart, local("2026-08-10 00:00"), "Monday of the week eleven weeks before this one")
        XCTAssertEqual(result.dailyCost.count, 7 * 11 + 3, "eleven full weeks, then Monday to Wednesday")
        XCTAssertEqual(result.dailyCost.first?.costUSD ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(result.dailyCost.reduce(0) { $0 + $1.costUSD }, 3, accuracy: 1e-9, "the Sunday before is outside")
        XCTAssertEqual(result.dailyCost.last?.day, local("2026-10-28 00:00"))
        XCTAssertEqual(result.recentDailyCost(14).count, 14)
        XCTAssertEqual(result.recentDailyCost(14).first?.day, local("2026-10-15 00:00"))
    }

    // MARK: Mean, month, week

    func testMeanCoversThirtyFullDaysBeforeToday() {
        let result = overview([
            opus("2026-10-28 08:00"),  // today: not part of the mean
            sonnet("2026-10-27 23:59"), sonnet("2026-09-28 00:01"),
            sonnet("2026-09-27 23:59"),  // 31 days back
        ])
        XCTAssertEqual(result.meanDailyCostUSD, 6.0 / 30, accuracy: 1e-9)
    }

    /// A new user's mean covers the days they have used Claude Code, not 30 days of zeros.
    func testMeanCoversOnlyTheDaysWithHistory() {
        let result = overview([sonnet("2026-10-25 10:00"), sonnet("2026-10-27 10:00"), opus("2026-10-28 09:00")])
        XCTAssertEqual(result.historyDays, 3, "the 25th (25 hours long), 26th and 27th")
        XCTAssertEqual(result.meanDailyCostUSD, 6.0 / 3, accuracy: 1e-9)

        let firstDay = overview([opus("2026-10-28 09:00")])
        XCTAssertEqual(firstDay.historyDays, 0)
        XCTAssertEqual(firstDay.meanDailyCostUSD, 0)
    }

    func testMonthProjectionCountsCalendarDays() {
        // October 1st to now: 27 full days plus 15 of today's 24 hours.
        let result = overview([sonnet("2026-10-01 10:00"), sonnet("2026-10-26 10:00"), sonnet("2026-09-30 22:00")])
        XCTAssertEqual(result.monthElapsedDays, 27 + 15.0 / 24, accuracy: 1e-9)
        XCTAssertEqual(result.monthToDateCostUSD, 6, accuracy: 1e-9)
        XCTAssertEqual(result.monthProjectionUSD ?? 0, 6 / (27 + 15.0 / 24) * 31, accuracy: 1e-9)
        XCTAssertEqual(result.lastMonthCostUSD, 3, accuracy: 1e-9)
    }

    func testNoProjectionBeforeAFullDayOfTheMonth() {
        let result = overview([sonnet("2026-11-01 08:00")], at: local("2026-11-01 20:00"))
        XCTAssertEqual(result.monthToDateCostUSD, 3, accuracy: 1e-9)
        XCTAssertNil(result.monthProjectionUSD)
    }

    func testWeekComparesTheSameStretchOfLastWeek() {
        // This week: Monday 26 00:00 → Wednesday 15:00. Last week: Monday 19 → Wednesday 21 15:00.
        let result = overview([
            sonnet("2026-10-26 09:00"), opus("2026-10-28 14:00"),
            sonnet("2026-10-21 14:59"),
            opus("2026-10-21 15:01"),  // after the matching point
        ])
        XCTAssertEqual(result.costThisWeekToDateUSD, 8, accuracy: 1e-9)
        XCTAssertEqual(result.costLastWeekToDateUSD, 3, accuracy: 1e-9)
        XCTAssertEqual(result.elapsedThisWeek, now.timeIntervalSince(local("2026-10-26 00:00")), accuracy: 1e-9)
    }

    func testLastWeekToDateKeepsWallClockTimeAcrossDST() {
        // Tuesday 27 at 10:00 compares with Tuesday 20 at 10:00 local, a 25-hour week apart.
        let result = overview([sonnet("2026-10-20 09:59"), sonnet("2026-10-20 10:01")], at: local("2026-10-27 10:00"))
        XCTAssertEqual(result.costLastWeekToDateUSD, 3, accuracy: 1e-9)
    }

    // MARK: Today

    func testTodaySplitsTokensAndHours() {
        let result = overview([
            EventFactory.make(sessionId: "a", model: "claude-sonnet-5", timestamp: local("2026-10-28 10:15"),
                              inputTokens: 10, outputTokens: 20, cacheCreationTokens: 30, cacheReadTokens: 40),
            EventFactory.make(sessionId: "b", model: "claude-sonnet-5", timestamp: local("2026-10-28 14:45"), inputTokens: 1),
            sonnet("2026-10-27 10:30"),
        ])
        XCTAssertEqual(result.today.inputTokens, 11)
        XCTAssertEqual(result.today.outputTokens, 20)
        XCTAssertEqual(result.today.cacheCreationTokens, 30)
        XCTAssertEqual(result.today.cacheReadTokens, 40)
        XCTAssertEqual(result.today.sessionCount, 2)
        XCTAssertEqual(result.hourlyToday.count, 24)
        XCTAssertEqual(result.hourlyToday[10].inputTokens, 10)
        XCTAssertEqual(result.hourlyToday[14].inputTokens, 1)
        XCTAssertEqual(result.hourlyYesterday[10].estimatedCostUSD, 3, accuracy: 1e-9)
    }

    // MARK: Projects, models, cache

    func testTopProjectsKeepsTheFiveCostliest() {
        let events = (1...6).flatMap { index in
            (0..<index).map { _ in sonnet("2026-10-20 10:00", cwd: "/Users/test/DevApps/P\(index)") }
        }
        let result = overview(events)
        XCTAssertEqual(result.topProjects.map(\.label), ["~/DevApps/P6", "~/DevApps/P5", "~/DevApps/P4", "~/DevApps/P3", "~/DevApps/P2"])
        XCTAssertEqual(result.topProjects.first?.estimatedCostUSD ?? 0, 18, accuracy: 1e-9)
    }

    func testModelMixAndTheProjectSpendingMostOnOpus() {
        let result = overview([
            opus("2026-10-20 10:00", cwd: projB), opus("2026-10-21 10:00", cwd: projB),
            opus("2026-10-22 10:00", cwd: projA), sonnet("2026-10-22 11:00", cwd: projA),
            sonnet("2026-10-22 12:00", cwd: projA),
        ])
        XCTAssertEqual(result.modelMix.map(\.family), [.opus, .sonnet])
        XCTAssertEqual(result.opusShare, 15.0 / 21, accuracy: 1e-9)
        XCTAssertEqual(result.topOpusProject, "~/DevApps/ProjB", "ProjA costs more overall but less on Opus")
    }

    /// Cache writes count as cacheable too: Claude Code writes its prompt cache on almost every
    /// turn, and leaving them out made the rate look near-perfect on any account.
    func testCacheRateCountsCacheWrites() {
        let result = overview([
            EventFactory.make(model: "claude-sonnet-5", timestamp: local("2026-10-20 10:00"),
                              inputTokens: 250, cacheCreationTokens: 1_000, cacheReadTokens: 750),
        ])
        XCTAssertEqual(result.cacheHitRate ?? 0, 750.0 / 2_000, accuracy: 1e-9)
        XCTAssertEqual(result.cacheableTokens30Days, 2_000)
        XCTAssertNil(overview([]).cacheHitRate)
    }

    func testOpusShareOfThePrevious30Days() {
        let result = overview([
            opus("2026-10-20 10:00"),  // last 30 days: Opus only
            opus("2026-09-10 10:00"), sonnet("2026-09-11 10:00"),  // days 30–59 back: 5 of 8
            opus("2026-08-28 10:00"),  // 61 days back: outside both
        ])
        XCTAssertEqual(result.opusShare, 1, accuracy: 1e-9)
        XCTAssertEqual(result.opusSharePrevious30Days, 5.0 / 8, accuracy: 1e-9)
    }

    /// `<synthetic>` lines (Claude Code's own placeholders) and turns that used no token say
    /// nothing about a model: they must not raise a pricing warning nor count as turns.
    func testSyntheticAndEmptyTurnsAreNotModelUsage() {
        let result = overview([
            EventFactory.make(model: "<synthetic>", timestamp: local("2026-10-28 10:00")),
            EventFactory.make(model: "mystery-2", timestamp: local("2026-10-28 10:05")),
            EventFactory.make(model: "claude-sonnet-5", timestamp: local("2026-10-28 10:10"), inputTokens: 5),
        ])
        XCTAssertEqual(result.unpricedModels, [])
        XCTAssertEqual(result.today.turnCount, 1)
    }

    func testUnpricedModelsOverThirtyDays() {
        let result = overview([
            EventFactory.make(model: "mystery-1", timestamp: local("2026-10-20 10:00"), inputTokens: 1),
            EventFactory.make(model: "mystery-0", timestamp: local("2026-09-01 10:00"), inputTokens: 1),
            sonnet("2026-10-20 10:00"),
        ])
        XCTAssertEqual(result.unpricedModels, ["mystery-1"])
    }

    // MARK: Snapshot

    func testSnapshotOverviewIgnoresTheFilters() {
        let events = [sonnet("2026-10-28 09:00", cwd: projA), opus("2026-10-28 10:00", cwd: projB)]
        let filtered = UsageAggregator.snapshot(
            events: events,
            filters: UsageFilters(models: [.opus], project: projB, range: .today),
            now: now, calendar: calendar, home: home)
        XCTAssertEqual(filtered.overview, overview(events))
        XCTAssertEqual(filtered.overview.today.estimatedCostUSD, 8, accuracy: 1e-9)
    }

    // MARK: Midnight DST

    /// Where summer time starts at midnight the day begins at 01:00. Every day of the series
    /// must still be the calendar's own start of day, or no event finds its bucket.
    func testDaysStayAtStartOfDayWhereDSTStartsAtMidnight() {
        // The last element is how many days of history the switch day starts.
        for (zone, now, switchDay, history) in [
            ("America/Santiago", "2025-09-20 15:00", "2025-09-07", 13.0),
            ("America/Havana", "2026-03-20 15:00", "2026-03-08", 12.0),
        ] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let formatter = DateFormatter()
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            func at(_ text: String) -> Date { formatter.date(from: text)! }
            let events = [
                EventFactory.make(model: "claude-sonnet-5", timestamp: at(switchDay + " 12:00"), inputTokens: 1_000_000),
                EventFactory.make(model: "claude-sonnet-5", timestamp: at("\(String(now.prefix(10))) 10:00"), inputTokens: 1_000_000),
            ]
            let result = UsageAggregator.overview(events: events, now: at(now), calendar: calendar, home: home)
            XCTAssertTrue(result.dailyCost.allSatisfy { calendar.startOfDay(for: $0.day) == $0.day }, zone)
            XCTAssertTrue(result.last30Days.allSatisfy { calendar.startOfDay(for: $0) == $0 }, zone)
            XCTAssertEqual(result.dailyCost.reduce(0) { $0 + $1.costUSD }, 6, accuracy: 1e-9, zone)
            XCTAssertEqual(result.costByDayAndFamily.reduce(0) { $0 + $1.costUSD }, 6, accuracy: 1e-9, zone)
            XCTAssertEqual(result.meanDailyCostUSD, 3.0 / history, accuracy: 1e-9, zone)
        }
    }
}
