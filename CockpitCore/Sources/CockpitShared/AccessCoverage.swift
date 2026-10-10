import Foundation

/// Pure rules behind the App Sandbox grants: whether a path falls under a folder the
/// user granted, and whether a folder picked in the open panel is the one asked for.
///
/// Paths are compared lexically, component by component, after standardisation
/// (`.`/`..` removed, trailing slash dropped). Symlinks are deliberately not resolved:
/// inside the sandbox a path that is not granted cannot be read, so resolving it
/// would silently fall back to the unresolved form anyway.
public enum AccessCoverage {

    /// Standardised path, no trailing slash (except for `/`).
    public static func normalized(_ path: String) -> String {
        var standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        while standardized.count > 1, standardized.hasSuffix("/") { standardized.removeLast() }
        return standardized
    }

    /// True when `path` equals `root` or lies below it (`/Users/x` never covers `/Users/xy`).
    public static func isPath(_ path: String, inside root: String) -> Bool {
        let target = normalized(path)
        let base = normalized(root)
        if base == "/" { return true }
        return target == base || target.hasPrefix(base + "/")
    }

    /// Whether `url` is readable given the granted roots. Outside the sandbox the app
    /// reads what the user can, so everything counts as covered.
    public static func isCovered(_ url: URL, grantedPaths: [String], sandboxed: Bool) -> Bool {
        guard sandboxed else { return true }
        return grantedPaths.contains { isPath(url.path, inside: $0) }
    }

    /// What a folder picked in the grant panel gives, measured against the folder
    /// the app asked for (`expected`, usually the home) and the one it cannot work
    /// without (`required`, the Claude config directory).
    public enum SelectionVerdict: Equatable, Sendable {
        /// The selection contains `required` and `expected`: everything the app reads is covered.
        case full
        /// The selection contains `required` but not `expected`: the app works, degraded.
        case partial
        /// The selection contains `expected` but not `required`: the Claude config directory
        /// lives elsewhere (another volume, say) and needs a grant of its own.
        case requiredElsewhere
        /// The selection contains neither: it gives the app nothing it needs.
        case unrelated
    }

    public static func evaluate(selection: URL, expected: URL, required: URL) -> SelectionVerdict {
        let hasRequired = isPath(required.path, inside: selection.path)
        let hasExpected = isPath(expected.path, inside: selection.path)
        switch (hasRequired, hasExpected) {
        case (true, true): return .full
        case (true, false): return .partial
        case (false, true): return .requiredElsewhere
        case (false, false): return .unrelated
        }
    }

    /// Whether swapping the grant at `old` for `new` keeps `required` readable. A grant that
    /// never covered `required` can be replaced by anything; one that did must be replaced by
    /// a folder that does, unless another usable grant (`grantedPaths`) covers it anyway.
    public static func replacementKeepsRequired(
        old: String, new: URL, required: URL, grantedPaths: [String]
    ) -> Bool {
        guard isPath(required.path, inside: old) else { return true }
        let after = grantedPaths.filter { normalized($0) != normalized(old) } + [new.path]
        return after.contains { isPath(required.path, inside: $0) }
    }

    /// True when the process runs inside the App Sandbox.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}
