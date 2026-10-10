import SwiftUI
import CockpitShared
import UsageKit

/// The chrome of the Usage screen's chart cards: the Overview tiles' look (icon, uppercase
/// title, card background) with a control on the right of the title, e.g. a segmented switch.
struct UsageCard<Accessory: View, Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = Theme.blue
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                SectionLabel(text: title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                accessory
            }
            .frame(minHeight: 22)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension UsageCard where Accessory == EmptyView {
    init(title: String, icon: String, tint: Color = Theme.blue, @ViewBuilder content: () -> Content) {
        self.init(title: title, icon: icon, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

/// Hands a card the current snapshot. The screen shows its cards only once a snapshot exists
/// and says once, above them, why the transcripts cannot be read; a failed rescan keeps the
/// last figures on screen.
struct UsageSource<Content: View>: View {
    @Environment(CockpitStore.self) private var store
    @ViewBuilder var content: (UsageSnapshot) -> Content

    var body: some View {
        if let usage = store.usage { content(usage) }
    }
}

extension UsagePeriod.Bucket {
    func tokens(_ series: UsageSeries) -> Int {
        switch series {
        case .input: inputTokens
        case .output: outputTokens
        case .cacheRead: cacheReadTokens
        case .cacheCreation: cacheCreationTokens
        }
    }
}

extension UsageSummary {
    /// The four token kinds in the order the split bars and legends use.
    var tokenParts: [(UsageSeries, Int)] {
        [(.input, inputTokens), (.output, outputTokens),
         (.cacheRead, cacheReadTokens), (.cacheCreation, cacheCreationTokens)]
    }
}
