import SwiftUI
import CockpitShared
import UsageKit

/// Today's tokens and how they split between input, output and the two cache kinds.
struct TokensTodayTile: View {
    @Environment(CockpitStore.self) private var store

    private var today: UsageSummary? { store.usage?.overview.today }

    var body: some View {
        OverviewTile(
            title: String(localized: "Tokens today"),
            icon: "number.circle",
            summary: summary,
            destination: CockpitSection.usage.title,
            action: store.usageState.showsBanner ? nil : { store.show(.usage) }
        ) {
            TileSource(
                state: store.usageState, ready: today != nil,
                unauthorized: String(localized: "the transcripts cannot be read."),
                retry: { Task { await store.refreshUsage() } }
            ) {
                if let today { content(today) }
            }
        }
    }

    private func parts(_ today: UsageSummary) -> [(UsageSeries, Int)] {
        [(.input, today.inputTokens), (.output, today.outputTokens),
         (.cacheRead, today.cacheReadTokens), (.cacheCreation, today.cacheCreationTokens)]
    }

    private func content(_ today: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TileValue(text: AppFormat.tokens(today.totalTokens))
            splitBar(today)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6, alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 3) {
                ForEach(parts(today), id: \.0) { series, _ in
                    HStack(spacing: 4) {
                        Circle().fill(series.color).frame(width: 6, height: 6)
                        Text(verbatim: series.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.slate)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
    }

    /// One bar, each kind's share of today's tokens. Cache reads usually dwarf the rest, so
    /// any non-zero kind keeps a sliver wide enough to see.
    private func splitBar(_ today: UsageSummary) -> some View {
        GeometryReader { geometry in
            let total = max(1, today.totalTokens)
            HStack(spacing: 1.5) {
                ForEach(parts(today), id: \.0) { series, value in
                    if value > 0 {
                        Rectangle()
                            .fill(series.color)
                            .frame(width: max(3, geometry.size.width * CGFloat(value) / CGFloat(total)))
                            .help(Text(verbatim: "\(series.displayName): \(AppFormat.tokens(value))"))
                    }
                }
                if today.totalTokens == 0 { Rectangle().fill(Theme.track) }
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private var summary: String {
        guard let today else { return "" }
        return ([AppFormat.tokens(today.totalTokens)] + parts(today).map { "\($0.0.displayName) \(AppFormat.tokens($0.1))" })
            .joined(separator: ", ")
    }
}
