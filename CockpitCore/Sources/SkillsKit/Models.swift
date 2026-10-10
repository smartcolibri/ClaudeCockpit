// SkillsKit — see docs/superpowers/specs/2026-09-21-claude-cockpit-design.md
import Foundation
import CockpitShared

// MARK: - Kind

/// The three kinds of Claude Code resources managed by the app.
///
/// Skills live in a directory holding a `SKILL.md`; agents and commands are
/// single markdown files with a front matter header.
public enum ResourceKind: String, CaseIterable, Sendable, Codable {
    case skill
    case agent
    case command

    /// Name of the folder holding resources of this kind at every level.
    public var directoryName: String {
        switch self {
        case .skill: return "skills"
        case .agent: return "agents"
        case .command: return "commands"
        }
    }

    /// True when one resource is a directory (skills) rather than a single file.
    public var isDirectoryBased: Bool { self == .skill }

    /// Plural label for the UI.
    public var pluralLabel: String {
        switch self {
        case .skill: return String(localized: "Skills", bundle: .module)
        case .agent: return String(localized: "Agents", bundle: .module)
        case .command: return String(localized: "Commands", bundle: .module)
        }
    }
}

// MARK: - Project

/// A project owning a `.claude/` directory.
public struct ProjectRef: Hashable, Identifiable, Sendable, Codable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    /// Stable identity: the standardized filesystem path.
    public var id: String { url.standardizedFileURL.path }

    /// `<project>/.claude`
    public var claudeDir: URL { url.appendingPathComponent(".claude", isDirectory: true) }
}

// MARK: - Level

/// Where a resource lives: the inactive library, the user-global `~/.claude`,
/// or a project's `.claude` directory.
public enum ResourceLevel: Hashable, Sendable {
    case library
    case global
    case project(ProjectRef)

    /// Label shown in the level picker.
    public var label: String {
        switch self {
        case .library: return String(localized: "Library", bundle: .module)
        case .global: return String(localized: "Global", bundle: .module)
        case .project(let project): return project.name
        }
    }

    /// Stable identifier, unique across projects sharing a basename.
    public var id: String {
        switch self {
        case .library: return "library"
        case .global: return "global"
        case .project(let project): return "project:\(project.id)"
        }
    }

    /// Filesystem-safe component used inside a backup folder.
    public var backupComponent: String {
        switch self {
        case .library: return "library"
        case .global: return "global"
        case .project(let project): return "project-" + NameSanitizer.sanitize(project.id)
        }
    }

    /// Directory holding resources of `kind` at this level.
    public func directory(for kind: ResourceKind, paths: ClaudePaths) -> URL {
        switch self {
        case .library:
            return paths.libraryDir.appendingPathComponent(kind.directoryName, isDirectory: true)
        case .global:
            switch kind {
            case .skill: return paths.skillsDir
            case .agent: return paths.agentsDir
            case .command: return paths.commandsDir
            }
        case .project(let project):
            return project.claudeDir.appendingPathComponent(kind.directoryName, isDirectory: true)
        }
    }
}

// MARK: - Resource

/// One skill, agent or command found on disk.
public struct ClaudeResource: Identifiable, Hashable, Sendable {
    public let kind: ResourceKind
    public let name: String
    public let level: ResourceLevel
    /// Directory for a skill, markdown file for an agent or a command.
    public let url: URL
    public let description: String?
    public let frontmatter: Frontmatter
    public let modifiedAt: Date
    public let sizeBytes: Int64
    /// True when the item itself (skill directory or markdown file) is a symbolic link,
    /// e.g. a skill installed as `~/.claude/skills/x -> ../../.agents/skills/x`. Such a
    /// resource is listed and readable, but `ResourceStore` refuses to transfer or delete
    /// it: the UI should show it as linked and disable those actions.
    public let isSymlink: Bool

    public init(
        kind: ResourceKind,
        name: String,
        level: ResourceLevel,
        url: URL,
        description: String? = nil,
        frontmatter: Frontmatter = Frontmatter(),
        modifiedAt: Date = .distantPast,
        sizeBytes: Int64 = 0,
        isSymlink: Bool = false
    ) {
        self.kind = kind
        self.name = name
        self.level = level
        self.url = url
        self.description = description
        self.frontmatter = frontmatter
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.isSymlink = isSymlink
    }

    /// Stable across refreshes: level identity + kind + name.
    public var id: String { "\(level.id)/\(kind.rawValue)/\(name)" }

    /// The markdown file carrying the content: `SKILL.md` inside a skill directory.
    public var contentURL: URL {
        kind.isDirectoryBased ? url.appendingPathComponent("SKILL.md") : url
    }

