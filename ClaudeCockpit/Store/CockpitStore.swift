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

    var isLoading: Bool { self == .loading }
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
    let paths: ClaudePaths
    private let usageService: UsageService
    private var rtkService: RTKService
    let sessionService: SessionService
    private let skillsStore: ResourceStore
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
    init(paths: ClaudePaths = .live) {
        SettingsKey.registerDefaults()
        self.paths = paths
        usageService = UsageService(paths: paths)
        let override = UserDefaults.standard.string(forKey: SettingsKey.rtkDBPath).flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        rtkService = RTKService(paths: paths, overridePath: override)
        sessionService = SessionService(paths: paths)
        skillsStore = ResourceStore(paths: paths)
        pricing = UserDefaults.standard.string(forKey: SettingsKey.pricingJSON)
            .map(PricingSettings.decoded(fromJSONString:)) ?? .default
    }

    // MARK: Loops
    private var loopsStarted = false
    private var loopTasks: [Task<Void, Never>] = []

    /// Starts the independent refresh loops once. Safe to call several times.
    func start() {
        guard !loopsStarted else { return }
        loopsStarted = true

        // Housekeeping: drop skill backups older than 30 days (off the main thread).
        let paths = paths
        Task.detached(priority: .background) { BackupPruner.prune(paths: paths) }

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
        loopTasks.append(Task { [weak self] in
            await self?.refreshSkills()
            guard let self else { return }
            let watcher = DirectoryWatcher(directories: [
                paths.skillsDir, paths.agentsDir, paths.commandsDir,
                paths.libraryDir.appendingPathComponent("skills"),
                paths.libraryDir.appendingPathComponent("agents"),
                paths.libraryDir.appendingPathComponent("commands"),
            ])
            self.skillsWatcher = watcher
            for await _ in watcher.changes {
                await self.refreshSkills()
            }
        })
    }
    private var skillsWatcher: DirectoryWatcher?

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
        let raw = defaults.string(forKey: SettingsKey.rtkDBPath) ?? ""
        let override = raw.isEmpty ? nil : URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        rtkService = RTKService(paths: paths, overridePath: override)
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
        return lines.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

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
            let roots = projectRoots
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
