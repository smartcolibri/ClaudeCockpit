import AppKit
import SwiftUI
import CockpitShared

/// The menu-bar panel: two collapsible sections (today, RTK savings) and the
/// action footer. Ported from ClaudeMenu's `UsagePanelView` onto the cockpit store.
struct MenuBarPanelView: View {
    /// `false` renders the content without a scroll container. Used only by
    /// `PanelSizer`, which cannot lay out a `ScrollView`.
    var scrolls = true

    @Environment(CockpitStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @AppStorage(SettingsKey.panelSectionToday) private var showToday = true
    @AppStorage(SettingsKey.panelSectionSavings) private var showSavings = true

    /// The panel's natural height, measured through AppKit (see `remeasure`).
    @State private var contentHeight: CGFloat = 0
    @State private var isRefreshing = false
    @State private var now = Date()

    // MARK: Derived

    /// Hidden only when rtk has nothing to say and its source failed.
    private var showsSavingsSection: Bool {
        !(store.rtk == nil && store.rtkState.errorMessage != nil)
    }

    // MARK: Height

    /// The popover must fit under the menu bar whatever sections are open, and the
    /// cockpit keeps it deliberately shorter than the full strip: past ~720 pt the
    /// panel stops being a glance and the main window is the better place.
    private var maxHeight: CGFloat {
        let usable = (NSScreen.main?.visibleFrame.height ?? 800) - 24
        if SnapshotRunner.requestedDirectory != nil { return 1400 }   // full panel in screenshots
        return max(320, min(720, usable))
    }
    /// Never zero: a zero measurement would collapse the popover entirely, so an
    /// unmeasured panel falls back to a plausible height and scrolls.
    private var resolvedHeight: CGFloat {
        min(contentHeight > 0 ? contentHeight : Self.fallbackHeight, maxHeight)
    }
    private static let fallbackHeight: CGFloat = 560

    /// Re-measures a non-scrolling copy. The store has to be re-injected: the copy
    /// is built from scratch.
    private func remeasure() {
        contentHeight = PanelSizer.naturalHeight(
            of: MenuBarPanelView(scrolls: false).environment(store))
    }

    /// Everything that changes how tall the panel wants to be. Text that merely gets
    /// longer is not tracked: the scroll view absorbs a few points. Each entry flips
    /// at most a handful of times per run — a signature that churned on every refresh
    /// would re-host and re-lay out the whole panel behind the scenes each time.
    private var layoutSignature: String {
        [
            showToday.description, showSavings.description,
            showsSavingsSection.description,
            (store.usage != nil).description,
            (store.usageState.errorMessage != nil).description,
            store.usageState.isUnauthorized.description,
            store.rtkState.isUnauthorized.description,
        ].joined(separator: "|")
    }

    // MARK: Body

    var body: some View {
        if scrolls {
            ScrollView(.vertical) { content }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: Theme.panelWidth, height: resolvedHeight)
                .onAppear {
                    store.openWindowHandler = { openWindow(id: MainWindowView.windowID) }
                    store.start()
                    now = Date()
                    remeasure()
                }
                .onChange(of: layoutSignature) { _, _ in remeasure() }
        } else {
            content.frame(width: Theme.panelWidth)
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            todaySection
            if showsSavingsSection { savingsSection }
            footer
        }
        .padding(10)
    }

    // MARK: Sections

    private var todaySection: some View {
        DisclosureCard(
            title: "Aujourd'hui",
            icon: "text.alignleft",
            iconColor: Theme.violet,
            expanded: $showToday
        ) {
            if let usage = store.usage {
                InfoRow(label: "Coût local du jour", value: store.money(usage.costTodayUnfilteredUSD), tint: Theme.blue)
                Divider().opacity(0.4)
                InfoRow(
                    label: "Tokens du jour", value: FRFormat.tokens(usage.tokensTodayUnfiltered),
                    note: "entrée + sortie + cache, tous modèles confondus")
                Divider().opacity(0.4)
                InfoRow(
                    label: "Sessions cette semaine", value: FRFormat.integer(usage.sessionsThisWeekUnfilteredTotal),
                    note: "\(FRFormat.integer(usage.sessionsLastWeekUnfilteredTotal)) la semaine précédente")
            } else if store.usageState.isUnauthorized {
                AccessRequiredBanner(message: "ouvrez le cockpit pour autoriser la lecture de vos transcripts.")
                    .padding(.vertical, 6)
            } else if let message = store.usageState.errorMessage {
                SourceBanner(kind: .error, message: message, action: { Task { await store.refreshUsage() } })
                    .padding(.vertical, 6)
            } else {
                InfoRow(label: "Lecture des transcripts", value: "en cours…")
            }
        }
    }

    private var savingsSection: some View {
        DisclosureCard(
            title: "Économies RTK",
            icon: "scissors",
            iconColor: Theme.emerald,
            expanded: $showSavings
        ) {
            if let rtk = store.rtk {
                let week = rtk.last7Days.reduce(0) { $0 + $1.savedTokens }
                InfoRow(
                    label: "Tokens économisés aujourd'hui", value: FRFormat.tokens(rtk.today.savedTokens),
                    tint: Theme.emerald,
                    note: "\(FRFormat.percent(rtk.today.savingsPct, fraction: false, digits: 1)) de \(FRFormat.tokens(rtk.today.inputTokens)) tokens, sur \(FRFormat.integer(rtk.today.count)) commandes filtrées")
                Divider().opacity(0.4)
                InfoRow(
                    label: "Sur 7 jours", value: FRFormat.tokens(week),
                    note: "cumul des sept derniers jours")
                Divider().opacity(0.4)
                InfoRow(
                    label: "Depuis l'installation", value: FRFormat.tokens(rtk.allTime.savedTokens),
                    note: "\(FRFormat.percent(rtk.allTime.savingsPct, fraction: false, digits: 1)) économisés sur \(FRFormat.integer(rtk.allTime.count)) commandes")
            } else if store.rtkState.isUnauthorized {
                InfoRow(
                    label: "Économies rtk", value: "accès non autorisé",
                    note: "base RTK hors des dossiers autorisés (Réglages › Accès)")
            } else {
                InfoRow(
                    label: "Économies rtk", value: "aucune donnée",
                    note: "rtk n'a encore rien enregistré")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                store.openMainWindow()
            } label: {
                ActionRow(
                    icon: "macwindow", iconColor: Theme.accent,
                    title: "Ouvrir le cockpit",
                    subtitle: "Usage, sessions, RTK et skills")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().opacity(0.4).padding(.leading, 46)

            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await store.refreshAll()
                    now = Date()
                    isRefreshing = false
                }
            } label: {
                ActionRow(
                    icon: "arrow.clockwise", iconColor: Theme.blue,
                    title: isRefreshing ? "Actualisation en cours…" : "Rafraîchir",
                    subtitle: refreshSubtitle
                ) {
                    if isRefreshing { ProgressView().controlSize(.small) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            Divider().opacity(0.4).padding(.leading, 46)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                ActionRow(icon: "xmark.circle", iconColor: .red, title: "Quitter")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
        .card()
    }

    /// Says when the transcripts were last read.
    private var refreshSubtitle: String {
        guard let scanned = store.usageLastScan else { return "Transcripts jamais lus" }
        return "Transcripts lus \(FRFormat.relative(scanned, now: now))"
    }
}
