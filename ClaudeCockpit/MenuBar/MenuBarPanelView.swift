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
            title: String(localized: "Today"),
            icon: "text.alignleft",
            iconColor: Theme.violet,
            expanded: $showToday
        ) {
            if let usage = store.usage {
                InfoRow(label: String(localized: "Local cost today"), value: store.money(usage.costTodayUnfilteredUSD), tint: Theme.blue)
                Divider().opacity(0.4)
                InfoRow(
                    label: String(localized: "Tokens today"), value: AppFormat.tokens(usage.tokensTodayUnfiltered),
                    note: String(localized: "input + output + cache, all models"))
                Divider().opacity(0.4)
                InfoRow(
                    label: String(localized: "Sessions this week"), value: AppFormat.integer(usage.sessionsThisWeekUnfilteredTotal),
                    note: String(localized: "\(AppFormat.integer(usage.sessionsLastWeekUnfilteredTotal)) last week", locale: AppFormat.locale))
            } else if store.usageState.isUnauthorized {
                AccessRequiredBanner(message: String(localized: "open the cockpit to allow reading your transcripts."))
                    .padding(.vertical, 6)
            } else if let message = store.usageState.errorMessage {
                SourceBanner(kind: .error, message: message, action: { Task { await store.refreshUsage() } })
                    .padding(.vertical, 6)
            } else {
                InfoRow(label: String(localized: "Reading transcripts"), value: String(localized: "in progress…"))
            }
        }
    }

    private var savingsSection: some View {
        DisclosureCard(
            title: String(localized: "RTK Savings"),
            icon: "scissors",
            iconColor: Theme.emerald,
            expanded: $showSavings
        ) {
            if let rtk = store.rtk {
                let week = rtk.last7Days.reduce(0) { $0 + $1.savedTokens }
                InfoRow(
                    label: String(localized: "Tokens saved today"), value: AppFormat.tokens(rtk.today.savedTokens),
                    tint: Theme.emerald,
                    note: String(localized: "\(AppFormat.percent(rtk.today.savingsPct, fraction: false, digits: 1)) of \(AppFormat.tokens(rtk.today.inputTokens)) tokens, across \(String(localized: "\(rtk.today.count) filtered commands", locale: AppFormat.locale))"))
                Divider().opacity(0.4)
                InfoRow(
                    label: String(localized: "Last 7 days"), value: AppFormat.tokens(week),
                    note: String(localized: "total over the last seven days"))
                Divider().opacity(0.4)
                InfoRow(
                    label: String(localized: "Since install"), value: AppFormat.tokens(rtk.allTime.savedTokens),
                    note: String(localized: "\(AppFormat.percent(rtk.allTime.savingsPct, fraction: false, digits: 1)) saved across \(String(localized: "\(rtk.allTime.count) commands", locale: AppFormat.locale))"))
            } else if store.rtkState.isUnauthorized {
                InfoRow(
                    label: String(localized: "RTK savings"), value: String(localized: "access not granted"),
                    note: String(localized: "RTK database outside the allowed folders (Settings › Access)"))
            } else {
                InfoRow(
                    label: String(localized: "RTK savings"), value: String(localized: "no data"),
                    note: String(localized: "rtk has not recorded anything yet"))
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
                    title: String(localized: "Open Cockpit"),
                    subtitle: String(localized: "Usage, sessions, RTK and skills"))
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
                    title: isRefreshing ? String(localized: "Refreshing…") : String(localized: "Refresh"),
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
                ActionRow(icon: "xmark.circle", iconColor: .red, title: String(localized: "Quit"))
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
        guard let scanned = store.usageLastScan else { return String(localized: "Transcripts never read") }
        return String(localized: "Transcripts read \(AppFormat.relative(scanned, now: now))", locale: AppFormat.locale)
    }
}
