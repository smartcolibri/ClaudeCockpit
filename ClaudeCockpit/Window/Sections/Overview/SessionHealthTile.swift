import SwiftUI
import CockpitShared
import SessionsKit

/// Today's mean health score with the week's for context, how many sessions hit errors and
/// how many scored low. Leads to the browser filtered on sessions with errors.
struct SessionHealthTile: View {
    @Environment(CockpitStore.self) private var store
    let today: [SessionRef]
    let week: [SessionRef]
    let loaded: Bool

    /// Grades D and F: the score bands the browser's badge already marks as poor.
    static let lowScore = 60

    static func mean(_ sessions: [SessionRef]) -> Int? {
        guard !sessions.isEmpty else { return nil }
        return Int((Double(sessions.reduce(0) { $0 + $1.healthScore }) / Double(sessions.count)).rounded())
    }

    private var withErrors: Int { today.filter(\.hasErrors).count }
    private var lowScored: Int { today.filter { $0.healthScore < Self.lowScore }.count }

    var body: some View {
        OverviewTile(
            title: String(localized: "Session health"),
            icon: "heart.text.square.fill",
            tint: tint,
            summary: summary,
            destination: CockpitSection.sessions.title,
            action: { store.showSessions(withErrorsOnly: true) }
        ) {
            TileSource(
                state: store.sessionsState, ready: loaded,
                unauthorized: String(localized: "the transcripts cannot be read."),
                retry: { Task { await store.indexSessions() } }
            ) {
                content
            }
        }
    }

    private var tint: Color {
        guard let score = Self.mean(today) else { return Theme.slate }
        return score >= 90 ? Theme.emerald : score >= Self.lowScore ? .orange : .red
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let score = Self.mean(today) {
                TileValue(text: AppFormat.integer(score), tint: tint, suffix: "/100")
            } else {
                TileValue(text: "—", tint: Theme.slate)
            }
            if let week = Self.mean(week) {
                TileCaption(text: String(localized: "7 days: \(AppFormat.integer(week))/100", locale: AppFormat.locale))
            }
            TileCaption(text: today.isEmpty
                ? String(localized: "No sessions since midnight.")
                : String(localized: "With errors: \(withErrors) · below \(Self.lowScore): \(lowScored)", locale: AppFormat.locale))
        }
    }

    private var summary: String {
        guard loaded else { return "" }
        var parts: [String] = []
        if let score = Self.mean(today) { parts.append(String(localized: "Today \(AppFormat.integer(score))/100", locale: AppFormat.locale)) }
        if let week = Self.mean(week) { parts.append(String(localized: "7 days: \(AppFormat.integer(week))/100", locale: AppFormat.locale)) }
        if !today.isEmpty {
            parts.append(String(localized: "With errors: \(withErrors) · below \(Self.lowScore): \(lowScored)", locale: AppFormat.locale))
        }
        return parts.joined(separator: ", ")
    }
}
