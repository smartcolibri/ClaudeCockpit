import Foundation
import CockpitShared

/// One row of the breakdown table: a group key (project / agent / skill) with its aggregate
/// usage, sorted by cost.
public struct BreakdownRow: Identifiable, Hashable, Sendable {
    public var id: String { label }
    public let label: String
    public let turnCount: Int
    public let totalTokens: Int
    public let estimatedCostUSD: Double
    /// Distinct sessions with at least one turn under this key.
    public let sessionCount: Int

    public init(label: String, turnCount: Int, totalTokens: Int, estimatedCostUSD: Double, sessionCount: Int = 0) {
        self.label = label
        self.turnCount = turnCount
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.sessionCount = sessionCount
    }
}

/// The grouping dimensions offered by the breakdown panel.
public enum BreakdownDimension: String, CaseIterable, Identifiable, Hashable, Sendable {
    case project = "Project"
    /// The model id as Claude Code wrote it (`claude-opus-4-8`), finer than the family.
    case model = "Model"
    case agent = "Agent"
    case skill = "Skill"

    public var id: String { rawValue }

    /// Group key used for turns that were not run by a sub-agent. Kept as the source app's
    /// English label so grouping stays identical; the UI maps it to French for display.
    public static let directLabel = "Direct (main session)"

    /// Group key for one event under this dimension. Sub-agent attribution fields are only
    /// populated on turns actually run by a sub-agent, so main-session turns fall back to
    /// `directLabel` under Agent/Skill.
    public func key(
        for event: UsageEvent,
        home: URL = ClaudePaths.realHome
    ) -> String {
        switch self {
        case .project: UsagePath.shorten(event.cwd, home: home)
        case .model: event.model
        case .agent: event.attributionAgent ?? Self.directLabel
        case .skill: event.attributionSkill ?? Self.directLabel
        }
    }
}
