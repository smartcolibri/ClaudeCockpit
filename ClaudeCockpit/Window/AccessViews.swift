import SwiftUI
import CockpitShared

/// First-launch screen of the sandboxed app, shown in place of the overview until
/// the Claude config directory is covered by a grant.
struct OnboardingView: View {
    @Environment(CockpitStore.self) private var store
    @State private var feedback: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Cockpit for Claude").font(.display(24, weight: .bold))
                    Text("Permission is needed before your data can be shown.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.slate)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Why this access?").font(.system(size: 14, weight: .semibold))
                    explanation("Cockpit for Claude reads what Claude Code saves in \(store.displayPath(store.paths.claudeDir)): session transcripts, skills, agents and commands.")
                    explanation("macOS isolates Mac App Store apps: they only see the folders you explicitly open to them.")
                    explanation("The folder \(store.displayPath(store.paths.claudeDir)) is only read. Only the skill transfers you start yourself write to it, after a backup in \(store.displayPath(store.paths.backupsDir)).")
                    explanation("Nothing leaves your Mac: the app has no network access.")
                }
                .padding(18)
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        handle(store.requestAccess(.home))
                    } label: {
                        Label("Allow Access to My Home Folder", systemImage: "house.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Text("Recommended. Covers \(store.displayPath(store.paths.claudeDir)), skills linked elsewhere in your folder (for example ~/.agents), the RTK database and the scan of your project folders. In the window that opens, your home folder is already selected: click “Allow”.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button("Allow Only \(store.displayPath(store.paths.claudeDir))") {
                        handle(store.requestAccess(.claudeOnly))
                    }
                    Text("Usage, sessions, skills, agents and commands work. Still unavailable: skills linked outside \(store.displayPath(store.paths.claudeDir)), RTK statistics and the scan of project folders. You can widen the access in Settings › Access.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        store.enterDemo()
                    } label: {
                        Label("Explore with Sample Data", systemImage: "play.rectangle")
                    }
                    Text("Three made-up projects with sessions, RTK statistics and skills, to explore the app without allowing any folder. Your own data is neither read nor changed.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let feedback {
                    SourceBanner(kind: .warning, message: feedback)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }

    private func explanation(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.emerald).font(.system(size: 11))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func handle(_ result: CockpitStore.AccessRequestResult) {
        switch result {
        case .cancelled: feedback = nil
        case .rejected(let message): feedback = message
        // A partial grant replaces this screen with the overview; the store's notice says
        // what stays unavailable.
        case .granted: feedback = nil
        }
    }
}

/// What a section shows when the grants do not cover its source.
struct NoAccessView: View {
    @Environment(CockpitStore.self) private var store
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.mist)
            Text("Access Not Granted").font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Button("Allow Access to My Home Folder…") { store.requestAccess(.home) }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

/// Inline version for cards and the menu-bar panel.
struct AccessRequiredBanner: View {
    @Environment(CockpitStore.self) private var store
    let message: String

    var body: some View {
        SourceBanner(
            kind: .warning,
            message: String(localized: "Access not granted: \(message)", locale: AppFormat.locale),
            action: { store.requestAccess(.home) },
            actionTitle: String(localized: "Allow…"))
    }
}
