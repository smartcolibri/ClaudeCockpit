import AppKit
import Foundation
import Observation
import CockpitShared

/// The folders the user granted to the sandboxed app, kept as app-scope
/// security-scoped bookmarks.
///
/// Each bookmark is resolved once at launch and its scope stays open for the life
/// of the process: the watchers on `~/.claude/projects` and rtk's database are
/// long-lived, and stopping access between reads would cut them off. A stale
/// bookmark is recreated while its scope is open; one that no longer resolves is
/// kept, flagged, so the user sees it in Settings › Access instead of losing it.
///
/// Outside the sandbox (unsigned Debug builds) every path counts as covered and
/// grants are not needed.
@MainActor @Observable
final class AccessStore {
    struct Grant: Identifiable, Equatable {
        enum Status: Equatable {
            case active
            /// Resolved, but the bookmark had gone stale and was recreated.
            case renewed
            /// The bookmark no longer resolves (folder moved or deleted).
            case broken(String)
            /// Resolved, but macOS refused to open its security scope: nothing under it
            /// can be read, so it covers nothing until the user grants it again.
            case denied
        }
        /// The path the user picked, as stored. Also the identity.
        let path: String
        var id: String { path }
        var status: Status
        var isUsable: Bool {
            switch status {
            case .active, .renewed: true
            case .broken, .denied: false
            }
        }
    }

    private struct Stored: Codable {
        var path: String
        var bookmark: Data
    }

    private static let defaultsKey = "access.bookmarks"

    let isSandboxed: Bool
    private(set) var grants: [Grant] = []
    /// Called after any grant is added or removed, so the store can reload its sources.
    var onChange: (() -> Void)?

    private var stored: [Stored] = []
    /// URLs whose security scope is open, keyed by stored path.
    private var openScopes: [String: URL] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, sandboxed: Bool = AccessCoverage.isSandboxed) {
        self.defaults = defaults
        self.isSandboxed = sandboxed
        if let data = defaults.data(forKey: Self.defaultsKey),
           let list = try? JSONDecoder().decode([Stored].self, from: data) {
            stored = list
        }
        grants = stored.map { resolve($0) }
        persist()
    }

    // MARK: Coverage

    /// Paths of the grants that currently resolve.
    var grantedPaths: [String] { grants.filter(\.isUsable).map(\.path) }

    func covers(_ url: URL) -> Bool {
        AccessCoverage.isCovered(url, grantedPaths: grantedPaths, sandboxed: isSandboxed)
    }

    // MARK: Mutations

    /// Stores a bookmark for a URL the user just picked in an open panel (the
    /// panel is what makes it accessible) and opens its scope for good.
    @discardableResult
    func add(_ url: URL) throws -> Grant {
        let path = AccessCoverage.normalized(url.path)
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        closeScope(path)
        stored.removeAll { $0.path == path }
        let entry = Stored(path: path, bookmark: bookmark)
        stored.append(entry)
        let grant = resolve(entry)
        grants.removeAll { $0.path == path }
        grants.append(grant)
        persist()
        onChange?()
        return grant
    }

    /// Swaps `grant` for a newly picked URL in one step, so the sources reload once.
    func replace(_ grant: Grant, with url: URL) throws {
        let path = AccessCoverage.normalized(url.path)
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        closeScope(grant.path)
        closeScope(path)
        stored.removeAll { $0.path == grant.path || $0.path == path }
        grants.removeAll { $0.path == grant.path || $0.path == path }
        let entry = Stored(path: path, bookmark: bookmark)
        stored.append(entry)
        grants.append(resolve(entry))
        persist()
        onChange?()
    }

    func remove(_ grant: Grant) {
        closeScope(grant.path)
        stored.removeAll { $0.path == grant.path }
        grants.removeAll { $0.path == grant.path }
        persist()
        onChange?()
    }

    // MARK: Panel

    /// Shows the open panel on `directory` and grants what the user picks.
    /// Returns the picked URL, or nil when the panel was cancelled.
    func runPanel(
        directory: URL,
        message: String,
        prompt: String = String(localized: "Allow"),
        chooseFiles: Bool = false
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = chooseFiles
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = directory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: Private

    private func resolve(_ entry: Stored) -> Grant {
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            return Grant(path: entry.path, status: .broken(error.localizedDescription))
        }
        // A bookmark follows a moved folder: coverage must use where it is now.
        let path = AccessCoverage.normalized(url.path)
        let index = stored.firstIndex(where: { $0.path == entry.path })
        if let index { stored[index].path = path }
        // Outside the sandbox `startAccessing…` returns false and nothing is needed; inside
        // it, false means the scope stayed closed and the grant gives no access at all.
        if url.startAccessingSecurityScopedResource() {
            openScopes[path] = url
        } else if isSandboxed {
            return Grant(path: path, status: .denied)
        }
        guard stale else { return Grant(path: path, status: .active) }
        // Recreated while the scope is open, as the API requires.
        if let fresh = try? url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil),
           let index {
            stored[index].bookmark = fresh
        }
        return Grant(path: path, status: .renewed)
    }

    private func closeScope(_ path: String) {
        openScopes.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
