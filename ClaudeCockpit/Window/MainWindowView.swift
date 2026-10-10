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
                Section("Dashboard") {
                    row(.overview); row(.usage); row(.sessions); row(.rtk)
                }
                Section("Workshop") {
                    row(.skills); row(.agents); row(.commands)
                }
                Section {
                    row(.settings)
                }
            }
            .modifier(SidebarStyle())
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            // A stack rather than a safe-area inset: the split views (RTK, resources) are
            // AppKit-backed and would draw under an inset.
            VStack(spacing: 0) {
                if store.isDemo {
                    DemoBanner {
                        store.exitDemo()
                        sectionRaw = CockpitSection.overview.rawValue
                    }
                }
                detail(for: selection.wrappedValue ?? .overview)
            }
            .frame(minWidth: 860, minHeight: 640)
            .background(Theme.background)
        }
        .navigationTitle(Self.windowTitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh all sources")
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
                NoAccessView(title: String(localized: "Local Usage"), message: String(localized: "Usage is computed from the transcripts in \(claude)/projects, which the app is not allowed to read."))
            }
        case .sessions:
            if store.claudeAccess { SessionsView() } else {
                NoAccessView(title: String(localized: "Sessions"), message: String(localized: "Sessions are indexed from the transcripts in \(claude)/projects, which the app is not allowed to read."))
            }
        case .rtk:
            if store.rtkAccess { RTKView() } else {
                NoAccessView(title: "RTK", message: String(localized: "The RTK database (~/Library/Application Support/rtk or ~/.local/share/rtk) is outside the allowed folders. Allow your home folder, or choose the database in Settings › RTK."))
            }
        case .skills, .agents, .commands:
            if store.claudeAccess { ResourcesView(kind: section.resourceKind ?? .skill) } else {
                NoAccessView(title: section.title, message: String(localized: "Resources are read from \(claude), which the app is not allowed to read."))
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

/// Shown above every section while the demo runs, with the way back to the user's data.
private struct DemoBanner: View {
    let exit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill").foregroundStyle(Theme.accent)
            Text("Demo mode — sample data").font(.system(size: 12, weight: .semibold))
            Text("Made-up projects, sessions and statistics to explore the app.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.slate)
                .lineLimit(1)
            Spacer()
            Button("Exit Demo", action: exit).controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.12))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
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
