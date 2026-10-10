import SwiftUI
import CockpitShared
import UsageKit

/// App-layer presentation of the UsageKit value types: colours (UsageKit is Foundation-only)
/// and localised labels (its raw values stay as they are so persisted selections and grouping
/// keys survive untouched).
enum UsagePalette {
    /// The four token series, in a blue/violet/teal family so the terracotta cost line
    /// overlaid on the same chart never reads as one more token bucket.
    static let input = Theme.blue
    static let output = Theme.violet
    static let cacheRead = Theme.adaptive(light: 0x0E9AA7, dark: 0x3ECFD5)
    static let cacheCreation = Theme.adaptive(light: 0x6C8AA8, dark: 0x8FA8C0)
    /// Cost overlay on the daily chart. Cost *figures* use `Theme.blue`, the usage accent;
    /// the line needs a hue no token series occupies.
    static let cost = Theme.accent
    /// Context series (last week / yesterday) — never competes with the emphasis series.
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

    /// Keys of the chart's foreground style scale — must match the series values passed to
    /// `.value(_:_:)`, or Swift Charts silently falls back to its default palette.
    static var styleScale: KeyValuePairs<String, Color> {
        [
            UsageSeries.input.displayName: UsagePalette.input,
            UsageSeries.output.displayName: UsagePalette.output,
            UsageSeries.cacheRead.displayName: UsagePalette.cacheRead,
            UsageSeries.cacheCreation.displayName: UsagePalette.cacheCreation,
        ]
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
        case .agent: String(localized: "Agent")
        case .skill: String(localized: "Skill")
        }
    }

    /// Turns not run by a sub-agent are grouped under the module's fixed key.
    func displayRowLabel(_ label: String) -> String {
        label == BreakdownDimension.directLabel ? String(localized: "Direct (main session)") : label
    }
}

extension Insight.Level {
    var displayName: String {
        switch self {
        case .critical: String(localized: "Critical")
        case .warning: String(localized: "Warning")
        case .good: String(localized: "Good")
        case .info: String(localized: "Info")
        }
    }

    var color: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .good: .green
        case .info: Theme.blue
        }
    }
}

extension Insight {
    /// Sentence rebuilt from `kind`. `text` is the source app's fixed English wording, kept
    /// verbatim by UsageKit on purpose — it is never displayed here.
    var displayText: String {
        switch kind {
        case .costUp(let fraction):
            String(localized: "Cost up \(AppFormat.percent(fraction)) compared with the same point last week.", locale: AppFormat.locale)
        case .costDown(let fraction):
            String(localized: "Cost down \(AppFormat.percent(fraction)) compared with the same point last week.", locale: AppFormat.locale)
        case .unpricedModel(let model):
            String(localized: "\(model) has no dedicated pricing — the default Sonnet rate is applied.", locale: AppFormat.locale)
        case .cacheHitRate(let rate):
            String(localized: "Cache read rate at \(AppFormat.percent(rate)) — keeping costs down.", locale: AppFormat.locale)
        case .noNotableChange:
            String(localized: "No notable change in this period.")
        }
    }
}
