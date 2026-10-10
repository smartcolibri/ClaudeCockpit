import SwiftUI
import CockpitShared
import UsageKit

/// App-layer presentation of the UsageKit value types: colours (UsageKit is Foundation-only)
/// and localised labels (its raw values stay as they are so persisted selections and grouping
/// keys survive untouched).
enum UsagePalette {
    /// The four token series, in a blue/violet/teal family apart from the terracotta accent.
    static let input = Theme.blue
    static let output = Theme.violet
    static let cacheRead = Theme.adaptive(light: 0x0E9AA7, dark: 0x3ECFD5)
    static let cacheCreation = Theme.adaptive(light: 0x6C8AA8, dark: 0x8FA8C0)
    /// Context series (yesterday on the Overview) — never competes with the emphasis series.
    static let context = Theme.mist
}

extension DateRangeFilter {
    var displayName: String {
        switch self {
        case .today: String(localized: "Today")
        case .thisWeek: String(localized: "This week")
        case .thisMonth: String(localized: "This month")
        case .prevMonth: String(localized: "Previous month")
        case .last7Days: String(localized: "7 days")
        case .last30Days: String(localized: "30 days")
        case .last90Days: String(localized: "90 days")
        case .all: String(localized: "All")
        }
    }

    /// The segmented control's label, short enough for the filters to fit on one line.
    var shortName: String {
        switch self {
        case .today: String(localized: "Today")
        case .thisWeek: String(localized: "Week")
        case .thisMonth: String(localized: "Month")
        case .prevMonth: String(localized: "Prev. month")
        case .last7Days: String(localized: "7 d")
        case .last30Days: String(localized: "30 d")
        case .last90Days: String(localized: "90 d")
        case .all: String(localized: "All")
        }
    }
}

extension UsageSeries {
    var displayName: String {
        switch self {
        case .input: String(localized: "Input")
        case .output: String(localized: "Output")
        case .cacheRead: String(localized: "Cache read")
        case .cacheCreation: String(localized: "Cache written")
        }
    }

    var color: Color {
        switch self {
        case .input: UsagePalette.input
        case .output: UsagePalette.output
        case .cacheRead: UsagePalette.cacheRead
        case .cacheCreation: UsagePalette.cacheCreation
        }
    }
}

extension ModelFamily {
    /// Family names are proper nouns — identical in every language.
    var label: String { rawValue }

    var color: Color {
        switch self {
        case .opus: Theme.violet
        case .sonnet: Theme.blue
        case .haiku: UsagePalette.cacheRead
        case .fable: Theme.accent
        }
    }
}

extension BreakdownDimension {
    var displayName: String {
        switch self {
        case .project: String(localized: "Project")
        case .model: String(localized: "Model")
        case .agent: String(localized: "Agent")
        case .skill: String(localized: "Skill")
        }
    }

    /// The breakdown card's title for this dimension.
    var byTitle: String {
        switch self {
        case .project: String(localized: "By project")
        case .model: String(localized: "By model")
        case .agent: String(localized: "By agent")
        case .skill: String(localized: "By skill")
        }
    }

    /// Turns not run by a sub-agent are grouped under the module's fixed key.
    func displayRowLabel(_ label: String) -> String {
        label == BreakdownDimension.directLabel ? String(localized: "Direct (main session)") : label
    }
}
