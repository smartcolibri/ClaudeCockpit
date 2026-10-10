import SwiftUI
import CockpitShared
import RTKKit
import SessionsKit
import SkillsKit
import UsageKit

/// The landing screen: four KPI tiles, then the insights and today's sessions on
/// the left and the RTK week on the right. Every block carries its own banner, so
/// a failing source never blanks the page.
struct OverviewView: View {
    @Environment(CockpitStore.self) private var store
    @State private var now = Date()

    /// Today's sessions, from the store's own dedicated query rather than from
    /// `store.sessions`, which is the browser's filtered page.
    @State private var todaySessions: [SessionRef] = []
    /// When `todaySessions` was read — what "since midnight" and the relative time
    /// of the latest session are measured against.
    @State private var sessionsAsOf = Date()
    @State private var sessionsLoaded = false

    private var rtkWeekSaved: Int {
        store.rtk?.last7Days.reduce(0) { $0 + $1.savedTokens } ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                tiles
                HStack(alignment: .top, spacing: 16) {
                    mainColumn.frame(maxWidth: .infinity, alignment: .leading)
                    sideColumn.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
        .onAppear { now = Date() }
        // Re-read after every index pass: a session that started since the last one
        // would otherwise never reach the card.
        .task(id: store.sessionIndex.lastRun) {
            let asOf = Date()
            let rows = await store.todaySessions(now: asOf)
            guard !Task.isCancelled else { return }
            sessionsAsOf = asOf
            todaySessions = rows
            sessionsLoaded = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Overview").font(.display(24, weight: .bold))
                Text(updatedCaption).font(.system(size: 12)).foregroundStyle(Theme.slate)
            }
            Spacer()
        }
    }

    /// The freshest of the sources — what "updated" means at a glance.
    private var updatedCaption: String {
        let dates = [
            store.usageState.lastSuccess, store.rtkState.lastSuccess, store.skillsState.lastSuccess,
        ].compactMap { $0 }
        guard let latest = dates.max() else { return String(localized: "No source read yet") }
        return String(localized: "Updated \(AppFormat.relative(latest, now: now))")
    }

