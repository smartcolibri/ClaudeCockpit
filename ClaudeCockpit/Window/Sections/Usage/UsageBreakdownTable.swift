import SwiftUI
import CockpitShared
import UsageKit

/// Cost and token breakdown grouped by project, agent or skill, sorted by estimated cost.
struct UsageBreakdownTable: View {
    let snapshot: UsageSnapshot
    let money: (Double) -> String
    @State private var dimension: BreakdownDimension = .project

    var body: some View {
        let rows = snapshot.breakdown(for: dimension)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionLabel(text: String(localized: "Breakdown"))
                Spacer()
                Picker("", selection: $dimension) {
                    ForEach(BreakdownDimension.allCases) { dimension in
                        Text(dimension.displayName).tag(dimension)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            if rows.isEmpty {
                Text("No data in this period.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    header
                    ForEach(rows) { row in
                        rowView(row)
                        if row.id != rows.last?.id {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private var header: some View {
        HStack {
            Text(dimension.displayName.uppercased())
            Spacer()
            Text(String(localized: "Turns").uppercased()).frame(width: 70, alignment: .trailing)
            Text(String(localized: "Tokens").uppercased()).frame(width: 90, alignment: .trailing)
            Text(String(localized: "Cost").uppercased()).frame(width: 90, alignment: .trailing)
        }
        .font(.label(10))
        .tracking(1.2)
        .foregroundStyle(Theme.slate)
        .padding(.bottom, 8)
    }

    private func rowView(_ row: BreakdownRow) -> some View {
        HStack {
            Text(dimension.displayRowLabel(row.label))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(AppFormat.integer(row.turnCount))
                .frame(width: 70, alignment: .trailing)
            Text(AppFormat.tokens(row.totalTokens))
                .frame(width: 90, alignment: .trailing)
            Text(money(row.estimatedCostUSD))
                .foregroundStyle(Theme.blue)
                .frame(width: 90, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(Theme.slate)
        .padding(.vertical, 6)
    }
}
