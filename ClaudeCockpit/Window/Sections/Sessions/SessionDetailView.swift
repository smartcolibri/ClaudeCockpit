// Session transcript detail — see docs/superpowers/specs/2026-09-23-sessions-viewer.md
import AppKit
import SwiftUI
import CockpitShared
import SessionsKit
import UsageKit

/// The full transcript of one session, paged.
///
/// A session can hold tens of thousands of lines and the benchmark transcript is
/// 35 MB, so the body never asks for more than ``pageSize`` messages at a time and
/// appends the next page as the reader nears the end. `sessionMessageCount` gives
/// the total so the footer can say how far in the reader is.
struct SessionDetailView: View {
    let session: SessionRef
    /// A message the browser wants scrolled to — a search hit, typically.
    @Binding var targetMessageId: String?

    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.sessionsShowSystemLines) private var showSystemLines = false

    @State private var messages: [SessionMessage] = []
    /// `toolUseId → tool_result`, rebuilt as pages land. A call and its result sit
    /// on two transcript lines, so a page boundary can separate them.
    @State private var results: [String: ContentBlock] = [:]
    @State private var elapsedById: [String: TimeInterval] = [:]
    @State private var total = 0
    @State private var isLoading = false
    /// Bumped by every `reload`. A page that comes back under an older generation was
    /// fetched for another session or with the other `includeMeta`, and is dropped.
    @State private var loadGeneration = 0
    @State private var reachedEnd = false
    @State private var health: SessionHealth?
    @State private var showHealth = false
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var confirmHide = false
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findMatches: [String] = []
    @State private var findIndex = 0
    @State private var scrollTarget: String?
    @State private var targetMissing = false
    @State private var isChasingTarget = false
    @FocusState private var findFocused: Bool
    @FocusState private var titleFocused: Bool

    private static let pageSize = 200

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if findVisible {
                findBar
                Divider().opacity(0.4)
            }
            transcript
        }
        .background(Theme.background)
        .task(id: session.id) { await reload() }
        .onChange(of: showSystemLines) { _, _ in
            // Not a display filter: the store passes it to the service as
            // `includeMeta`, so the pages themselves change and must be refetched.
            Task { await reload() }
        }
        .onChange(of: targetMessageId) { _, _ in resolveTarget() }
        .onChange(of: findQuery) { _, _ in recomputeMatches() }
        .alert("Hide This Session?", isPresented: $confirmHide) {
            Button("Cancel", role: .cancel) {}
            Button("Hide", role: .destructive) {
                Task { await store.hideSession(session.id) }
            }
        } message: {
            Text("The session disappears from the list. The transcript on disk is never changed, and rebuilding the index brings it back.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                titleField
                Spacer(minLength: 8)
                toolbar
            }
            metaLine
            statsLine
            if !session.prLinks.isEmpty { prLine }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.panel)
    }

    @ViewBuilder
    private var titleField: some View {
        if isEditingTitle {
            TextField("Session title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.display(16))
                .foregroundStyle(Theme.ink)
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .frame(maxWidth: 420)
        } else {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(.display(16))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Button {
                    titleDraft = session.customName ?? session.title
                    isEditingTitle = true
                    titleFocused = true
                } label: {
                    Image(systemName: "pencil").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mist)
                .help("Rename the session")
                .accessibilityLabel("Rename the session")
            }
        }
    }

    private func commitTitle() {
        isEditingTitle = false
        titleFocused = false
        let draft = titleDraft
        Task { await store.renameSession(session.id, to: draft) }
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            Label(UsagePath.shorten(session.cwd), systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.head)
            if let branch = session.gitBranch, !branch.isEmpty {
                Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
            }
            if let version = session.claudeVersion, !version.isEmpty {
                Label("Claude Code \(version)", systemImage: "app.badge").lineLimit(1)
            }
            Label(AppFormat.dateTime(session.firstTimestamp), systemImage: "calendar")
            Label(AppFormat.duration(session.duration), systemImage: "clock")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.slate)
    }

    /// One row when the pane is wide enough; otherwise the token chips and the rest
    /// split over two rows, so no pill ever wraps its own label.
    private var statsLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                tokenChips
                activityChips
                Spacer(minLength: 8)
                healthControl
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { tokenChips }
                HStack(spacing: 6) {
                    activityChips
                    Spacer(minLength: 8)
                    healthControl
                }
            }
        }
    }

    @ViewBuilder
    private var tokenChips: some View {
        SessionChip(title: String(localized: "Input \(AppFormat.tokens(session.inputTokens))", locale: AppFormat.locale), tint: Theme.blue)
        SessionChip(title: String(localized: "Output \(AppFormat.tokens(session.outputTokens))", locale: AppFormat.locale), tint: Theme.blue)
        SessionChip(
            title: String(localized: "Cache \(AppFormat.tokens(session.cacheReadTokens + session.cacheCreationTokens))", locale: AppFormat.locale),
            tint: Theme.blue)
    }

    @ViewBuilder
    private var activityChips: some View {
        if let cost = store.sessionCost(session) {
            // Estimated from the per-model tokens when the transcript carries
            // no recorded total; the tilde keeps the two apart.
            SessionChip(
                title: cost.estimated ? "~\(store.money(cost.usd))" : store.money(cost.usd),
                systemImage: "eurosign.circle", active: true, tint: Theme.blue)
        }
        SessionChip(title: String(localized: "\(session.toolCalls) tools", locale: AppFormat.locale), systemImage: "wrench.and.screwdriver")
        if session.toolErrors > 0 {
            SessionChip(
                title: String(localized: "\(session.toolErrors) errors", locale: AppFormat.locale),
                systemImage: "exclamationmark.triangle", active: true, tint: .red)
        }
    }

    @ViewBuilder
    private var healthControl: some View {
        if let health {
            Button { showHealth.toggle() } label: {
                HStack(spacing: 5) {
                    HealthBadge(grade: health.grade)
                    Text(verbatim: "\(health.score)/100")
                        .font(.data(10))
                        .monospacedDigit()
                        .fixedSize()
                        .foregroundStyle(Theme.slate)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Health grade details")
            .popover(isPresented: $showHealth, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        HealthBadge(grade: health.grade)
                        Text("Session health · \(health.score)/100")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    if health.evidence.isEmpty {
                        Text("No incidents found.").font(.system(size: 12)).foregroundStyle(Theme.slate)
                    } else {
                        ForEach(Array(health.evidence.enumerated()), id: \.offset) { _, line in
                            Label(line.sentence(locale: AppFormat.locale), systemImage: "circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.slate)
                        }
                    }
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
            }
        }
    }

    private var prLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 11))
                .foregroundStyle(Theme.violet)
            ForEach(session.prLinks, id: \.url) { link in
                Link(destination: link.url) { Text(verbatim: "#\(link.number) \(link.repository)") }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.violet)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.setSessionStarred(!session.isStarred, sessionId: session.id) }
            } label: {
                Image(systemName: session.isStarred ? "star.fill" : "star")
                    .foregroundStyle(session.isStarred ? Theme.accent : Theme.mist)
            }
            .buttonStyle(.plain)
            .help(session.isStarred ? Text("Remove from Favorites") : Text("Add to Favorites"))
            .accessibilityLabel(session.isStarred ? Text("Remove from Favorites") : Text("Add to Favorites"))

            Button {
                store.resumeSession(session)
            } label: {
                Label("Copy Resume Command", systemImage: "doc.on.clipboard")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.canResume(session) ? Theme.emerald : Theme.mist)
            .disabled(!store.canResume(session))
            .help(store.canResume(session)
                  ? Text("Copy the resume command (cd + claude --resume) to paste into a terminal")
                  : Text("Unknown working folder for this session"))
            .accessibilityLabel("Copy resume command")

            Button {
                Task { await store.revealTranscript(session) }
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mist)
            .help("Show the transcript in Finder")
            .accessibilityLabel("Show the transcript")

            Menu {
                Button("Markdown") { Task { await store.exportSession(session, format: .markdown) } }
                Button("HTML") { Task { await store.exportSession(session, format: .html) } }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("Export the session")
            .accessibilityLabel("Export the session")

            Button {
                copyIdentifier()
            } label: {
                Image(systemName: "number")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mist)
            .help("Copy the session ID")
            .accessibilityLabel("Copy the ID")

            Button {
                findVisible = true
                findFocused = true
            } label: {
                Image(systemName: "text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .foregroundStyle(findVisible ? Theme.accent : Theme.mist)
            .keyboardShortcut("f", modifiers: .command)
            .help("Find in the session (Cmd+F)")
            .accessibilityLabel("Find in the session")

            Button {
                confirmHide = true
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mist)
            .help("Hide this session from the list")
            .accessibilityLabel("Hide the session")
        }
        .font(.system(size: 13))
    }

    private func copyIdentifier() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.id, forType: .string)
        store.notice = String(localized: "ID copied: \(session.id)", locale: AppFormat.locale)
    }

    // MARK: - Find bar

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.slate)
            TextField("Find in Loaded Turns", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($findFocused)
                .onSubmit { step(1) }
            if !findQuery.isEmpty {
                Text(findMatches.isEmpty
                     ? String(localized: "No turns")
                     : String(localized: "\(findIndex + 1) of \(findMatches.count)", locale: AppFormat.locale))
                    .font(.data(11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mist)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(findMatches.isEmpty)
                .help("Previous turn (Cmd+[ or [)")
                .accessibilityLabel("Previous turn")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mist)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(findMatches.isEmpty)
                .help("Next turn (Cmd+] or ])")
                .accessibilityLabel("Next turn")
            Button {
                findVisible = false
                findQuery = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.mist)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close the search")
            bareBracketShortcuts
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    /// Bare `[` / `]` navigation, armed only while the field is not focused so the
    /// two characters stay typable inside the query itself.
    @ViewBuilder
    private var bareBracketShortcuts: some View {
        if !findFocused && !findMatches.isEmpty {
            Group {
                Button("") { step(-1) }.keyboardShortcut("[", modifiers: [])
                Button("") { step(1) }.keyboardShortcut("]", modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func step(_ delta: Int) {
        guard !findMatches.isEmpty else { return }
        findIndex = (findIndex + delta + findMatches.count) % findMatches.count
        scrollTarget = findMatches[findIndex]
    }

    /// The query changed: rebuild the matches and jump to the first one.
    private func recomputeMatches() {
        findMatches = matchingIds()
        findIndex = 0
        scrollTarget = findMatches.first
    }

    /// A page landed: new matches may appear, but the reader is mid-navigation.
    /// The current match is re-found by id so the counter does not jump back to 1.
    private func refreshMatchesKeepingPosition() {
        let current = findMatches.indices.contains(findIndex) ? findMatches[findIndex] : nil
        findMatches = matchingIds()
        if let current, let index = findMatches.firstIndex(of: current) {
            findIndex = index
        } else {
            findIndex = min(findIndex, max(0, findMatches.count - 1))
        }
    }

    private func matchingIds() -> [String] {
        let query = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return renderableMessages
            .filter { message in
                message.blocks.contains {
                    $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
            .map(\.id)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if targetMissing { targetBanner }
                    ForEach(visibleMessages) { message in
                        SessionTurnView(
                            message: message,
                            results: results,
                            elapsed: elapsedById[message.id],
                            depth: 0,
                            highlighted: isMatch(message.id))
                            .id(message.id)
                            .onAppear {
                                guard message.id == prefetchTriggerId else { return }
                                Task { await loadNextPage() }
                            }
                    }
                    pagingFooter
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }

    private func isMatch(_ id: String) -> Bool {
        !findQuery.isEmpty && findMatches.contains(id)
    }

    /// The turn whose appearance asks for the next page. Set a little before the
    /// end so the reader never waits at the bottom; the footer button stays as the
    /// manual fallback when the whole page fits on screen at once.
    ///
    /// Taken from the unfiltered turns: the find filter can shrink the body to two
    /// rows, and paging must still track where the reader is in the transcript.
    private var prefetchTriggerId: String? {
        let shown = renderableMessages
        guard shown.count > 20 else { return shown.last?.id }
        return shown[shown.count - 20].id
    }

    /// Everything the renderer would show, before the find filter.
    private var renderableMessages: [SessionMessage] {
        messages.filter { message in
            if message.role == .system && !showSystemLines { return false }
            if message.isMeta && !showSystemLines { return false }
            return SessionTurnView.isRenderable(message)
        }
    }

    private var visibleMessages: [SessionMessage] {
        guard findVisible, !findQuery.isEmpty else { return renderableMessages }
        let matched = Set(findMatches)
        return renderableMessages.filter { matched.contains($0.id) }
    }

    private var targetBanner: some View {
        SourceBanner(
            kind: .info,
            message: isChasingTarget
                ? String(localized: "Loading the transcript up to the message found…")
                : String(localized: "This result is further into the transcript, past the turns already loaded."),
            action: { Task { await chaseTarget() } },
            actionTitle: String(localized: "Load Up to the Message"))
    }

    @ViewBuilder
    private var pagingFooter: some View {
        VStack(spacing: 8) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading turns…").font(.system(size: 11)).foregroundStyle(Theme.slate)
                }
            } else if !reachedEnd {
                Button("Load More") { Task { await loadNextPage() } }
                    .controlSize(.small)
            }
            if total > 0 {
                // The total now counts the same set the pages return, so the two
                // denominators match and this can honestly say "messages".
                Text("\(String(localized: "\(messages.count) messages", locale: AppFormat.locale)) out of \(AppFormat.integer(total))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Theme.mist)
            } else if messages.isEmpty && !isLoading {
                Text("No messages indexed for this session.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .onAppear {
            // The footer entering the viewport is the signal to page ahead.
            Task { await loadNextPage() }
        }
    }

    // MARK: - Loading

    /// Starts over from the first page — on a session change or a `showSystemLines` toggle.
    ///
    /// A page may still be in flight for the previous filter. Its `isLoading` must not block
    /// the fresh load, and its result must not land in the new list: appended at offset 0
    /// under the old filter, it would make every later offset skip or repeat messages. The
    /// generation bump is what lets `loadNextPage` recognise and drop it.
    private func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let sessionId = session.id
        messages = []
        results = [:]
        elapsedById = [:]
        isLoading = false
        reachedEnd = false
        targetMissing = false
        findMatches = []
        findIndex = 0
        let count = await store.sessionMessageCount(sessionId)
        guard generation == loadGeneration else { return }
        total = count
        await loadNextPage()
        let sessionHealth = await store.sessionHealth(sessionId)
        guard generation == loadGeneration else { return }
        health = sessionHealth
        resolveTarget()
    }

    private func loadNextPage() async {
        guard !isLoading, !reachedEnd else { return }
        let generation = loadGeneration
        isLoading = true
        let page = await store.sessionMessages(session.id, offset: messages.count, limit: Self.pageSize)
        // A `reload` ran meanwhile: it already reset `isLoading` and may own a newer load.
        guard generation == loadGeneration else { return }
        var previous = messages.last?.timestamp
        for message in page {
            if let previous {
                elapsedById[message.id] = message.timestamp.timeIntervalSince(previous)
            }
            previous = message.timestamp
            for block in message.blocks where block.kind == .toolResult {
                if let toolUseId = block.toolUseId { results[toolUseId] = block }
            }
        }
        messages.append(contentsOf: page)
        reachedEnd = page.count < Self.pageSize || (total > 0 && messages.count >= total)
        isLoading = false
        if !findQuery.isEmpty { refreshMatchesKeepingPosition() }
        resolveTarget()
    }

    /// Scrolls to the message the browser asked for, or says it is not loaded yet.
    ///
    /// Paging from zero on every search hit of a very long session would be wasteful, so
    /// the jump stays behind an explicit button; `chaseTarget` then uses the index to stop
    /// as soon as the message is in.
    private func resolveTarget() {
        guard let target = targetMessageId else {
            targetMissing = false
            return
        }
        if messages.contains(where: { $0.id == target }) {
            targetMissing = false
            scrollTarget = target
            targetMessageId = nil
        } else {
            targetMissing = !reachedEnd
            if reachedEnd { targetMessageId = nil }
        }
    }

    /// Pages forward until the requested message is loaded.
    ///
    /// Two things keep this from spinning. It asks the index where the message sits, so it
    /// stops as soon as enough pages are in rather than trusting `contains` alone. And it
    /// breaks when a pass loaded nothing: `loadNextPage` returns immediately while another
    /// load is in flight, and without that check the loop would keep re-entering it on the
    /// main actor, doing no work and freezing the window.
    private func chaseTarget() async {
        guard let target = targetMessageId, !isChasingTarget else { return }
        isChasingTarget = true
        defer { isChasingTarget = false }
        let targetIndex = await store.sessionMessageIndex(session.id, messageId: target)
        while !reachedEnd, !messages.contains(where: { $0.id == target }) {
            if let targetIndex, messages.count > targetIndex { break }
            let loadedBefore = messages.count
            await loadNextPage()
            guard messages.count > loadedBefore else { break }
        }
        resolveTarget()
    }
}
