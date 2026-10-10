import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// The chrome every Overview tile shares: an uppercase label with its icon, then the content.
/// With an `action` the whole tile is one button — a label for VoiceOver, a hover outline for
/// the pointer — that leads to the section behind the figure.
struct OverviewTile<Content: View>: View {
    let title: String
    let icon: String
    var tint: Color = Theme.blue
    /// What VoiceOver reads after the title: the tile's figures in one sentence.
    var summary: String = ""
    /// Read as the button's hint, e.g. "Opens Local Usage".
    var destination: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { chrome(hover: hovering) }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(summary)
                .accessibilityHint(destination.map { String(localized: "Opens \($0)", locale: AppFormat.locale) } ?? "")
                .accessibilityAddTraits(.isButton)
        } else {
            // `.contain`, not `.ignore`: a source banner's Retry button inside must stay reachable.
            chrome(hover: false)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
                .accessibilityValue(summary)
        }
    }

    private func chrome(hover: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                SectionLabel(text: title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.mist)
                        .opacity(hover ? 1 : 0)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(tint.opacity(hover ? 0.55 : 0), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// What a tile shows in place of its figures while its source cannot give them: the grant
/// flow, the error with a retry, or a quiet loading line. A failing source only ever blanks
/// its own tiles.
struct TileSource<Content: View>: View {
    let state: SourceState
    /// True once the source has produced something to draw.
    let ready: Bool
    let unauthorized: String
    var retry: (() -> Void)? = nil
    var loading: String = String(localized: "Reading…")
    @ViewBuilder var content: Content

    var body: some View {
        if state.isUnauthorized {
            AccessRequiredBanner(message: unauthorized)
        } else if let message = state.errorMessage {
            SourceBanner(kind: .error, message: message, action: retry)
        } else if ready {
            content
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loading).font(.system(size: 11)).foregroundStyle(Theme.slate)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// The big figure at the top of a tile.
struct TileValue: View {
    let text: String
    var tint: Color = Theme.ink
    var suffix: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: text)
                .font(.display(24))
                .monospacedDigit()
                .foregroundStyle(tint)
            if let suffix {
                Text(verbatim: suffix)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint.opacity(0.75))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// A small caption line under a tile's figure.
struct TileCaption: View {
    let text: String
    var tint: Color = Theme.slate

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10.5))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// One bar split between the four token kinds, each kind's share of `parts`' total. Cache
/// reads usually dwarf the rest, so any non-zero kind keeps a sliver wide enough to see.
struct TokenSplitBar: View {
    let parts: [(UsageSeries, Int)]

    var body: some View {
        GeometryReader { geometry in
            let total = max(1, parts.reduce(0) { $0 + $1.1 })
            HStack(spacing: 1.5) {
                ForEach(parts, id: \.0) { series, value in
                    if value > 0 {
                        Rectangle()
                            .fill(series.color)
                            .frame(width: max(3, geometry.size.width * CGFloat(value) / CGFloat(total)))
                            .help(Text(verbatim: "\(series.displayName): \(AppFormat.tokens(value))"))
                    }
                }
                if parts.allSatisfy({ $0.1 == 0 }) { Rectangle().fill(Theme.track) }
            }
            .frame(width: geometry.size.width, alignment: .leading)
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

/// The floating label a chart shows under the pointer.
struct ChartTooltip: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text(verbatim: line)
                    .font(.system(size: 10, weight: index == 0 ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(index == 0 ? Theme.ink : Theme.slate)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
    }
}

extension View {
    /// Tracks the pointer over a chart's plot area and reports the x value under it, `nil`
    /// once it leaves. Swift Charts' own selection waits for a click on macOS; a dashboard
    /// tooltip has to follow the hover.
    func chartHover<X: Plottable>(_ type: X.Type, _ onChange: @escaping (X?) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return onChange(nil) }
                            let origin = geometry[plot].origin
                            onChange(proxy.value(atX: location.x - origin.x, as: X.self))
                        case .ended:
                            onChange(nil)
                        }
                    }
            }
        }
    }
}
