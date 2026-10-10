import SwiftUI

struct MainWindowView: View {
    static let windowID = "main"
    /// Also how the AppKit side finds this window (`NSWindow.title`).
    static let windowTitle = "Cockpit for Claude"
    @Environment(CockpitStore.self) private var store
    @AppStorage(SettingsKey.mainSection) private var sectionRaw: String = CockpitSection.overview.rawValue

    private var selection: Binding<CockpitSection?> {
        Binding(
            get: { CockpitSection(rawValue: sectionRaw) ?? .overview },
            set: { sectionRaw = ($0 ?? .overview).rawValue })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("Tableau de bord") {
                    row(.overview); row(.usage); row(.sessions); row(.rtk)
                }
                Section("Atelier") {
                    row(.skills); row(.agents); row(.commands)
                }
                Section {
                    row(.settings)
                }
            }
            .modifier(SidebarStyle())
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail(for: selection.wrappedValue ?? .overview)
                .frame(minWidth: 860, minHeight: 640)
                .background(Theme.background)
        }
        .navigationTitle(Self.windowTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Rafraîchir", systemImage: "arrow.clockwise")
                }
                .help("Rafraîchir toutes les sources")
            }
        }
        .overlay(alignment: .bottom) { NoticeToast() }
        .task {
            await SnapshotRunner.runIfRequested(store: store) { sectionRaw = $0.rawValue }
        }
    }

    private func row(_ section: CockpitSection) -> some View {
        NavigationLink(value: section) {
            Label(section.title, systemImage: section.icon)
        }
    }

    @ViewBuilder
    private func detail(for section: CockpitSection) -> some View {
        // Under the sandbox a source the grants do not cover shows why, with the way
        // to grant it, rather than an empty screen.
        let claude = store.displayPath(store.paths.claudeDir)
        switch section {
        case .overview:
            if store.claudeAccess { OverviewView() } else { OnboardingView() }
        case .usage:
            if store.claudeAccess { UsageView() } else {
                NoAccessView(title: "Usage local", message: "L'usage est calculé à partir des transcripts de \(claude)/projects, que l'app n'est pas autorisée à lire.")
            }
        case .sessions:
            if store.claudeAccess { SessionsView() } else {
                NoAccessView(title: "Sessions", message: "Les sessions sont indexées à partir des transcripts de \(claude)/projects, que l'app n'est pas autorisée à lire.")
            }
        case .rtk:
            if store.rtkAccess { RTKView() } else {
                NoAccessView(title: "RTK", message: "La base de RTK (~/Library/Application Support/rtk ou ~/.local/share/rtk) est hors des dossiers autorisés. Autorisez votre dossier personnel, ou choisissez la base dans Réglages › RTK.")
            }
        case .skills, .agents, .commands:
            if store.claudeAccess { ResourcesView(kind: section.resourceKind ?? .skill) } else {
                NoAccessView(title: section.title, message: "Les ressources sont lues dans \(claude), que l'app n'est pas autorisée à lire.")
            }
        case .settings: SettingsView()
        }
    }
}

/// The vibrant sidebar material cannot be rendered by in-process snapshots, so
/// the snapshot mode falls back to a flat list on a solid background.
private struct SidebarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if SnapshotRunner.requestedDirectory != nil {
            content.listStyle(.plain).scrollContentBackground(.hidden).background(Theme.panel)
        } else {
            content.listStyle(.sidebar)
        }
    }
}

/// Transient bottom toast for `store.notice`.
struct NoticeToast: View {
    @Environment(CockpitStore.self) private var store
    var body: some View {
        if let notice = store.notice {
            Text(notice)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.notice == notice { store.notice = nil }
                }
        }
    }
}
