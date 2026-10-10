import SwiftUI
import CockpitShared
import SessionsKit

/// The day's latest sessions, title and cost, each opening its transcript.
struct TodaySessionsCard: View {
    @Environment(CockpitStore.self) private var store
    let sessions: [SessionRef]
    let loaded: Bool

    static let maximumRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.violet)
                SectionLabel(text: String(localized: "Today's sessions"))
                Spacer(minLength: 0)
            }
            if store.sessionsState.isUnauthorized {
                AccessRequiredBanner(message: String(localized: "the transcripts cannot be read."))
            } else if let message = store.sessionsState.errorMessage {
                SourceBanner(
                    kind: .info,
                    message: String(localized: "Sessions index unavailable: \(message)", locale: AppFormat.locale),
                    action: { Task { await store.indexSessions() } },
                    actionTitle: String(localized: "Reindex"))
            } else if !loaded || (sessions.isEmpty && store.sessionIndex.isRunning) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.sessionIndex.isRunning
                        ? String(localized: "Indexing transcripts…")
                        : String(localized: "Reading today's sessions…"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                }
            } else if sessions.isEmpty {
                Text("No sessions since midnight.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions.prefix(Self.maximumRows)) { session in
                        row(session)
                    }
                }
                costFooter
                if sessions.count > Self.maximumRows {
                    Button(String(localized: "All \(sessions.count) sessions today", locale: AppFormat.locale)) {
                        store.showSessions(day: Date())
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        }
    }

    private func row(_ session: SessionRef) -> some View {
        Button {
            store.showSessions(selecting: session.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: session.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(verbatim: cost(session))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.slate)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: session.title))
        .accessibilityLabel(session.title)
        .accessibilityValue(cost(session))
        .accessibilityHint(String(localized: "Opens the session"))
    }

    /// Recorded where the transcript has it, priced from the tokens otherwise, a dash when
    /// neither exists: a missing cost is never shown as zero.
    private func cost(_ session: SessionRef) -> String {
        store.sessionCost(session).map { store.money($0.usd) } ?? "—"
    }

    /// What these sessions cost in full — including what they spent before midnight, which is
    /// why it can differ from Today's cost — and how many have no cost to add.
    @ViewBuilder
    private var costFooter: some View {
        let costs = sessions.compactMap { store.sessionCost($0)?.usd }
        let missing = sessions.count - costs.count
        VStack(alignment: .leading, spacing: 2) {
            // Every session lacking its cost: a total would be a fabricated zero.
            if !costs.isEmpty {
                TileCaption(text: String(localized: "Full cost of these sessions: \(store.money(costs.reduce(0, +)))", locale: AppFormat.locale))
            }
            if missing > 0 {
                TileCaption(text: String(localized: "\(missing) without a recorded cost", locale: AppFormat.locale))
            }
        }
        .padding(.top, 2)
    }
}
