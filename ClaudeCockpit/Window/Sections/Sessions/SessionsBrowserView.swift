// Sessions browser — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import Combine
import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// Left: every indexed session, grouped and filtered. Right: the transcript of the
/// selected one. The list never reads a transcript itself — everything on a row
/// comes from the index.
struct SessionsBrowserView: View {
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.sessionsGrouping) private var groupingRaw = SessionGrouping.day.rawValue

    @State private var searchText = ""
    @State private var debounce: Task<Void, Never>?
    /// Persisted through the store like the sidebar section: reopening the window on the
    /// transcript you were reading is the expected behaviour, and it gives the snapshot runner
    /// a way to capture the detail view instead of the empty state. The demo keeps its own.
    @State private var selection: String?
    @State private var hits: [SearchHit] = []
    @State private var projects: [ProjectCount] = []
    @State private var period: Period = .all
    @State private var now = Date()
    @State private var targetMessageId: String?
    @FocusState private var searchFocused: Bool

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    enum SessionGrouping: String, CaseIterable, Identifiable {
        case day, project
        var id: String { rawValue }
        var title: String {
            switch self {
            case .day: return String(localized: "By Day")
            case .project: return String(localized: "By Project")
            }
        }
    }

    enum Period: String, CaseIterable, Identifiable {
        case today, week, month, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return String(localized: "Today")
            case .week: return String(localized: "7 days")
            case .month: return String(localized: "30 days")
            case .all: return String(localized: "All")
            }
        }
        func since(_ reference: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .today: return calendar.startOfDay(for: reference)
            case .week: return calendar.date(byAdding: .day, value: -7, to: reference)
            case .month: return calendar.date(byAdding: .day, value: -30, to: reference)
            case .all: return nil
            }
        }
    }

    private var grouping: SessionGrouping {
        SessionGrouping(rawValue: groupingRaw) ?? .day
    }

    var body: some View {
        VStack(spacing: 0) {
            filterHeader
            Divider().opacity(0.4)
            HSplitView {
                listPane
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 520)
                detailPane
                    .frame(minWidth: 420)
            }
        }
        .onReceive(clock) { now = $0 }
        .onAppear { if selection == nil { selection = store.lastSessionSelection } }
        .onChange(of: selection) { _, new in store.lastSessionSelection = new }
        .task { projects = await store.sessionProjects() }
        .onChange(of: store.sessionIndex.lastRun) { _, _ in
            Task { projects = await store.sessionProjects() }
        }
        .onChange(of: searchText) { _, value in scheduleSearch(value) }
        .onDisappear { debounce?.cancel() }
    }

    // MARK: - Header

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                searchField
                Spacer(minLength: 8)
                Picker("Grouping", selection: $groupingRaw) {
                    ForEach(SessionGrouping.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            chips
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.slate)
            TextField("Search All Transcripts", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mist)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .frame(maxWidth: 320)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                projectMenu
                periodMenu
                SessionChip(
                    title: String(localized: "Starred"), systemImage: "star",
                    active: store.sessionFilter.starredOnly, tint: Theme.accent
                ) { store.sessionFilter.starredOnly.toggle() }
                SessionChip(
                    title: String(localized: "With Errors"), systemImage: "exclamationmark.triangle",
                    active: store.sessionFilter.withErrorsOnly, tint: .red
                ) { store.sessionFilter.withErrorsOnly.toggle() }
                SessionChip(
                    title: String(localized: "Sub-agents"), systemImage: "person.2",
                    active: store.sessionFilter.includeSubagents, tint: Theme.violet
                ) { store.sessionFilter.includeSubagents.toggle() }
            }
            .padding(.vertical, 1)
        }
    }

    private var projectMenu: some View {
        Menu {
            Button("All Projects") { store.sessionFilter.projectCwd = nil }
            Divider()
            ForEach(projects) { project in
                Button(UsagePath.shorten(project.cwd) + " (\(project.sessions))") {
                    store.sessionFilter.projectCwd = project.cwd
                }
            }
        } label: {
            SessionChip(
                title: store.sessionFilter.projectCwd.map { UsagePath.shorten($0) } ?? String(localized: "Project"),
                systemImage: "folder",
                active: store.sessionFilter.projectCwd != nil,
                tint: Theme.blue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var periodMenu: some View {
        Menu {
            ForEach(Period.allCases) { value in
                Button(value.title) {
                    period = value
                    // Also leaves a single day picked from the Overview's activity grid.
                    store.sessionFilter.since = value.since(Date())
                    store.sessionFilter.until = nil
                }
            }
        } label: {
            SessionChip(
                title: dayFilterTitle ?? period.title,
                systemImage: "calendar",
                active: dayFilterTitle != nil || period != .all,
                tint: Theme.blue)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// The day the Overview's activity grid opened the browser on: a bounded filter no
    /// period of the menu describes, so the chip names it instead.
    private var dayFilterTitle: String? {
        guard store.sessionFilter.until != nil, let since = store.sessionFilter.since else { return nil }
        return AppFormat.shortDate(since)
    }

    // MARK: - Search

    /// The store's `sessionFilter` re-queries on every assignment, so the query
    /// only lands once the typing has stopped.
    private func scheduleSearch(_ value: String) {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            store.sessionFilter.query = trimmed
            let results = trimmed.isEmpty ? [] : await store.searchSessions(trimmed)
            guard !Task.isCancelled else { return }
            hits = results
        }
    }

    private var hitsBySession: [String: [SearchHit]] {
        Dictionary(grouping: hits, by: \.sessionId)
    }

    // MARK: - List

    @ViewBuilder
    private var listPane: some View {
        if store.sessions.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.items) { session in
                            SessionRowView(
                                session: session,
                                now: now,
                                hits: hitsBySession[session.id] ?? [],
                                onSelectHit: { hit in
                                    selection = hit.sessionId
                                    targetMessageId = hit.messageId
                                })
                                .tag(session.id)
                        }
                    }
                }
                if store.sessionsTruncated {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Showing only \(store.sessions.count) sessions · there are more")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.slate)
                            Button("Show 200 More Sessions") {
                                Task { await store.loadMoreSessions() }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.inset)
            .onKeyPress(keys: ["j", "k"]) { press in
                guard !searchFocused else { return .ignored }
                move(by: press.key == "j" ? 1 : -1)
                return .handled
            }
        }
    }

    private var flattenedIds: [String] {
        groups.flatMap { $0.items.map(\.id) }
    }

    private func move(by delta: Int) {
        let ids = flattenedIds
        guard !ids.isEmpty else { return }
        guard let current = selection, let index = ids.firstIndex(of: current) else {
            selection = ids.first
            return
        }
        let next = min(max(0, index + delta), ids.count - 1)
        selection = ids[next]
    }

    // MARK: - Grouping

    struct SessionGroupRows: Identifiable {
        let id: String
        let title: String
        let items: [SessionRef]
    }

    private var groups: [SessionGroupRows] {
        switch grouping {
        case .day: return dayGroups
        case .project: return projectGroups
        }
    }

    private var dayGroups: [SessionGroupRows] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: store.sessions) {
            calendar.startOfDay(for: $0.lastTimestamp)
        }
        let formatter = ISO8601DateFormatter()
        return buckets.keys.sorted(by: >).map { day in
            SessionGroupRows(
                id: formatter.string(from: day),
                title: dayTitle(day, calendar: calendar),
                items: (buckets[day] ?? []).sorted { $0.lastTimestamp > $1.lastTimestamp })
        }
    }

    private func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return AppFormat.shortDate(day)
    }

    private var projectGroups: [SessionGroupRows] {
        let buckets = Dictionary(grouping: store.sessions, by: \.cwd)
        let ordered = buckets.keys.sorted { left, right in
            let lastLeft = buckets[left]?.map(\.lastTimestamp).max() ?? .distantPast
            let lastRight = buckets[right]?.map(\.lastTimestamp).max() ?? .distantPast
            return lastLeft > lastRight
        }
        return ordered.map { cwd in
            SessionGroupRows(
                id: cwd,
                title: UsagePath.shorten(cwd),
                items: (buckets[cwd] ?? []).sorted { $0.lastTimestamp > $1.lastTimestamp })
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.sessionIndex.isRunning {
                ProgressView().controlSize(.small)
                Text("Indexing Transcripts…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("\(String(localized: "\(store.sessionIndex.filesDone) files", locale: AppFormat.locale)) out of \(store.sessionIndex.filesTotal). The list fills in as it goes.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: emptyIcon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.mist)
                Text(emptyTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                if store.sessionIndex.lastRun == nil {
                    Button("Index Now") { Task { await store.indexSessions() } }
                        .controlSize(.small)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasActiveFilter: Bool {
        let filter = store.sessionFilter
        return !filter.query.isEmpty || filter.projectCwd != nil || filter.since != nil
            || filter.starredOnly || filter.withErrorsOnly
    }

    private var emptyIcon: String {
        if store.sessionIndex.lastRun == nil { return "tray" }
        return hasActiveFilter ? "line.3.horizontal.decrease.circle" : "text.bubble"
    }

    private var emptyTitle: String {
        if store.sessionIndex.lastRun == nil { return String(localized: "Index not built") }
        if hasActiveFilter { return String(localized: "No results") }
        return String(localized: "No sessions indexed")
    }

    private var emptyMessage: String {
        if store.sessionIndex.lastRun == nil {
            return String(localized: "The transcripts in ~/.claude/projects have not been read yet.")
        }
        if hasActiveFilter {
            return String(localized: "No session matches this filter. Widen the period or remove a criterion.")
        }
        return String(localized: "No transcripts found in ~/.claude/projects.")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let id = selection, let session = store.sessions.first(where: { $0.id == id }) {
            SessionDetailView(session: session, targetMessageId: $targetMessageId)
                .id(session.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.mist)
                Text("Select a Session")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("The full transcript shows here: turns, tool calls, diffs and sub-agents.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
    }
}

// MARK: - Row

/// One session in the list. Everything shown, the health grade included, comes from the
/// `SessionRef` the list already holds — no row does any I/O of its own.
///
/// This used to query `store.sessionHealth` per row as it scrolled into view. That call
/// is a pure function of the same stored counters `SessionRef.healthGrade` is derived
/// from, so it could never return anything else, and it serialised every visible row
/// behind the indexing actor during a rebuild.
private struct SessionRowView: View {
    let session: SessionRef
    let now: Date
    let hits: [SearchHit]
    let onSelectHit: (SearchHit) -> Void

    @Environment(CockpitStore.self) private var store

    private var isLive: Bool {
        now.timeIntervalSince(session.lastTimestamp) < SessionsPalette.liveWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleLine
            Text(UsagePath.shorten(session.cwd))
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
                .truncationMode(.head)
            statsLine
            ForEach(Array(hits.prefix(3))) { hit in
                Button { onSelectHit(hit) } label: {
                    Text(SessionsPalette.oneLine(hit.snippet(
                        open: AppFormat.locale.quotationBeginDelimiter ?? "“",
                        close: AppFormat.locale.quotationEndDelimiter ?? "”"), limit: 180))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this message in the transcript")
            }
        }
        .padding(.vertical, 4)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Button {
                Task { await store.setSessionStarred(!session.isStarred, sessionId: session.id) }
            } label: {
                Image(systemName: session.isStarred ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(session.isStarred ? Theme.accent : Theme.mist)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isStarred ? Text("Remove from Favorites") : Text("Add to Favorites"))

            Text(session.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            if isLive {
                Circle()
                    .fill(Theme.emerald)
                    .frame(width: 6, height: 6)
                    .help("Session active right now")
                    .accessibilityLabel("Active session")
            }
            if session.isSubagent {
                Image(systemName: "person.2")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.violet)
                    .help("Sub-agent transcript")
            }
            Spacer(minLength: 4)
            HealthBadge(grade: session.healthGrade, compact: true)
        }
    }

    private var statsLine: some View {
        HStack(spacing: 8) {
            Text(AppFormat.time(session.firstTimestamp))
            Text(AppFormat.duration(session.duration))
            Text("\(session.userTurns + session.assistantTurns) turns")
            if session.toolErrors > 0 {
                Text("\(AppFormat.integer(session.toolErrors)) err.").foregroundStyle(.red)
            }
            Spacer(minLength: 4)
            // `~` marks a cost priced from tokens rather than read from the
            // transcript, so an estimate never passes for a measured figure.
            Text(store.sessionCost(session).map { $0.estimated ? "~\(store.money($0.usd))" : store.money($0.usd) } ?? "–")
                .foregroundStyle(store.sessionCost(session) == nil ? Theme.mist : Theme.blue)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Theme.mist)
    }
}
