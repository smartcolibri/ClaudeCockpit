import SwiftUI
import CockpitShared
import UsageKit

/// Local usage dashboard: everything read from `~/.claude/projects` transcripts, aggregated by
/// UsageKit. One rule: the whole screen follows `store.usageFilters` (models, project,
/// period); today-versus-yesterday comparisons live on the Overview.
struct UsageView: View {
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                UsageDashboard(width: geometry.size.width)
            }
        }
        .background(Theme.background)
    }
}

/// The screen's content at a given width, with no `GeometryReader` of its own, so a snapshot
/// can host it at its full height. Below `wideLayout` points the two-card rows stack and the
/// four tiles go two by two.
struct UsageDashboard: View {
    @Environment(CockpitStore.self) private var store
    let width: CGFloat
    /// Only the snapshot pins the width; on screen the content fills what the scroll view
    /// leaves, which a permanent scroll bar narrows.
    var pinsWidth = false

    static let wideLayout: CGFloat = 900
    static let horizontalPadding: CGFloat = 20
    static let spacing: CGFloat = 12

    private var wide: Bool { width >= Self.wideLayout }
    private var contentWidth: CGFloat { max(0, width - 2 * Self.horizontalPadding) }

    var body: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: Self.spacing) {
            header
            UsageFilterBar(
                filters: $store.usageFilters,
                availableFamilies: store.usage?.availableModelFamilies ?? [],
                availableProjects: store.usage?.availableProjects ?? [])
            if let usage = store.usage, usage.filteredEventCount == 0, !store.usageState.showsBanner {
                placeholder
            } else {
                tiles
                UsagePeriodChartCard()
                SectionLabel(text: String(localized: "Breakdown")).padding(.top, 6)
                row(ModelMixCard(), BreakdownBarsCard(), leading: 0.4)
                SectionLabel(text: String(localized: "Rhythm over the period")).padding(.top, 6)
                row(CostByHourCard(), SessionsByWeekdayCard(), leading: 0.6)
                if let usage = store.usage {
                    UsageSessionsList(sessions: usage.sessions, money: { store.money($0) })
                        .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 16)
        .frame(width: pinsWidth ? width : nil, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Local Usage").font(.display(22, weight: .bold))
            Text(updatedLabel).font(.system(size: 12)).foregroundStyle(Theme.slate)
            Spacer(minLength: 12)
            if store.usageState.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await store.refreshUsage(rescan: true) }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(store.usageState.isLoading)
            .help("Read every transcript in ~/.claude/projects again")
        }
    }

    private var updatedLabel: String {
        guard let date = store.usageLastScan else { return String(localized: "Scanning transcripts…") }
        return String(localized: "Updated \(AppFormat.relative(date))", locale: AppFormat.locale)
    }

    // MARK: Rows

    private var tiles: some View {
        Group {
            if wide {
                HStack(alignment: .top, spacing: Self.spacing) {
                    UsageCostTile()
                    UsageSessionsTile()
                    UsageTurnsTile()
                    UsageTokensTile()
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: Self.spacing) {
                    HStack(alignment: .top, spacing: Self.spacing) {
                        UsageCostTile()
                        UsageTokensTile()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: Self.spacing) {
                        UsageSessionsTile()
                        UsageTurnsTile()
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Two cards side by side at equal height, the first taking `leading` of the width; stacked
    /// when narrow.
    @ViewBuilder
    private func row<A: View, B: View>(_ first: A, _ second: B, leading: CGFloat) -> some View {
        if wide {
            let available = contentWidth - Self.spacing
            HStack(alignment: .top, spacing: Self.spacing) {
                first.frame(width: (available * leading).rounded())
                second
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            first
            second
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.mist)
            Text("No usage in this period")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Widen the period or remove the project filter to see more activity.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .card()
    }
}
