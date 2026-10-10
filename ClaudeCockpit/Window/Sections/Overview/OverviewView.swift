import SwiftUI
import CockpitShared
import OverviewKit
import RTKKit
import SessionsKit
import UsageKit

/// The landing screen, a bento of tiles: today's cost, tokens and RTK week; cost per day by
/// model and the top projects; the day by hour, session health and skills; twelve weeks of
/// activity. A column on the right carries the recommendations and today's sessions.
///
/// Every figure ignores the Usage screen's filters, and every tile carries its own source
/// state, so a failing source never blanks the page. Below `wideLayout` points the column
/// moves under the tiles instead of squeezing them.
struct OverviewView: View {
    @Environment(CockpitStore.self) private var store
    @State private var now = Date()

    /// Today's sessions, from the store's own query rather than from `store.sessions`, which
    /// is the browser's filtered page.
    @State private var todaySessions: [SessionRef] = []
    @State private var weekSessions: [SessionRef] = []
    @State private var activity: [DayCost] = []
    /// Sessions with an error in a message dated today, not every active session that ever failed.
    @State private var erroredToday: Set<String> = []
    @State private var sessionsLoaded = false

    static let wideLayout: CGFloat = 920
    static let sideColumnWidth: CGFloat = 270
    /// Fixed so the bento, heatmap included, fits the default window (1160 × 760) without
    /// scrolling: left to their ideal sizes, charts ask for far more height than they need.
    static let rowHeights: [CGFloat] = [118, 150, 112]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if geometry.size.width >= Self.wideLayout {
                        HStack(alignment: .top, spacing: 12) {
                            bento
                            sideColumn
                                .frame(width: Self.sideColumnWidth)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        bento
                        sideColumn
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .onAppear { now = Date() }
        // Re-read after every index pass: a session that started since the last one would
        // otherwise never reach the tiles.
        .task(id: store.sessionIndex.lastRun) { await loadSessions() }
    }

    private func loadSessions() async {
        let asOf = Date()
        let calendar = Calendar.current
        let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: asOf)) ?? asOf
        let start = UsageOverview.activityStart(now: asOf, calendar: calendar)
        async let today = store.todaySessions(now: asOf)
        async let week = store.sessions(since: weekStart)
        async let report = store.sessionActivity(since: start, until: asOf)
        async let errored = store.sessionsWithErrorsToday(now: asOf)
        let (todayRows, weekRows, activityReport, erroredRows) = await (today, week, report, errored)
        guard !Task.isCancelled else { return }
        now = asOf
        todaySessions = todayRows
        weekSessions = weekRows
        activity = activityReport.days
        erroredToday = erroredRows
        sessionsLoaded = true
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Overview").font(.display(22, weight: .bold))
            Text(updatedCaption).font(.system(size: 12)).foregroundStyle(Theme.slate)
        }
    }

    /// The freshest of the sources — what "updated" means at a glance.
    private var updatedCaption: String {
        let dates = [
            store.usageState.lastSuccess, store.rtkState.lastSuccess, store.skillsState.lastSuccess,
        ].compactMap { $0 }
        guard let latest = dates.max() else { return String(localized: "No source read yet") }
        return String(localized: "Updated \(AppFormat.relative(latest, now: now))", locale: AppFormat.locale)
    }

    // MARK: Tiles

    private var bento: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                TodayCostTile()
                TokensTodayTile()
                RTKWeekTile()
            }
            .frame(height: Self.rowHeights[0])
            GridRow {
                CostPerDayTile().gridCellColumns(2)
                TopProjectsTile()
            }
            .frame(height: Self.rowHeights[1])
            GridRow {
                HourlyTile()
                SessionHealthTile(today: todaySessions, week: weekSessions, erroredToday: erroredToday.count, loaded: sessionsLoaded)
                ActiveSkillsTile()
            }
            .frame(height: Self.rowHeights[2])
            GridRow {
                ActivityHeatmapTile(
                    start: UsageOverview.activityStart(now: now, calendar: .current),
                    days: activity, loaded: sessionsLoaded, now: now)
                    .gridCellColumns(3)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Side column

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            RecommendationsCard(recommendations: recommendations, ready: store.usage != nil || sessionsLoaded)
            TodaySessionsCard(sessions: todaySessions, loaded: sessionsLoaded)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
        .card()
    }

    // MARK: Recommendations

    private var recommendations: [Recommendation] {
        RecommendationEngine.recommend(RecommendationInput(
            usage: store.usage.map { Self.usageFacts($0.overview) },
            sessions: sessionsLoaded && store.sessionsState.errorMessage == nil && !store.sessionsState.isUnauthorized
                ? RecommendationInput.Sessions(
                    withErrorsToday: erroredToday.count,
                    lowHealthToday: todaySessions.filter { $0.healthScore < SessionHealthTile.lowScore }.count)
                : nil,
            rtk: rtkFacts))
    }

    static func usageFacts(_ overview: UsageOverview) -> RecommendationInput.Usage {
        RecommendationInput.Usage(
            costThisWeekToDateUSD: overview.costThisWeekToDateUSD,
            costLastWeekToDateUSD: overview.costLastWeekToDateUSD,
            elapsedThisWeek: overview.elapsedThisWeek,
            cost30DaysUSD: overview.cost30DaysUSD,
            opusShare30Days: overview.opusShare,
            opusSharePrevious30Days: overview.opusSharePrevious30Days,
            topOpusProject: overview.topOpusProject,
            hourlyCostToday: overview.hourlyToday.map(\.estimatedCostUSD),
            cacheHitRate30Days: overview.cacheHitRate,
            cacheableTokens30Days: overview.cacheableTokens30Days,
            unpricedModels: overview.unpricedModels,
            monthProjectionUSD: overview.monthProjectionUSD,
            monthElapsedDays: overview.monthElapsedDays,
            lastMonthCostUSD: overview.lastMonthCostUSD)
    }

    /// RTK is "missing" only when the source answered that no database exists; unread,
    /// refused or failing for another reason, it says nothing either way.
    private var rtkFacts: RecommendationInput.RTK {
        if store.rtkIsMissing { return .missing }
        // A failing read keeps the last snapshot on screen; its figures are not advice material.
        guard store.rtkState.errorMessage == nil, !store.rtkState.isUnauthorized else { return .unknown }
        if let rtk = store.rtk {
            let saved = rtk.last7Days.reduce(0) { $0 + $1.savedTokens }
            let input = rtk.last7Days.reduce(0) { $0 + $1.inputTokens }
            let commands = rtk.last7Days.reduce(0) { $0 + $1.count }
            return .active(savedFraction: input > 0 ? Double(saved) / Double(input) : 0, commands: commands)
        }
        return .unknown
    }
}