    public static func == (lhs: ClaudeResource, rhs: ClaudeResource) -> Bool {
        lhs.id == rhs.id
            && lhs.url == rhs.url
            && lhs.description == rhs.description
            && lhs.frontmatter == rhs.frontmatter
            && lhs.modifiedAt == rhs.modifiedAt
            && lhs.sizeBytes == rhs.sizeBytes
            && lhs.isSymlink == rhs.isSymlink
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Plugin

/// A skill shipped by an installed plugin. Read-only; can be imported.
public struct PluginResource: Identifiable, Hashable, Sendable {
    public let org: String
    public let plugin: String
    public let version: String
    public let name: String
    /// The skill directory inside the plugin cache.
    public let url: URL
    public let description: String?

    public init(
        org: String,
        plugin: String,
        version: String,
        name: String,
        url: URL,
        description: String? = nil
    ) {
        self.org = org
        self.plugin = plugin
        self.version = version
        self.name = name
        self.url = url
        self.description = description
    }

    public var id: String { "\(org)/\(plugin)/\(version)/\(name)" }

    /// Label shown in the import sheet, e.g. `superpowers:brainstorming`.
    public var qualifiedName: String { "\(plugin):\(name)" }

    public var contentURL: URL { url.appendingPathComponent("SKILL.md") }
}

// MARK: - Inventory

/// Immutable snapshot of every resource reachable from the three levels.
public struct SkillsInventory: Sendable, Equatable {
    public let resources: [ClaudeResource]
    /// Skills offered by the plugins in the cache, one per skill and version.
    public let plugins: [PluginResource]
    /// The installed plugins themselves, `org/plugin`, sorted: each counted once whatever its
    /// skills or cached versions, those with only orphaned versions left out.
    public let installedPlugins: [String]
    public let projects: [ProjectRef]
    public let generatedAt: Date

    public init(
        resources: [ClaudeResource] = [],
        plugins: [PluginResource] = [],
        installedPlugins: [String] = [],
        projects: [ProjectRef] = [],
        generatedAt: Date = Date()
    ) {
        self.resources = resources
        self.plugins = plugins
        self.installedPlugins = installedPlugins
        self.projects = projects
        self.generatedAt = generatedAt
    }

    /// Resources filtered by kind and/or level, already sorted by name.
    public func resources(kind: ResourceKind? = nil, level: ResourceLevel? = nil) -> [ClaudeResource] {
        resources.filter { resource in
            (kind == nil || resource.kind == kind) && (level == nil || resource.level == level)
        }
    }

    public func count(kind: ResourceKind? = nil, level: ResourceLevel? = nil) -> Int {
        resources(kind: kind, level: level).count
    }

    /// Every level present in this inventory, library and global first.
    public var levels: [ResourceLevel] {
        [.library, .global] + projects.map { ResourceLevel.project($0) }
    }

    public var isEmpty: Bool { resources.isEmpty && plugins.isEmpty }
}

// MARK: - Errors

public enum SkillsError: Error, Equatable, LocalizedError {
    /// A source or destination path escapes the user's home directory.
    case outsideHome
    /// The destination already exists and `overwrite` was not requested.
    case alreadyExists(URL)
    /// The source resource is gone from disk.
    case notFound
    /// Any filesystem or validation failure, with an explanation.
    case io(String)
    /// A filesystem failure that happened *after* the destination had been
    /// backed up. The destination itself is untouched, but the copy of it taken
    /// before the attempt is worth naming: it is the only other place the user
    /// can recover the resource from.
    case ioAfterBackup(String, URL)
    /// The resource (or the item it would replace) is a symbolic link. Copying one copies
    /// the link itself — a relative one then dangles — and backing one up saves only the
    /// link, so transfers and deletions of links are refused outright.
    case symlinkUnsupported(URL)

    public var errorDescription: String? {
        switch self {
        case .outsideHome:
            return String(localized: "Path outside the home folder.", bundle: .module)
        case .alreadyExists(let url):
            return String(localized: "Already exists at the destination: \(url.path)", bundle: .module)
        case .notFound:
            return String(localized: "Resource not found.", bundle: .module)
        case .io(let message):
            return message
        case .ioAfterBackup(let message, let backup):
            return String(localized: "\(message) A backup is still available in: \(backup.path)", bundle: .module)
        case .symlinkUnsupported(let url):
            return String(localized: "“\(url.lastPathComponent)” is a symbolic link: transferring and deleting it are not supported. Edit its target directly.", bundle: .module)
        }
    }
}

// MARK: - Name sanitizing

/// Replaces anything outside `[A-Za-z0-9_-]` with `-`, as SkillManager does.
public enum NameSanitizer {
    public static func sanitize(_ name: String) -> String {
        var result = ""
        result.reserveCapacity(name.count)
        for scalar in name.unicodeScalars {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "-":
                result.unicodeScalars.append(scalar)
            default:
                result.append("-")
            }
        }
        return result
    }
}

// MARK: - Transfer mode

public enum TransferMode: String, Sendable, CaseIterable {
    case copy
    case move

    public var label: String {
        switch self {
        case .copy: return String(localized: "Copy", bundle: .module)
        case .move: return String(localized: "Move", bundle: .module)
        }
    }
}
