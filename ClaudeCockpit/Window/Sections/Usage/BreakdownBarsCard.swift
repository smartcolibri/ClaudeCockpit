import SwiftUI
import CockpitShared
import UsageKit

/// Cost and sessions grouped by project, model, agent or skill, as bars against the costliest
/// row. The top rows show at first; "Show all" lists the others in place. Turns and tokens
/// stay in each row's tooltip.
struct BreakdownBarsCard: View {
    @Environment(CockpitStore.self) private var store
    @State private var dimension: BreakdownDimension = .project
    @State private var expanded = false

    static let topCount = 5

    var body: some View {
        UsageCard(title: dimension.byTitle, icon: "list.bullet.indent") {
            Picker(String(localized: "Breakdown"), selection: $dimension) {
                ForEach(BreakdownDimension.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            UsageSource { usage in
                let rows = usage.breakdown(for: dimension).filter { $0.estimatedCostUSD > 0 || $0.turnCount > 0 }
                if rows.isEmpty {
                    TileCaption(text: String(localized: "No data in this period."))
                } else {
                    list(rows)
                }
            }
        }
        .onChange(of: dimension) { expanded = false }
    }

    private func list(_ rows: [BreakdownRow]) -> some View {
        let shown = expanded ? rows : Array(rows.prefix(Self.topCount))
        let peak = max(rows.first?.estimatedCostUSD ?? 0, 0.0001)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(shown) { row in
                rowView(row, peak: peak)
            }
            if rows.count > Self.topCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Text(expanded
                         ? String(localized: "Show less")
                         : String(localized: "+ \(rows.count - Self.topCount) more · Show all", locale: AppFormat.locale))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rowView(_ row: BreakdownRow, peak: Double) -> some View {
        let sessions = String(localized: "\(row.sessionCount) sessions", locale: AppFormat.locale)
        let detail = String(localized: "Turns: \(AppFormat.integer(row.turnCount)) · Tokens: \(AppFormat.tokens(row.totalTokens))", locale: AppFormat.locale)
        let spoken = [store.money(row.estimatedCostUSD), sessions, detail].joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: name(row.label))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(verbatim: "\(store.money(row.estimatedCostUSD)) · \(sessions)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(color(row.label))
                    .frame(width: max(3, geometry.size.width * CGFloat(row.estimatedCostUSD / peak)))
            }
            .frame(height: 5)
        }
        .contentShape(Rectangle())
        .help(Text(verbatim: "\(dimension.displayRowLabel(row.label))\n\(detail)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name(row.label))
        .accessibilityValue(spoken)
    }

    /// The folder name reads better than the whole `~/…` path; the tooltip keeps the path.
    private func name(_ label: String) -> String {
        switch dimension {
        case .project:
            let last = (label as NSString).lastPathComponent
            return last.isEmpty ? label : last
        case .model:
            return label
        case .agent, .skill:
            return dimension.displayRowLabel(label)
        }
    }

    private func color(_ label: String) -> Color {
        switch dimension {
        case .project: Theme.blue
        case .model: ModelFamily.detect(from: label).color
        case .agent, .skill: Theme.violet
        }
    }
}
