import XCTest
@testable import UsageKit

final class DateRangeFilterTests: XCTestCase {
    private let calendar = TestClock.calendar
    /// Wednesday 2026-09-23, 12:00 UTC.
    private let now = TestClock.now

    private func bounds(_ range: DateRangeFilter) -> (start: Date?, end: Date?) {
        range.bounds(now: now, calendar: calendar)
    }

    func testTodayIsTheCalendarDay() {
        let (start, end) = bounds(.today)
        XCTAssertEqual(start, TestClock.date("2026-09-23T00:00:00Z"))
        XCTAssertEqual(end, TestClock.date("2026-09-24T00:00:00Z"))
        XCTAssertTrue(DateRangeFilter.today.contains(now, now: now, calendar: calendar))
        XCTAssertFalse(DateRangeFilter.today.contains(
            TestClock.date("2026-09-22T23:59:59Z"), now: now, calendar: calendar))
        XCTAssertFalse(DateRangeFilter.today.contains(
            TestClock.date("2026-09-24T00:00:00Z"), now: now, calendar: calendar))
    }

    /// "This week" follows ISO weeks (Monday start), like the weekly cards, whatever the
    /// caller's locale: the week of Wednesday the 23rd opens on Monday the 21st.
    func testThisWeekStartsOnTheISOMonday() {
        let (start, end) = bounds(.thisWeek)
        XCTAssertEqual(start, TestClock.date("2026-09-21T00:00:00Z"))
        XCTAssertNil(end)
    }

    /// An en_US calendar starts weeks on Sunday; on Sunday the 27th it would reset "this week"
    /// to that single day while the weekly cards still cover Monday the 21st onwards.
    func testThisWeekIgnoresTheLocaleFirstWeekdayButKeepsTheTimeZone() {
        var usCalendar = Calendar(identifier: .gregorian)
        usCalendar.locale = Locale(identifier: "en_US")
        usCalendar.firstWeekday = 1
        usCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        // Sunday 2026-09-27, 12:00 in New York.
        let sunday = TestClock.date("2026-09-27T16:00:00Z")

        let start = DateRangeFilter.thisWeek.bounds(now: sunday, calendar: usCalendar).start
        // Monday 2026-09-21 00:00 New York time (EDT, UTC-4).
        XCTAssertEqual(start, TestClock.date("2026-09-21T04:00:00Z"))
    }

    func testThisMonthAndPreviousMonth() {
        let (thisStart, thisEnd) = bounds(.thisMonth)
        XCTAssertEqual(thisStart, TestClock.date("2026-09-01T00:00:00Z"))
        XCTAssertNil(thisEnd)

        let (prevStart, prevEnd) = bounds(.prevMonth)
        XCTAssertEqual(prevStart, TestClock.date("2026-08-01T00:00:00Z"))
        XCTAssertEqual(prevEnd, TestClock.date("2026-09-01T00:00:00Z"))
        // Previous month is the only bounded range besides Today: August 31 is in, Sept 1 is out.
        XCTAssertTrue(DateRangeFilter.prevMonth.contains(
            TestClock.date("2026-08-31T23:00:00Z"), now: now, calendar: calendar))
        XCTAssertFalse(DateRangeFilter.prevMonth.contains(
            TestClock.date("2026-09-01T00:00:00Z"), now: now, calendar: calendar))
    }

    /// The rolling windows count today as day one, so 7 days reaches back 6 days.
    func testRollingWindowsIncludeToday() {
        XCTAssertEqual(bounds(.last7Days).start, TestClock.date("2026-09-17T00:00:00Z"))
        XCTAssertEqual(bounds(.last30Days).start, TestClock.date("2026-08-25T00:00:00Z"))
        XCTAssertEqual(bounds(.last90Days).start, TestClock.date("2026-06-26T00:00:00Z"))
        XCTAssertNil(bounds(.last7Days).end)
        XCTAssertFalse(DateRangeFilter.last7Days.contains(
            TestClock.date("2026-09-16T23:59:59Z"), now: now, calendar: calendar))
        XCTAssertTrue(DateRangeFilter.last7Days.contains(
            TestClock.date("2026-09-17T00:00:00Z"), now: now, calendar: calendar))
    }

    func testAllHasNoBounds() {
        let (start, end) = bounds(.all)
        XCTAssertNil(start)
        XCTAssertNil(end)
        XCTAssertTrue(DateRangeFilter.all.contains(
            TestClock.date("1999-01-01T00:00:00Z"), now: now, calendar: calendar))
    }

    func testRawValuesAndLabelsCoverEveryCase() {
        XCTAssertEqual(
            DateRangeFilter.allCases.map(\.rawValue),
            ["Today", "This Week", "This Month", "Prev Month", "7d", "30d", "90d", "All"])
        XCTAssertEqual(DateRangeFilter(rawValue: "Prev Month"), .prevMonth)
        XCTAssertEqual(DateRangeFilter.prevMonth.frenchLabel, "Mois précédent")
        XCTAssertTrue(DateRangeFilter.allCases.allSatisfy { !$0.frenchLabel.isEmpty })
    }
}
