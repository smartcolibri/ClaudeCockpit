import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// Twelve weeks of sessions per day: one column per week, Monday at the top. Each day is a
/// button that opens the Sessions browser on that day; hovering shows its figures.
///
/// Sessions come from the index (`activity`), the cost from the usage events: the index only
/// knows the cost Claude Code recorded, which most sessions lack.
struct ActivityHeatmapTile: View {
    @Environment(CockpitStore.self) private var store
    let start: Date
    let days: [DayCost]
    let loaded: Bool
    let now: Date

    @State private var hovered: Date?

    private static let cell: CGFloat = 12
    private static let gap: CGFloat = 3
    private let calendar = Calendar.current

    private var sessionsByDay: [Date: Int] {
        Dictionary(days.map { (calendar.startOfDay(for: $0.day), $0.sessions) }, uniquingKeysWith: +)
    }
    private var costByDay: [Date: Double] {
        Dictionary((store.usage?.overview.dailyCost ?? []).map { ($0.day, $0.costUSD) }, uniquingKeysWith: +)
    }

    var body: some View {
        OverviewTile(title: String(localized: "Activity, 12 weeks — sessions per day"), icon: "square.grid.3x3.fill") {
            TileSource(
                state: store.sessionsState, ready: loaded,
                unauthorized: String(localized: "the transcripts cannot be read."),
                retry: { Task { await store.indexSessions() } }
            ) {
                content
            }
        }
    }

    private var content: some View {
        let sessions = sessionsByDay
        let costs = costByDay
        let peak = max(1, sessions.values.max() ?? 1)
        let today = calendar.startOfDay(for: now)
        return HStack(alignment: .top, spacing: 18) {
            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                HStack(spacing: Self.gap) {
                    ForEach(0..<UsageOverview.activityWeeks, id: \.self) { week in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { weekday in
                                let day = date(week: week, weekday: weekday)
                                if day > today {
                                    Color.clear.frame(width: Self.cell, height: Self.cell)
                                } else {
                                    cell(day, sessions: sessions[day] ?? 0, cost: costs[day] ?? 0, peak: peak,
                                         isToday: day == today)
                                }
                            }
                        }
                    }
                }
            }
            .fixedSize()
            details(sessions: sessions, costs: costs, peak: peak)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { weekday in
                Text(verbatim: weekday % 2 == 0 ? weekdaySymbol(weekday) : "")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.slate)
                    .frame(height: Self.cell)
            }
        }
        .accessibilityHidden(true)
    }

    private func cell(_ day: Date, sessions: Int, cost: Double, peak: Int, isToday: Bool) -> some View {
        let intensity = Double(sessions) / Double(peak)
        return Button {
            store.showSessions(day: day)
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(sessions == 0 ? Theme.track.opacity(0.6) : Theme.blue.opacity(0.28 + 0.72 * intensity))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(hovered == day ? Theme.ink.opacity(0.7) : isToday ? Theme.blue : .clear, lineWidth: 1))
                .frame(width: Self.cell, height: Self.cell)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = day } else if hovered == day { hovered = nil }
        }
        .help(Text(verbatim: describe(day, sessions: sessions, cost: cost)))
        .accessibilityLabel(AppFormat.shortDate(day))
        .accessibilityValue(describe(day, sessions: sessions, cost: cost))
        .accessibilityHint(String(localized: "Opens the sessions of this day"))
    }

    /// The hovered day's figures, or the legend when the pointer is elsewhere.
    @ViewBuilder
    private func details(sessions: [Date: Int], costs: [Date: Double], peak: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let day = hovered {
                Text(verbatim: AppFormat.shortDate(day))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(String(localized: "\(sessions[day] ?? 0) sessions", locale: AppFormat.locale))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                Text(verbatim: store.money(costs[day] ?? 0))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.blue)
            } else {
                // Days, not sessions: a session crossing midnight is active on both days.
                let active = sessions.values.filter { $0 > 0 }.count
                Text(String(localized: "\(active) active days in 12 weeks", locale: AppFormat.locale))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Hover a day for its sessions and cost; click to open them.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 3) {
                    Text("Less").font(.system(size: 9)).foregroundStyle(Theme.slate)
                    ForEach([0.0, 0.33, 0.66, 1.0], id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(level == 0 ? Theme.track.opacity(0.6) : Theme.blue.opacity(0.28 + 0.72 * level))
                            .frame(width: 9, height: 9)
                    }
                    Text("More").font(.system(size: 9)).foregroundStyle(Theme.slate)
                }
                .accessibilityHidden(true)
            }
        }
    }

    private func date(week: Int, weekday: Int) -> Date {
        let offset = week * 7 + weekday
        let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
        return calendar.startOfDay(for: day)
    }

    /// Short weekday name for a row, Monday first whatever the locale's first weekday.
    private func weekdaySymbol(_ row: Int) -> String {
        var localized = calendar
        localized.locale = AppFormat.locale
        let symbols = localized.shortWeekdaySymbols  // Sunday first
        return symbols[(row + 1) % 7]
    }

    private func describe(_ day: Date, sessions: Int, cost: Double) -> String {
        "\(AppFormat.shortDate(day)) · " + String(localized: "\(sessions) sessions", locale: AppFormat.locale) + " · \(store.money(cost))"
    }
}
