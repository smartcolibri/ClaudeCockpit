import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// Estimated cost of the filtered period split by model family, as a donut with the amounts
/// beside it — a part-to-whole view, not a trend.
struct ModelMixCard: View {
    @Environment(CockpitStore.self) private var store

    var body: some View {
        UsageCard(title: String(localized: "Cost by model family"), icon: "chart.pie.fill", tint: Theme.violet) {
            UsageSource { usage in
                let rows = usage.costByFamily
                let total = rows.reduce(0) { $0 + $1.costUSD }
                if rows.isEmpty || total <= 0 {
                    TileCaption(text: String(localized: "No spend in this period."))
                } else {
                    HStack(alignment: .center, spacing: 18) {
                        donut(rows)
                        legend(rows, total: total)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "Cost by model family"))
                    .accessibilityValue(rows.map { "\($0.family.label) \(store.money($0.costUSD))" }.joined(separator: ", "))
                }
            }
        }
    }

    private func donut(_ rows: [ModelCostRow]) -> some View {
        Chart(rows) { row in
            SectorMark(angle: .value("Cost", row.costUSD), innerRadius: .ratio(0.62), angularInset: 1.2)
                .foregroundStyle(row.family.color)
        }
        .chartLegend(.hidden)
        .frame(width: 104, height: 104)
    }

    private func legend(_ rows: [ModelCostRow], total: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.family.color).frame(width: 7, height: 7)
                    Text(verbatim: row.family.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text(verbatim: store.money(row.costUSD))
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text(verbatim: AppFormat.percent(row.costUSD / total))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.slate)
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: 260)
    }
}
