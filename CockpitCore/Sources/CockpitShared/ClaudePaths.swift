import Foundation

/// Well-known locations used by every module. Paths are computed from `home`
/// so tests can point the whole app at a temporary directory.
///
/// Under the App Sandbox, `FileManager.homeDirectoryForCurrentUser`,
/// `NSHomeDirectory()` and `expandingTildeInPath` all answer the app's
/// container (`~/Library/Containers/<id>/Data`). Claude Code's data lives in the
/// user's real home, so `live` reads it from the password database instead, while
/// the app's own files (`appSupportDir`) stay in the container, the one place the
/// sandbox lets it write without a grant.
public struct ClaudePaths: Sendable, Equatable {
    public let home: URL
    /// Explicit Claude config directory (honours `CLAUDE_CONFIG_DIR`); nil → `~/.claude`.
    public let configDirOverride: URL?
    /// Explicit app-data directory; nil → derived from `home` (what tests rely on).
    public let appSupportOverride: URL?

    public init(home: URL = ClaudePaths.realHome, configDir: URL? = nil, appSupport: URL? = nil) {
        self.home = home
        self.configDirOverride = configDir
        self.appSupportOverride = appSupport
    }

    /// The user's real home directory, sandboxed or not: `getpwuid(getuid())`.
    public static let realHome: URL = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// Where the app keeps its own data: the user-domain Application Support of this
    /// process, which is the container's when sandboxed, plus the app folder.
    public static var processAppSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? realHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("ClaudeCockpit", isDirectory: true)
    }

    /// Real home, with the Claude config directory resolved from the app setting, then
    /// `CLAUDE_CONFIG_DIR`, then `~/.claude`; app data in this process's Application Support.
    public static var live: ClaudePaths { live(configDirSetting: nil) }

    /// - Parameter configDirSetting: the "Dossier de configuration Claude" setting. An app
    ///   launched from the Finder never sees the shell's `CLAUDE_CONFIG_DIR`, so the setting
    ///   exists to say it explicitly; it wins over the variable when both are present.
    public static func live(
        configDirSetting: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudePaths {
        ClaudePaths(
            home: realHome,
            configDir: resolveConfigDir(setting: configDirSetting, environment: environment, home: realHome),
            appSupport: processAppSupportDir)
    }

    /// The demo mode's world, all under `root` (see `DemoSeeder`): a fictional home holding
    /// `.claude`, rtk's database and the project roots, and app data kept apart from the
    /// real index so nothing the demo does reaches the user's own state.
    public static func demo(root: URL) -> ClaudePaths {
        let home = root.appendingPathComponent("home", isDirectory: true)
        return ClaudePaths(
            home: home,
            configDir: home.appendingPathComponent(".claude", isDirectory: true),
            appSupport: root.appendingPathComponent("appdata", isDirectory: true))
    }

    /// Setting first, then `CLAUDE_CONFIG_DIR`, `~` expanded against `home`; nil when neither is set.
    /// A relative value is skipped: it would resolve against whatever the working directory is.
    public static func resolveConfigDir(setting: String?, environment: [String: String], home: URL) -> URL? {
        for raw in [setting, environment["CLAUDE_CONFIG_DIR"]] {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty, isUsableConfigDirSetting(trimmed) {
                return URL(fileURLWithPath: expandTilde(trimmed, home: home), isDirectory: true)
            }
        }
        return nil
    }

    /// Whether a config-directory value can be used: empty (no override), absolute, or a
    /// `~` / `~/…` form.
    public static func isUsableConfigDirSetting(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("/")
    }

    /// `~` and `~/…` expanded against `home` (the real one by default). Unlike
    /// `NSString.expandingTildeInPath`, this never lands in the sandbox container.
    /// `~user` forms are left alone.
    public static func expandTilde(_ path: String, home: URL = ClaudePaths.realHome) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
        return path
    }

    /// `expandTilde` against this instance's home.
    public func expandTilde(_ path: String) -> String { Self.expandTilde(path, home: home) }

    /// `~/.claude` (or `CLAUDE_CONFIG_DIR`)
    public var claudeDir: URL { configDirOverride ?? home.appendingPathComponent(".claude", isDirectory: true) }
    /// `~/.claude/projects` — Claude Code transcripts (`<encoded cwd>/<session>.jsonl`).
    public var projectsDir: URL { claudeDir.appendingPathComponent("projects", isDirectory: true) }
    /// `~/.claude/.credentials.json` — fallback for the OAuth token.
    public var credentialsFile: URL { claudeDir.appendingPathComponent(".credentials.json") }
    public var skillsDir: URL { claudeDir.appendingPathComponent("skills", isDirectory: true) }
    public var agentsDir: URL { claudeDir.appendingPathComponent("agents", isDirectory: true) }
    public var commandsDir: URL { claudeDir.appendingPathComponent("commands", isDirectory: true) }
    /// Inactive resources, shared with SkillManager: `~/.claude/skillmanager/library`.
    public var libraryDir: URL { claudeDir.appendingPathComponent("skillmanager/library", isDirectory: true) }
    /// `~/.claude/plugins/cache/<org>/<plugin>/<version>/…`
    public var pluginsCacheDir: URL { claudeDir.appendingPathComponent("plugins/cache", isDirectory: true) }
    /// Backups written before any SkillsKit mutation.
    public var backupsDir: URL { claudeDir.appendingPathComponent("backups", isDirectory: true) }
    /// The app's own data (session index, scan caches). `appSupport` when given, else
    /// `~/Library/Application Support/ClaudeCockpit` under `home`.
    public var appSupportDir: URL {
        appSupportOverride ?? home.appendingPathComponent("Library/Application Support/ClaudeCockpit", isDirectory: true)
    }
    /// rtk history database candidates, in priority order.
    public var rtkDatabaseCandidates: [URL] {
        [
            home.appendingPathComponent("Library/Application Support/rtk/history.db"),
            home.appendingPathComponent(".local/share/rtk/history.db"),
        ]
    }
    /// Default roots scanned for projects owning a `.claude/` directory.
    public var defaultProjectRoots: [URL] {
        [
            home.appendingPathComponent("DevApps", isDirectory: true),
            home.appendingPathComponent("Documents/GitHub", isDirectory: true),
        ]
    }

    /// True when `url` is inside the user's home directory (symlinks resolved).
    public func isInsideHome(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = home.standardizedFileURL.resolvingSymlinksInPath().path
        return target == root || target.hasPrefix(root + "/")
    }
}