    // MARK: Tiles

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
            StatTile(
                label: String(localized: "Today's cost"),
                value: store.usage.map { store.money($0.costTodayUnfilteredUSD) } ?? "—",
                note: store.usage.map { String(localized: "\(store.money($0.costThisWeekUnfilteredUSD)) since Monday") },
                tint: Theme.blue,
                icon: "eurosign.circle")
            StatTile(
                label: String(localized: "Tokens today"),
                value: store.usage.map { AppFormat.tokens($0.tokensTodayUnfiltered) } ?? "—",
                note: store.usage == nil ? nil : String(localized: "since midnight, cache included"),
                tint: Theme.blue,
                icon: "number.circle")
            StatTile(
                label: String(localized: "RTK tokens saved, 7 days"),
                value: store.rtk == nil ? "—" : AppFormat.tokens(rtkWeekSaved),
                note: store.rtk.map { String(localized: "\(AppFormat.tokens($0.today.savedTokens)) today") },
                tint: Theme.emerald,
                icon: "scissors")
            StatTile(
                label: String(localized: "Active skills"),
                value: store.skills.map { AppFormat.integer($0.count(kind: .skill, level: .global)) } ?? "—",
                note: store.skills.map { String(localized: "\(AppFormat.integer($0.count(kind: .skill))) in total, all levels") },
                tint: Theme.violet,
                icon: "sparkles")
        }
    }

    // MARK: Left column — insights & sessions

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: String(localized: "Insights"))
            insightsCard
            SectionLabel(text: String(localized: "Sessions today"))
            sessionsTodayCard
        }
    }

    // MARK: Right column — RTK

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: String(localized: "Last seven days"))
            rtkWeekCard
        }
    }

    // MARK: Sessions today

    /// Recorded cost where the transcript has one, priced from the per-model
    /// tokens everywhere else, and a count of the sessions that offer neither.
    /// A missing cost is never counted as zero.
    private var todayCost: (total: Double, missing: Int) {
        todaySessions.reduce(into: (total: 0.0, missing: 0)) { result, session in
            if let cost = store.sessionCost(session) { result.total += cost.usd } else { result.missing += 1 }
        }
    }

    private var sessionsTodayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.sessionsState.isUnauthorized {
                AccessRequiredBanner(message: String(localized: "the transcripts cannot be read."))
            } else if let message = store.sessionsState.errorMessage {
                SourceBanner(
                    kind: .info,
                    message: String(localized: "Sessions index unavailable: \(message)"),
                    action: { Task { await store.indexSessions() } },
                    actionTitle: String(localized: "Reindex"))
            } else if !sessionsLoaded || (todaySessions.isEmpty && store.sessionIndex.isRunning) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.sessionIndex.isRunning
                        ? String(localized: "Indexing transcripts…")
                        : String(localized: "Reading today's sessions…"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if todaySessions.isEmpty {
                Text("No sessions since midnight.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(AppFormat.integer(todaySessions.count))
                        .font(.display(26))
                        .monospacedDigit()
                        .foregroundStyle(Theme.violet)
                    // Never zero here: the empty case is handled above, so one/many is the whole rule.
                    (todaySessions.count == 1 ? Text("session") : Text("sessions"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.slate)
                    Spacer()
                    Text(costLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.blue)
                }
                if let latest = todaySessions.first {
                    Text(latest.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("last activity \(AppFormat.relative(latest.lastTimestamp, now: sessionsAsOf))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
                if todayCost.missing > 0 {
                    Text(costCaveat)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private var costLabel: String {
        let cost = todayCost
        // Every session lacking its cost line: a total would be a fabricated zero.
        if cost.missing == todaySessions.count { return String(localized: "cost unknown") }
        return store.money(cost.total)
    }

    private var costCaveat: String {
        let missing = todayCost.missing
        return missing == todaySessions.count
            ? String(localized: "None of these sessions recorded its cost.")
            : String(localized: "Partial cost: \(missing) sessions without a recorded cost.")
    }

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.usageState.isUnauthorized {
                AccessRequiredBanner(message: String(localized: "the transcripts cannot be read."))
            } else if let message = store.usageState.errorMessage {
                SourceBanner(kind: .error, message: message, action: { Task { await store.refreshUsage() } })
            } else if let insights = store.usage?.insights, !notable(insights).isEmpty {
                let rows = notable(insights)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, insight in
                    if index > 0 { Divider().opacity(0.4) }
                    insightRow(insight)
                }
            } else {
                Text(store.usage == nil ? String(localized: "Reading transcripts…") : String(localized: "Nothing notable in the period analyzed."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
        .padding(14)
        .card()
    }

    /// `noNotableChange` is an empty state, not a bullet.
    private func notable(_ insights: [Insight]) -> [Insight] {
        insights.filter { $0.kind != .noNotableChange }
    }

    private func insightRow(_ insight: Insight) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(insight.level))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color(insight.level))
                .frame(width: 18)
            Text(sentence(insight))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func color(_ level: Insight.Level) -> Color {
        switch level {
        case .critical: .red
        case .warning: .orange
        case .good: Theme.emerald
        case .info: Theme.blue
        }
    }
    private func icon(_ level: Insight.Level) -> String {
        switch level {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .good: "checkmark.seal.fill"
        case .info: "info.circle.fill"
        }
    }

    /// The engine's sentence is fixed English; `kind` carries the same information, so the
    /// wording is rebuilt here, where the String Catalog can translate it.
    private func sentence(_ insight: Insight) -> String {
        switch insight.kind {
        case .costUp(let fraction):
            return String(localized: "Cost is up \(AppFormat.percent(fraction)) compared with the same point last week.")
        case .costDown(let fraction):
            return String(localized: "Cost is down \(AppFormat.percent(fraction)) compared with the same point last week.")
        case .unpricedModel(let model):
            return String(localized: "The model \(model) has no dedicated pricing: the Sonnet rate is applied to it.")
        case .cacheHitRate(let rate):
            return String(localized: "The cache is working well: \(AppFormat.percent(rate)) of reusable tokens are read back.")
        case .noNotableChange:
            return String(localized: "Nothing notable in the period analyzed.")
        }
    }

    private var rtkWeekCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.rtkState.isUnauthorized {
                AccessRequiredBanner(message: String(localized: "the RTK database is outside the allowed folders."))
            } else if let message = store.rtkState.errorMessage {
                SourceBanner(kind: .info, message: message, action: { Task { await store.refreshRTK() } })
            } else if let days = store.rtk?.last7Days, !days.isEmpty {
                let peak = max(1, days.map(\.savedTokens).max() ?? 1)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(days) { day in
                        VStack(spacing: 6) {
                            Capsule()
                                .fill(day.savedTokens > 0 ? Theme.emerald : Theme.track)
                                .frame(height: max(4, 74 * CGFloat(day.savedTokens) / CGFloat(peak)))
                            Text(AppFormat.weekday(day.date))
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.slate)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 96, alignment: .bottom)
                Text("\(AppFormat.tokens(rtkWeekSaved)) tokens avoided over seven days")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.slate)
            } else {
                Text(store.rtk == nil ? String(localized: "Reading the rtk database…") : String(localized: "No filtered commands in the last seven days."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }
}
