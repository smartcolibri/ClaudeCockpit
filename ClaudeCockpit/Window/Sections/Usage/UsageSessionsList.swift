import SwiftUI
import CockpitShared
import UsageKit

/// Named sessions in the current filter range, most recent first. A row opens its detail sheet.
struct UsageSessionsList: View {
    let sessions: [SessionSummary]
    let money: (Double) -> String
    @State private var selected: SessionSummary?

    private static let maxRows = 30

    var body: some View {
        let shown = Array(sessions.prefix(Self.maxRows))
        return VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: String(localized: "Sessions"))
            if shown.isEmpty {
                Text("No sessions in this period.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    header
                    ForEach(shown) { session in
                        Button { selected = session } label: { rowView(session) }
                            .buttonStyle(.plain)
                        if session.id != shown.last?.id {
                            Divider().overlay(Theme.cardStroke)
                        }
                    }
                }
                if sessions.count > Self.maxRows {
                    Text("\(Self.maxRows) of \(AppFormat.integer(sessions.count)) sessions shown — narrow the period or the project to see the others.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
        .sheet(item: $selected) { session in
            SessionDetailSheet(session: session, money: money)
        }
    }

    private var header: some View {
        HStack {
            Text(String(localized: "Title").uppercased())
            Spacer()
            Text(String(localized: "Project").uppercased()).frame(width: 180, alignment: .leading)
            Text(String(localized: "Last turn").uppercased()).frame(width: 130, alignment: .leading)
            Text(String(localized: "Turns").uppercased()).frame(width: 60, alignment: .trailing)
            Text(String(localized: "Tokens").uppercased()).frame(width: 90, alignment: .trailing)
            Text(String(localized: "Cost").uppercased()).frame(width: 80, alignment: .trailing)
        }
        .font(.label(10))
        .tracking(1.2)
        .foregroundStyle(Theme.slate)
        .padding(.bottom, 8)
    }

    private func rowView(_ session: SessionSummary) -> some View {
        HStack {
            Text(session.displayName)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(UsagePath.shorten(session.cwd))
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.head)
            Text(AppFormat.dateTime(session.lastSeen))
                .frame(width: 130, alignment: .leading)
            Text(AppFormat.integer(session.turnCount))
                .frame(width: 60, alignment: .trailing)
            Text(AppFormat.tokens(session.totalTokens))
                .frame(width: 90, alignment: .trailing)
            Text(money(session.estimatedCostUSD))
                .foregroundStyle(Theme.blue)
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .foregroundStyle(Theme.slate)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Detail sheet for one session: identity, time range, token and cost totals.
struct SessionDetailSheet: View {
    let session: SessionSummary
    let money: (Double) -> String
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.displayName)
                    .font(.display(18))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Spacer(minLength: 16)
                Button("Close", action: dismiss.callAsFunction)
                    .keyboardShortcut(.defaultAction)
            }
            Text(UsagePath.shorten(session.cwd))
                .font(.system(size: 12))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
                .truncationMode(.head)
            Text(verbatim: "\(AppFormat.dateTime(session.firstSeen)) → \(AppFormat.dateTime(session.lastSeen)) · \(AppFormat.duration(session.lastSeen.timeIntervalSince(session.firstSeen)))")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
            Divider().overlay(Theme.cardStroke)
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(
                    label: String(localized: "Turns"),
                    value: AppFormat.integer(session.turnCount),
                    note: session.modelsUsed.joined(separator: ", "))
                StatTile(
                    label: String(localized: "Input"),
                    value: AppFormat.tokens(session.inputTokens),
                    note: String(localized: "tokens"),
                    tint: UsagePalette.input)
                StatTile(
                    label: String(localized: "Output"),
                    value: AppFormat.tokens(session.outputTokens),
                    note: String(localized: "tokens"),
                    tint: UsagePalette.output)
                StatTile(
                    label: String(localized: "Cache read"),
                    value: AppFormat.tokens(session.cacheReadTokens),
                    note: String(localized: "tokens"),
                    tint: UsagePalette.cacheRead)
                StatTile(
                    label: String(localized: "Cache written"),
                    value: AppFormat.tokens(session.cacheCreationTokens),
                    note: String(localized: "tokens"),
                    tint: UsagePalette.cacheCreation)
                StatTile(
                    label: String(localized: "Estimated cost"),
                    value: money(session.estimatedCostUSD),
                    note: String(localized: "approximate"),
                    tint: Theme.blue)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 360)
        .background(Theme.background)
    }
}
