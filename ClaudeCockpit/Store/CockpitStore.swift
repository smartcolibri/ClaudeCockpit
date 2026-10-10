import AppKit
import Foundation
import Observation
import ServiceManagement
import CockpitShared
import UsageKit
import RTKKit
import SkillsKit
import SessionsKit

/// Lifecycle of one data source. Every source is independent: a failure shows
/// in its own section and never blocks the others.
enum SourceState: Equatable {
    case idle
    case loading
    case ready(Date)
    case failed(String)
    /// The sandbox grants do not cover what this source reads. Not an error: the
    /// views offer the grant flow instead of a retry.
    case unauthorized

    var isLoading: Bool { self == .loading }
    var isUnauthorized: Bool { self == .unauthorized }
    var errorMessage: String? { if case .failed(let m) = self { return m } else { return nil } }
    var lastSuccess: Date? { if case .ready(let d) = self { return d } else { return nil } }
}

/// Sidebar sections of the main window.
enum CockpitSection: String, CaseIterable, Identifiable {
    case overview, usage, sessions, rtk, skills, agents, commands, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Vue d'ensemble"
        case .usage: "Usage local"
        case .sessions: "Sessions"
        case .rtk: "RTK"
        case .skills: "Skills"
        case .agents: "Agents"
        case .commands: "Commandes"
        case .settings: "Réglages"
        }
    }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .usage: "chart.bar.xaxis"
        case .sessions: "text.bubble.fill"
        case .rtk: "leaf.fill"
        case .skills: "sparkles"
        case .agents: "person.2.fill"
        case .commands: "terminal.fill"
        case .settings: "gearshape.fill"
        }
    }
    var resourceKind: ResourceKind? {
        switch self {
        case .skills: .skill
        case .agents: .agent
        case .commands: .command
        default: nil
        }
    }
}

/// The hub: owns the four services, one snapshot + state per source, the
/// refresh loops and the user-facing actions. Everything UI-visible is on the
/// main actor; the work happens in the services (actors / background).
@MainActor @Observable
final class CockpitStore {
    // MARK: Services
    /// Rebuilt when the Claude config directory setting changes.
    private(set) var paths: ClaudePaths
    /// Folders granted to the sandboxed app; every source checks it before reading.
    let access: AccessStore
    private var usageService: UsageService
    private var rtkService: RTKService
    private(set) var sessionService: SessionService
    private var skillsStore: ResourceStore
    private let defaults = UserDefaults.standard

    // MARK: Snapshots & states
    private(set) var usage: UsageSnapshot?
    private(set) var usageState: SourceState = .idle
    private(set) var usageLastScan: Date?

    private(set) var rtk: RTKSnapshot?
    private(set) var rtkState: SourceState = .idle

    private(set) var skills: SkillsInventory?
    private(set) var skillsState: SourceState = .idle

    /// Sessions are not a snapshot like the other sources: the archive is far too
    /// large to hold in memory, so the store keeps only the current page of the
    /// list plus the indexing progress, and the views query the service directly.
    /// Written only by the sessions extension in `SessionsStore.swift`; `private(set)`
    /// cannot express that, being file-scoped, so these stay plainly internal.
    var sessions: [SessionRef] = []
    var sessionsState: SourceState = .idle
    var sessionIndex: IndexProgress = .idle
    var sessionFilter = SessionFilter() {
        didSet {
            guard sessionFilter != oldValue else { return }
            sessionListTask?.cancel()
            sessionListTask = Task { [weak self] in await self?.refreshSessionList() }
        }
    }
    /// True when the last listing filled its page exactly, so more sessions exist than the
    /// list is showing. The view says so instead of pretending the archive ends there.
    var sessionsTruncated = false
    private var sessionListTask: Task<Void, Never>?
    private var sessionsWatcher: RecursiveWatcher?
    private var sessionsWatchTask: Task<Void, Never>?
    /// A targeted pass never prunes: only a complete walk can tell a deleted
    /// transcript from one the watcher simply did not name. This bounds how
    /// long a deleted session can linger in the list.
    var lastFullSessionWalk: Date = .distantPast

    /// Last user-visible notice (toast) from a skills action.
    var notice: String?

