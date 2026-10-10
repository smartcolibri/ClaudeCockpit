import Foundation

/// The four token kinds, in bottom-to-top stacking order. The per-case `Color` lives in the
/// app layer.
public enum UsageSeries: String, CaseIterable, Identifiable, Hashable, Sendable {
    case input = "Input"
    case output = "Output"
    case cacheRead = "Cache Read"
    case cacheCreation = "Cache Creation"

    public var id: String { rawValue }
}

/// Aggregate usage for one hour of day (0...23): today's or yesterday's on the Overview,
/// summed over the period on the Usage screen.
public struct HourlyUsage: Identifiable, Hashable, Sendable {
    public var id: Int { hour }
    public let hour: Int
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var estimatedCostUSD: Double = 0

    public init(hour: Int) { self.hour = hour }
}

/// Aggregate stats for the currently filtered set of usage events (the stat cards row).
public struct UsageSummary: Hashable, Sendable {
    public var sessionCount: Int = 0
    public var turnCount: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var estimatedCostUSD: Double = 0

    public init() {}

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }
}
