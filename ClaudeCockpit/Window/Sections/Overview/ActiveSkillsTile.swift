import SwiftUI
import CockpitShared
import SkillsKit

/// Skills active for every project, with the total across levels and the installed plugins.
struct ActiveSkillsTile: View {
    @Environment(CockpitStore.self) private var store

    var body: some View {
        OverviewTile(
            title: String(localized: "Active skills"),
            icon: "sparkles",
            tint: Theme.violet,
            summary: summary,
            destination: CockpitSection.skills.title,
            action: { store.show(.skills) }
        ) {
            TileSource(
                state: store.skillsState, ready: store.skills != nil,
                unauthorized: String(localized: "the Claude folder cannot be read."),
                retry: { Task { await store.refreshSkills() } }
            ) {
                if let skills = store.skills {
                    VStack(alignment: .leading, spacing: 4) {
                        TileValue(text: AppFormat.integer(skills.count(kind: .skill, level: .global)), tint: Theme.violet)
                        TileCaption(text: String(localized: "\(AppFormat.integer(skills.count(kind: .skill))) in total, all levels", locale: AppFormat.locale))
                        TileCaption(text: String(localized: "\(skills.plugins.count) plugins", locale: AppFormat.locale))
                    }
                }
            }
        }
    }

    private var summary: String {
        guard let skills = store.skills else { return "" }
        return [AppFormat.integer(skills.count(kind: .skill, level: .global)),
                String(localized: "\(AppFormat.integer(skills.count(kind: .skill))) in total, all levels", locale: AppFormat.locale),
                String(localized: "\(skills.plugins.count) plugins", locale: AppFormat.locale)].joined(separator: ", ")
    }
}