    // MARK: Usage filters & pricing
    var usageFilters = UsageFilters(range: .last30Days) {
        didSet { Task { await recomputeUsage() } }
    }
    var pricing: PricingSettings {
        didSet {
            defaults.set(pricing.jsonString, forKey: SettingsKey.pricingJSON)
            Task { await recomputeUsage() }
        }
    }

    // MARK: Derived
    /// Menu-bar label: today's estimated cost, formatted like the overview's
    /// "Coût du jour" tile. A dash stands for "not read yet" and is never
    /// rendered as a zero amount.
    var menuBarTitle: String {
        usage.map { money($0.costTodayUSD) } ?? "–"
    }
    var currency: String { defaults.string(forKey: SettingsKey.currency) ?? "USD" }
    /// Converts a USD amount to the display currency.
    func money(_ usd: Double, digits: Int = 2) -> String {
        if currency == "EUR" {
            let rate = defaults.double(forKey: SettingsKey.eurRate)
            return FRFormat.money(usd * (rate > 0 ? rate : 0.92), currency: "EUR", digits: digits)
        }
        return FRFormat.money(usd, currency: "USD", digits: digits)
    }

    // MARK: Init
    init() {
        SettingsKey.registerDefaults()
        let paths = ClaudePaths.live(configDirSetting: UserDefaults.standard.string(forKey: SettingsKey.claudeConfigDir))
        self.paths = paths
        access = AccessStore()
        usageService = UsageService(paths: paths)
        rtkService = RTKService(paths: paths, overridePath: Self.rtkOverride(paths: paths))
        sessionService = SessionService(paths: paths)
        skillsStore = ResourceStore(paths: paths)
        pricing = UserDefaults.standard.string(forKey: SettingsKey.pricingJSON)
            .map(PricingSettings.decoded(fromJSONString:)) ?? .default
        access.onChange = { [weak self] in self?.accessDidChange() }
    }

