import Foundation
import CockpitShared

public enum UsageServiceError: Error, LocalizedError, Sendable {
    /// `~/.claude/projects` does not exist — Claude Code has never run for this user.
    case projectsDirectoryMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .projectsDirectoryMissing(let url):
            String(localized: "No Claude Code transcripts: the folder \(url.path) was not found.", bundle: .module)
        }
    }
}

/// The usage domain's entry point: owns the incremental scanner and the last scan's results.
/// Aggregation stays a pure function (`UsageAggregator.snapshot`), so the app can recompute a
/// snapshot on a filter change without rescanning any file.
public actor UsageService {
    public let paths: ClaudePaths
    private let scanner: TranscriptScanner

    /// Every event known after the last successful `refresh()`.
    public private(set) var lastEvents: [UsageEvent] = []
    /// Session titles/slugs/cwds collected alongside those events.
    public private(set) var lastSessionInfo: [String: SessionInfo] = [:]
    /// When the last successful `refresh()` completed.
    public private(set) var lastRefreshedAt: Date?

    /// The overview ignores the filters, so a filter change must not recompute it: it is kept
    /// until a refresh, a pricing change or a new day.
    private struct OverviewKey: Equatable {
        let refreshedAt: Date?
        let eventCount: Int
        let pricing: PricingSettings
        let day: Date
    }
    private var overviewCache: (key: OverviewKey, value: UsageOverview)?
    /// How many times the overview was computed — for tests.
    private(set) var overviewComputations = 0

    public init(paths: ClaudePaths = .live) {
        self.paths = paths
        self.scanner = TranscriptScanner(paths: paths)
    }

    /// Reads whatever was appended since the previous call and returns every known event.
    @discardableResult
    public func refresh() async throws -> [UsageEvent] {
        guard FileManager.default.fileExists(atPath: paths.projectsDir.path) else {
            throw UsageServiceError.projectsDirectoryMissing(paths.projectsDir)
        }
        let result = await scanner.scan()
        lastEvents = result.events
        lastSessionInfo = result.sessionInfo
        lastRefreshedAt = Date()
        return result.events
    }

    /// Writes the scanner's caches to disk right away, ignoring their throttles. Worth
    /// calling when the app is going away; skipping it only costs a partial re-read on the
    /// next launch, since each cache entry records the offset it covers.
    public func flush() async {
        await scanner.flush()
    }

    /// Drops every cached offset and re-reads all transcripts from byte zero.
    @discardableResult
    public func rescan() async throws -> [UsageEvent] {
        await scanner.reset()
        return try await refresh()
    }

    /// Aggregates the last scan's events. Cheap enough to call on every filter change.
    public func snapshot(
        filters: UsageFilters = UsageFilters(),
        pricing: PricingSettings = .default,
        now: Date = Date()
    ) -> UsageSnapshot {
        let key = OverviewKey(
            refreshedAt: lastRefreshedAt, eventCount: lastEvents.count, pricing: pricing,
            day: Calendar.current.startOfDay(for: now))
        let overview: UsageOverview
        if let cached = overviewCache, cached.key == key {
            overview = cached.value
        } else {
            overview = UsageAggregator.overview(events: lastEvents, pricing: pricing, now: now, home: paths.home)
            overviewComputations += 1
            overviewCache = (key, overview)
        }
        return UsageAggregator.snapshot(
            events: lastEvents,
            sessionInfo: lastSessionInfo,
            filters: filters,
            pricing: pricing,
            now: now,
            home: paths.home,
            overview: overview)
    }
}
