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
                    Text("Bienvenue dans Cockpit for Claude").font(.display(24, weight: .bold))
                    Text("Une autorisation est nécessaire avant d'afficher vos données.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.slate)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Pourquoi cet accès ?").font(.system(size: 14, weight: .semibold))
                    explanation("Cockpit for Claude lit ce que Claude Code enregistre dans \(store.displayPath(store.paths.claudeDir)) : transcripts des sessions, skills, agents et commandes.")
                    explanation("macOS isole les apps du Mac App Store : elles ne voient que les dossiers que vous leur ouvrez explicitement.")
                    explanation("Le dossier \(store.displayPath(store.paths.claudeDir)) est seulement lu. Seuls les transferts de skills que vous lancez vous-même y écrivent, après une sauvegarde dans \(store.displayPath(store.paths.backupsDir)).")
                    explanation("Rien ne quitte votre Mac : l'app n'a pas accès au réseau.")
                }
                .padding(18)
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        handle(store.requestAccess(.home))
                    } label: {
                        Label("Autoriser l'accès à mon dossier personnel", systemImage: "house.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Text("Recommandé. Couvre \(store.displayPath(store.paths.claudeDir)), les skills liés ailleurs dans votre dossier (par exemple ~/.agents), la base RTK et l'analyse de vos dossiers de projets. Dans la fenêtre qui s'ouvre, votre dossier personnel est déjà sélectionné : cliquez sur « Autoriser ».")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button("Autoriser seulement \(store.displayPath(store.paths.claudeDir))") {
                        handle(store.requestAccess(.claudeOnly))
                    }
                    Text("Usage, sessions, skills, agents et commandes fonctionnent. Restent indisponibles : les skills liés hors de \(store.displayPath(store.paths.claudeDir)), les statistiques RTK et l'analyse des dossiers de projets. Vous pourrez élargir l'accès dans Réglages › Accès.")
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

    private func explanation(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.emerald).font(.system(size: 11))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func handle(_ result: CockpitStore.AccessRequestResult) {
        switch result {
        case .cancelled: feedback = nil
        case .rejected(let message): feedback = message
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
            Text("Accès non autorisé").font(.system(size: 15, weight: .semibold))
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Button("Autoriser l'accès à mon dossier personnel…") { store.requestAccess(.home) }
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
            message: "Accès non autorisé : \(message)",
            action: { store.requestAccess(.home) },
            actionTitle: "Autoriser…")
    }
}