    private static func rtkOverride(paths: ClaudePaths) -> URL? {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.rtkDBPath) ?? ""
        return raw.isEmpty ? nil : URL(fileURLWithPath: paths.expandTilde(raw))
    }

    // MARK: Access

    /// `~/.claude` (or the configured directory) is readable: usage, sessions, skills.
    var claudeAccess: Bool { access.covers(paths.claudeDir) }
    /// The whole home is readable: skills linked outside `~/.claude` resolve.
    var homeAccess: Bool { access.covers(paths.home) }
    /// rtk's database can be read: the chosen one, or any automatic candidate.
    var rtkAccess: Bool {
        if let override = Self.rtkOverride(paths: paths) {
            return access.covers(override.deletingLastPathComponent()) || access.covers(override)
        }
        return paths.rtkDatabaseCandidates.contains { access.covers($0.deletingLastPathComponent()) }
    }
    func isCovered(_ url: URL) -> Bool { access.covers(url) }

    /// Result of a grant request, for the onboarding and the settings to word.
    enum AccessRequestResult: Equatable {
        case cancelled
        case granted(full: Bool)
        case rejected(String)
    }

    enum AccessTarget { case home, claudeOnly }

    /// Runs the open panel for the recommended (home) or minimal (`~/.claude`) grant,
    /// checks the selection and stores it. Everything reloads through `accessDidChange`.
    @discardableResult
    func requestAccess(_ target: AccessTarget) -> AccessRequestResult {
        let expected = target == .home ? paths.home : paths.claudeDir
        let message = target == .home
            ? "Sélectionnez votre dossier personnel « \(paths.home.lastPathComponent) » puis cliquez sur Autoriser."
            : "Sélectionnez le dossier \(displayPath(paths.claudeDir)) puis cliquez sur Autoriser."
        // The home folder is the panel's start either way: `.claude` is visible in it
        // (hidden files are shown) and a click on Autoriser picks the home itself.
        guard let url = access.runPanel(directory: target == .home ? paths.home : paths.claudeDir, message: message) else {
            return .cancelled
        }
        let result: AccessRequestResult
        switch AccessCoverage.evaluate(selection: url, expected: expected, required: paths.claudeDir) {
        case .unrelated:
            result = .rejected("Le dossier choisi (\(displayPath(url))) ne contient pas \(displayPath(paths.claudeDir)). Aucun accès n'a été enregistré.")
        case .partial, .full:
            do {
                try access.add(url)
                result = .granted(full: access.covers(paths.home))
            } catch {
                result = .rejected("Impossible d'enregistrer l'accès : \(error.localizedDescription)")
            }
        }
        if case .rejected(let text) = result { notice = text }
        return result
    }

    /// Grants any folder (or file) the user picks, starting the panel at `directory`.
    @discardableResult
    func grantFolder(startingAt directory: URL, message: String, chooseFiles: Bool = false) -> URL? {
        guard let url = access.runPanel(directory: directory, message: message, chooseFiles: chooseFiles) else { return nil }
        grant(url)
        return url
    }

    /// Stores a grant for a URL just picked in an open panel; a failure becomes a notice.
    func grant(_ url: URL) {
        do {
            try access.add(url)
        } catch {
            notice = "Impossible d'enregistrer l'accès : \(error.localizedDescription)"
        }
    }

    /// `~/…` form of a path under the real home.
    func displayPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        let home = paths.home.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Reloads every source after a grant changed or the config directory moved. Paths are
    /// rebuilt only when they differ; watchers restart only on what is now covered.
    func accessDidChange() {
        let fresh = ClaudePaths.live(configDirSetting: defaults.string(forKey: SettingsKey.claudeConfigDir))
        if fresh != paths {
            sessionsWatchTask?.cancel()
            sessionsWatcher?.stop()
            paths = fresh
            usageService = UsageService(paths: fresh)
            sessionService = SessionService(paths: fresh)
            skillsStore = ResourceStore(paths: fresh)
            sessions = []
        }
        usage = nil
        skills = nil
        guard loopsStarted else { return }
        Task { await refreshUsage() }
        startSessionsWatch()
        startSkillsWatch()
        rtkPathDidChange()
    }

    // MARK: Loops
    private var loopsStarted = false
    private var loopTasks: [Task<Void, Never>] = []

    /// Starts the independent refresh loops once. Safe to call several times.
    func start() {
        guard !loopsStarted else { return }
        loopsStarted = true

        // Housekeeping: drop skill backups older than 30 days (off the main thread).
        // Only where it may write: the pruner deletes inside `~/.claude/backups`.
        if claudeAccess {
            let paths = paths
            Task.detached(priority: .background) { BackupPruner.prune(paths: paths) }
        }

        loopTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshUsage()
                let seconds = max(10, UserDefaults.standard.integer(forKey: SettingsKey.usageRefreshSeconds))
                try? await Task.sleep(for: .seconds(seconds))
            }
        })
        startRTKWatch()
        loopTasks.append(Task { [weak self] in
            // Fallback poll for rtk in case the watcher stream ended (no DB at launch); a refresh
            // that finds the database re-arms the live watch.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refreshRTK()
            }
        })
        startSessionsWatch()
        startSkillsWatch()
    }
    private var skillsWatcher: DirectoryWatcher?
    private var skillsWatchTask: Task<Void, Never>?

    /// Inventories the skills, then follows their directories. Restartable: a new grant
    /// (or a moved config directory) re-arms it; no watcher is started without access.
    private func startSkillsWatch() {
        skillsWatchTask?.cancel()
        skillsWatchTask = nil
        skillsWatcher = nil
        skillsWatchTask = Task { [weak self] in
            await self?.refreshSkills()
            guard let self, !Task.isCancelled, self.claudeAccess else { return }
            let paths = self.paths
            let watcher = DirectoryWatcher(directories: [
                paths.skillsDir, paths.agentsDir, paths.commandsDir,
                paths.libraryDir.appendingPathComponent("skills"),
                paths.libraryDir.appendingPathComponent("agents"),
                paths.libraryDir.appendingPathComponent("commands"),
            ])
            self.skillsWatcher = watcher
            for await _ in watcher.changes {
                if Task.isCancelled { return }
                await self.refreshSkills()
            }
        }
    }

    /// The task consuming `rtkService.changes`, kept apart from `loopTasks` because it is
    /// bound to one `RTKService` instance: when the user changes the database path a new
    /// service replaces it and this task has to be cancelled and restarted, or nobody
    /// subscribes to the new service's stream.
    private var rtkWatchTask: Task<Void, Never>?
    /// Set when the stream ended on its own — rtk had no database yet, so the service
    /// handed back a finished stream. The next refresh that finds the database re-arms the
    /// watch; without it, installing rtk after launch meant no live updates until relaunch.
    private var rtkWatchEnded = false

    private func startRTKWatch() {
        rtkWatchTask?.cancel()
        rtkWatchEnded = false
        guard rtkAccess else {
            // Nothing to watch without a grant; the next refresh after one re-arms it.
            rtkWatchEnded = true
            Task { await refreshRTK() }
            return
        }
        // Captured now, so the loop can never end up awaiting a stream from a service the
        // store has since replaced.
        let service = rtkService
        rtkWatchTask = Task { [weak self] in
            await self?.refreshRTK()
            for await _ in service.changes {
                if Task.isCancelled { return }
                await self?.refreshRTK()
            }
            if !Task.isCancelled { self?.rtkWatchEnded = true }
        }
    }

    /// Indexes once, then follows the archive. Restartable on purpose: the user can turn
    /// indexing off and on from the settings, and the previous version armed the watcher
    /// only at launch, so re-enabling the section did nothing until the next relaunch.
    func startSessionsWatch() {
        sessionsWatchTask?.cancel()
        sessionsWatchTask = nil
        sessionsWatcher?.stop()
        sessionsWatcher = nil
        guard defaults.bool(forKey: SettingsKey.sessionsIndexEnabled) else { return }
        guard claudeAccess else {
            sessions = []
            sessionsState = .unauthorized
            return
        }
        sessionsWatchTask = Task { [weak self] in
            // The first index walks ~900 MB, so it starts right away and reports its
            // progress; everything after it is driven by the watcher. That is why the
            // sessions source owns no periodic timer and cannot collide with the usage
            // scan on a shared tick.
            await self?.indexSessions(full: false)
            guard let self, !Task.isCancelled else { return }
            let watcher = RecursiveWatcher(
                roots: [self.paths.projectsDir],
                filter: { $0.hasSuffix(".jsonl") },
                debounce: 1.0,
                pollingInterval: 600)
            self.sessionsWatcher = watcher
            watcher.start()
            for await changed in watcher.changes {
                if Task.isCancelled { return }
                await self.indexSessions(changedPaths: changed)
            }
        }
    }

    /// Called by the settings toggle so enabling indexing takes effect immediately.
    func sessionsIndexingDidChange() { startSessionsWatch() }

    func refreshAll() async {
        async let a: Void = refreshUsage()
        async let b: Void = refreshRTK()
        async let c: Void = refreshSkills()
        _ = await (a, b, c)
    }

    // MARK: Usage
    func refreshUsage(rescan: Bool = false) async {
        guard claudeAccess else {
            usage = nil
            usageState = .unauthorized
            return
        }
        if usage == nil { usageState = .loading }
        do {
            if rescan { try await usageService.rescan() } else { try await usageService.refresh() }
            await recomputeUsage()
            usageLastScan = Date()
            usageState = .ready(Date())
        } catch {
            usageState = .failed(error.localizedDescription)
        }
    }

    private func recomputeUsage() async {
        let filters = usageFilters
        let pricing = pricing
        let snapshot = await usageService.snapshot(filters: filters, pricing: pricing, now: Date())
        self.usage = snapshot
    }

    // MARK: RTK
    func refreshRTK() async {
        guard rtkAccess else {
            rtk = nil
            rtkState = .unauthorized
            return
        }
        if rtk == nil { rtkState = .loading }
        let service = rtkService
        do {
            let snapshot = try await Task.detached(priority: .utility) { try service.snapshot() }.value
            rtk = snapshot
            rtkState = .ready(snapshot.generatedAt)
            if rtkWatchEnded { startRTKWatch() }
        } catch {
            rtkState = .failed(error.localizedDescription)
        }
    }

    /// Re-resolves the rtk database after the user changed the path setting.
    func rtkPathDidChange() {
        // Cancel before stopping the old service: `stop()` finishes its stream, and the
        // loop must not race a refresh against the service it is about to lose.
        rtkWatchTask?.cancel()
        rtkWatchTask = nil
        rtkService.stop()
        rtkService = RTKService(paths: paths, overridePath: Self.rtkOverride(paths: paths))
        rtk = nil
        // Refreshes once and re-subscribes, this time to the new service.
        startRTKWatch()
    }
    var rtkDatabaseURL: URL? { rtkService.databaseURL }

    // MARK: Skills
    var projectRoots: [URL] {
        let raw = defaults.string(forKey: SettingsKey.projectRoots) ?? ""
        let lines = raw.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.isEmpty { return paths.defaultProjectRoots }
        return lines.map { URL(fileURLWithPath: paths.expandTilde($0), isDirectory: true) }
    }
    /// Roots the sandbox grants do not cover: skipped by the scan, listed in Réglages.
    var inaccessibleProjectRoots: [URL] { projectRoots.filter { !access.covers($0) } }

    private static let projectsCacheKey = "cache.projects"

    /// Projects found by the last scan, persisted so the first inventory after
    /// launch does not wait for a directory walk.
    private var cachedProjects: [ProjectRef] {
        get {
            guard let data = defaults.data(forKey: Self.projectsCacheKey),
                  let list = try? JSONDecoder().decode([ProjectRef].self, from: data) else { return [] }
            return list.filter { FileManager.default.fileExists(atPath: $0.claudeDir.path) }
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.projectsCacheKey) }
    }

    func refreshSkills() async {
        guard claudeAccess else {
            skills = nil
            skillsState = .unauthorized
            return
        }
        if skills == nil { skillsState = .loading }
        do {
            // 1. Fast path: inventory with the cached project list.
            if skills == nil {
                let cached = cachedProjects
                if !cached.isEmpty {
                    let quick = try await skillsStore.inventory(projects: cached)
                    skills = quick
                    skillsState = .ready(quick.generatedAt)
                }
            }
            // 2. Full path: rescan roots (bounded walk) then rebuild the inventory.
            let roots = projectRoots.filter { access.covers($0) }
            let projects = await Task.detached(priority: .utility) { ProjectScanner().scan(roots: roots) }.value
            cachedProjects = projects
            let inventory = try await skillsStore.inventory(projects: projects)
            skills = inventory
            skillsState = .ready(inventory.generatedAt)
        } catch {
            skillsState = .failed(error.localizedDescription)
        }
    }

    func read(_ resource: ClaudeResource) async throws -> String { try await skillsStore.read(resource) }
    func read(_ plugin: PluginResource) async throws -> String { try await skillsStore.read(plugin) }

    @discardableResult
    func transfer(_ resource: ClaudeResource, to level: ResourceLevel, mode: TransferMode, overwrite: Bool = false) async throws -> ClaudeResource {
        let result = try await skillsStore.transfer(resource, to: level, mode: mode, overwrite: overwrite)
        notice = "\(mode == .copy ? "Copié" : "Déplacé") « \(resource.name) » vers \(level.label)"
        await refreshSkills()
        return result
    }

    @discardableResult
    func importPlugin(_ plugin: PluginResource, to level: ResourceLevel, overwrite: Bool = false) async throws -> ClaudeResource {
        let result = try await skillsStore.importPlugin(plugin, to: level, overwrite: overwrite)
        notice = "Importé « \(plugin.name) » vers \(level.label)"
        await refreshSkills()
        return result
    }

    @discardableResult
    func delete(_ resource: ClaudeResource) async throws -> URL {
        let backup = try await skillsStore.delete(resource)
        notice = "Supprimé « \(resource.name) » (sauvegarde : \(backup.path))"
        await refreshSkills()
        return backup
    }

    func reveal(_ resource: ClaudeResource) {
        NSWorkspace.shared.activateFileViewerSelecting([skillsStore.revealURL(for: resource)])
    }
    func reveal(_ plugin: PluginResource) {
        NSWorkspace.shared.activateFileViewerSelecting([skillsStore.revealURL(for: plugin)])
    }

    // MARK: System integration
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    func setMenuBarOnly(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKey.menuBarOnly)
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if !enabled { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Opens (or focuses) the main window and brings the app forward.
    func openMainWindow() {
        if NSApp.activationPolicy() == .accessory {
            // Menu-bar-only mode: the window still needs a reachable app to show up.
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let handler = openWindowHandler {
            handler()
        } else if let window = NSApp.windows.first(where: { $0.title == MainWindowView.windowTitle }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
    /// Injected by the App scene (SwiftUI `openWindow` action).
    var openWindowHandler: (() -> Void)?
}
