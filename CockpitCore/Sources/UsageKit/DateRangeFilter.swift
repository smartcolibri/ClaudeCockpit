import Foundation

/// The date-range presets shown in the range filter row. Raw values are kept identical to
/// the source app so a persisted selection survives the port.
public enum DateRangeFilter: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case today = "Today"
    case thisWeek = "This Week"
    case thisMonth = "This Month"
    case prevMonth = "Prev Month"
    case last7Days = "7d"
    case last30Days = "30d"
    case last90Days = "90d"
    case all = "All"

    public var id: String { rawValue }

    /// Returns the inclusive lower bound and exclusive upper bound for this range, or `nil`
    /// bounds for `.all` (no filtering).
    public func bounds(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date?, end: Date?) {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: today)
            return (today, end)
        case .thisWeek:
            // ISO weeks (Monday start) in the caller's time zone, like the weekly cards —
            // the locale calendar would start on Sunday in en_US.
            var isoCalendar = Calendar(identifier: .iso8601)
            isoCalendar.timeZone = calendar.timeZone
            let start = isoCalendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            return (start, nil)
        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? today
            return (start, nil)
        case .prevMonth:
            guard let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start,
                  let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)
            else { return (nil, nil) }
            return (prevMonthStart, thisMonthStart)
        case .last7Days:
            let start = calendar.date(byAdding: .day, value: -6, to: today)
            return (start, nil)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -29, to: today)
            return (start, nil)
        case .last90Days:
            let start = calendar.date(byAdding: .day, value: -89, to: today)
            return (start, nil)
        case .all:
            return (nil, nil)
        }
    }

    /// The window this range is compared with: the same length just before it, ending at the
    /// same point. An open range (today, this week, this month, N days) ends at `now`, so its
    /// previous window ends at `now` moved back by the same calendar step, wall-clock time
    /// kept across a DST switch and clamped to the range's own start; the previous month is
    /// the whole month before. `nil` for `.all`, which has nothing before it.
    public func previousBounds(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        let (start, end) = bounds(now: now, calendar: calendar)
        guard let start else { return nil }
        let step: DateComponents
        switch self {
        case .today: step = DateComponents(day: -1)
        case .thisWeek: step = DateComponents(day: -7)
        case .thisMonth, .prevMonth: step = DateComponents(month: -1)
        case .last7Days: step = DateComponents(day: -7)
        case .last30Days: step = DateComponents(day: -30)
        case .last90Days: step = DateComponents(day: -90)
        case .all: return nil
        }
        guard let previousStart = calendar.date(byAdding: step, to: start),
              // Only the previous month is closed; today's own end (tomorrow) is not reached yet.
              let previousEnd = calendar.date(byAdding: step, to: self == .prevMonth ? (end ?? now) : now)
        else { return nil }
        return (calendar.startOfDay(for: previousStart), min(previousEnd, start))
    }

    /// Whether `date` falls inside this range.
    public func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let (start, end) = bounds(now: now, calendar: calendar)
        if let start, date < start { return false }
        if let end, date >= end { return false }
        return true
    }
}

/// The filters applied on top of the scanned events before aggregation.
/// `models` `nil` (or empty) means every family; `project` is a raw `cwd` value.
public struct UsageFilters: Hashable, Sendable {
    public var models: Set<ModelFamily>?
    public var project: String?
    public var range: DateRangeFilter

    public init(
        models: Set<ModelFamily>? = nil,
        project: String? = nil,
        range: DateRangeFilter = .last30Days
    ) {
        self.models = models
        self.project = project
        self.range = range
    }

    /// Model/project filtering only — the fixed today/this-week comparisons ignore the range
    /// but still respect these two, exactly like the source view model.
    public func matchesModelAndProject(_ event: UsageEvent) -> Bool {
        if let models, !models.isEmpty, !models.contains(ModelFamily.detect(from: event.model)) {
            return false
        }
        if let project, event.cwd != project { return false }
        return true
    }
}
