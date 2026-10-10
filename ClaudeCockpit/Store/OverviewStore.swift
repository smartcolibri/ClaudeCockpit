// Overview side of the store: the reads its tiles need and the jumps they offer.
import Foundation
import CockpitShared
import SessionsKit

extension CockpitStore {

    // MARK: Reads

    /// Every top-level session active since `date`, for the 7-day health mean. Its own
    /// filter, like `todaySessions`, so the browser's filter and page size never leak in.
    func sessions(since date: Date) async -> [SessionRef] {
        var filter = SessionFilter()
        filter.since = date
        filter.limit = 2_000
        return (try? await sessionService.listSessions(filter)) ?? []
    }

    // MARK: Navigation

    /// Selects a sidebar section. The window binds the same defaults key, so it follows.
    func show(_ section: CockpitSection) {
        UserDefaults.standard.set(section.rawValue, forKey: SettingsKey.mainSection)
    }

    /// Opens the Sessions browser on a fresh filter: whatever the user had narrowed it to
    /// would otherwise hide what the Overview pointed at.
    func showSessions(withErrorsOnly: Bool = false, day: Date? = nil, selecting sessionId: String? = nil,
                      calendar: Calendar = .current) {
        var filter = SessionFilter()
        filter.withErrorsOnly = withErrorsOnly
        if let day {
            let start = calendar.startOfDay(for: day)
            filter.since = start
            // `until` bounds the session's first line: anything that began before the next
            // midnight and was still active on the day.
            filter.until = (calendar.date(byAdding: .day, value: 1, to: start) ?? start).addingTimeInterval(-1)
        }
        sessionFilter = filter
        if let sessionId { lastSessionSelection = sessionId }
        UserDefaults.standard.set(SessionsView.SessionsTab.browser.rawValue, forKey: SettingsKey.sessionsTab)
        show(.sessions)
    }
}
