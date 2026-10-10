import SwiftUI
import CockpitShared
import OverviewKit

/// The engine's advice, most pressing first: a coloured dot, one sentence, and a tap that
/// leads to the section where it can be looked into.
struct RecommendationsCard: View {
    @Environment(CockpitStore.self) private var store
    let recommendations: [Recommendation]
    /// False until at least one source has been read: "nothing to recommend" must not show
    /// while nothing is known yet.
    let ready: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                SectionLabel(text: String(localized: "Recommendations"))
            }
            if !ready {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading…").font(.system(size: 11)).foregroundStyle(Theme.slate)
                }
            } else if recommendations.isEmpty {
                Text("Nothing to recommend right now.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recommendations.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().opacity(0.4) }
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ item: Recommendation) -> some View {
        Button {
            open(item.target)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(item.level.color).frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(verbatim: item.sentence { store.money($0) })
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.sentence { store.money($0) })
        .accessibilityValue(item.level.label)
        .accessibilityHint(String(localized: "Opens \(item.target.section.title)", locale: AppFormat.locale))
    }

    private func open(_ target: Recommendation.Target) {
        switch target {
        case .sessionsWithErrors: store.showSessions(withErrorsOnly: true, day: Date())
        case .sessions: store.showSessions()
        case .usage, .rtk: store.show(target.section)
        }
    }
}

extension Recommendation.Target {
    var section: CockpitSection {
        switch self {
        case .usage: .usage
        case .sessions, .sessionsWithErrors: .sessions
        case .rtk: .rtk
        }
    }
}

extension Recommendation.Level {
    var color: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: Theme.blue
        case .good: Theme.emerald
        }
    }

    var label: String {
        switch self {
        case .critical: String(localized: "Critical")
        case .warning: String(localized: "Warning")
        case .info: String(localized: "Info")
        case .good: String(localized: "Good")
        }
    }
}

extension Recommendation {
    /// The engine returns kinds; the sentence is written here, where the String Catalog
    /// translates it. Amounts come in USD and are shown in the display currency by `money`.
    func sentence(money: (Double) -> String) -> String {
        switch kind {
        case .costUp(let fraction):
            String(localized: "Spending is up \(AppFormat.percent(fraction)) compared with the same point last week.", locale: AppFormat.locale)
        case .costDown(let fraction):
            String(localized: "Spending is down \(AppFormat.percent(fraction)) compared with the same point last week.", locale: AppFormat.locale)
        case .opusShareRose(let share, let previous, let project?):
            String(localized: "Opus rose to \(AppFormat.percent(share)) of the cost, from \(AppFormat.percent(previous)): try Sonnet for short tasks in \(project).", locale: AppFormat.locale)
        case .opusShareRose(let share, let previous, nil):
            String(localized: "Opus rose to \(AppFormat.percent(share)) of the cost, from \(AppFormat.percent(previous)): try Sonnet for short tasks.", locale: AppFormat.locale)
        case .sessionsWithErrors(let count):
            String(localized: "\(count) sessions hit errors today.", locale: AppFormat.locale)
        case .lowHealthSessions(let count):
            // 60 is `SessionHealthTile.lowScore`, written out so the count stays the only number.
            String(localized: "\(count) sessions scored below 60 today.", locale: AppFormat.locale)
        case .peakHour(let hour, let share):
            String(localized: "Usage peaks between \(AppFormat.hour(hour)) and \(AppFormat.hour((hour + 1) % 24)): \(AppFormat.percent(share)) of today's cost.", locale: AppFormat.locale)
        case .lowCacheRate(let rate):
            String(localized: "Only \(AppFormat.percent(rate)) of prompt tokens are read from the cache: sessions that keep their context reuse more.", locale: AppFormat.locale)
        case .rtkMissing:
            String(localized: "RTK is not set up: it trims shell output before it reaches the model.")
        case .rtkLowSavings(let fraction):
            String(localized: "RTK saved only \(AppFormat.percent(fraction)) of what it filtered this week.", locale: AppFormat.locale)
        case .unpricedModel(let model):
            String(localized: "The model \(model) has no dedicated pricing: the Sonnet rate is applied to it.", locale: AppFormat.locale)
        case .projectionAboveLastMonth(let projection, let lastMonth):
            String(localized: "This month is heading for \(money(projection)), above last month's \(money(lastMonth)).", locale: AppFormat.locale)
        }
    }
}
