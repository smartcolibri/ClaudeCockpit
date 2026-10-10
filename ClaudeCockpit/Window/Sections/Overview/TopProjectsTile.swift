import SwiftUI
import CockpitShared
import UsageKit

/// The five projects that cost the most over 30 days, as bars against the costliest.
struct TopProjectsTile: View {
    @Environment(CockpitStore.self) private var store

    private var rows: [BreakdownRow]? { store.usage?.overview.topProjects }

    var body: some View {
        OverviewTile(
            title: String(localized: "Top projects"),
            icon: "folder.fill",
            summary: (rows ?? []).map { "\(name($0.label)) \(store.money($0.estimatedCostUSD))" }.joined(separator: ", "),
            destination: CockpitSection.usage.title,
            action: { store.show(.usage) }
        ) {
            TileSource(
                state: store.usageState, ready: rows != nil,
                unauthorized: String(localized: "the transcripts cannot be read."),
                retry: { Task { await store.refreshUsage() } }
            ) {
                if let rows, !rows.isEmpty {
                    content(rows)
                } else {
                    TileCaption(text: String(localized: "No spend in the last 30 days"))
                }
            }
        }
    }

    private func content(_ rows: [BreakdownRow]) -> some View {
        let peak = max(rows.first?.estimatedCostUSD ?? 1, 0.0001)
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: name(row.label))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(verbatim: store.money(row.estimatedCostUSD))
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.slate)
                    }
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Theme.blue)
                            .frame(width: max(3, geometry.size.width * CGFloat(row.estimatedCostUSD / peak)))
                    }
                    .frame(height: 4)
                }
                .help(Text(verbatim: row.label))
            }
        }
    }

    /// The folder name reads better than the whole `~/…` path in a narrow tile; the full
    /// path stays in the tooltip.
    private func name(_ label: String) -> String {
        let last = (label as NSString).lastPathComponent
        return last.isEmpty ? label : last
    }
}
