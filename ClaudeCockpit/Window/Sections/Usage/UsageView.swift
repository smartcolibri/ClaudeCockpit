import SwiftUI
import CockpitShared
import UsageKit

/// Local usage dashboard: everything read from `~/.claude/projects` transcripts, aggregated by
/// UsageKit and filtered through `store.usageFilters`.
struct UsageView: View {
    @Environment(CockpitStore.self) private var store

    private let cardColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        @Bindable var store = store
        let money: (Double) -> String = { store.money($0) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = store.usageState.errorMessage {
                    SourceBanner(
                        kind: .error,
                        message: String(localized: "Could not read the usage: \(message). No transcripts found in ~/.claude/projects?"),
                        action: { Task { await store.refreshUsage(rescan: true) } },
                        actionTitle: String(localized: "Rescan"))
                }
                UsageFilterBar(
                    filters: $store.usageFilters,
                    availableFamilies: store.usage?.availableModelFamilies ?? [],
                    availableProjects: store.usage?.availableProjects ?? [])
                content(money: money)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Local Usage")
                    .font(.display(22))
                    .foregroundStyle(Theme.ink)
                Text(updatedLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
            }
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
        return String(localized: "Updated \(AppFormat.relative(date))")
    }

    // MARK: Body states

    @ViewBuilder
    private func content(money: @escaping (Double) -> String) -> some View {
        if let usage = store.usage, usage.filteredEventCount > 0 {
            dashboard(usage, money: money)
        } else if store.usage == nil && store.usageState.errorMessage == nil {
            placeholder(
                icon: "hourglass",
                title: "Reading transcripts…",
                message: "First scan of ~/.claude/projects; this can take a few seconds.")
        } else if store.usageState.errorMessage == nil {
            placeholder(
                icon: "tray",
                title: "No usage in this period",
                message: "Widen the period or remove the project filter to see more activity.")
        }
    }

    private func placeholder(icon: String, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.mist)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.slate)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .panelStyle()
    }

    private func dashboard(_ usage: UsageSnapshot, money: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageStatGrid(totals: usage.totals, range: usage.filters.range, money: money)
            LazyVGrid(columns: cardColumns, spacing: 16) {
                SessionsPerWeekCard(
                    lastWeek: usage.sessionsLastWeekByWeekday,
                    thisWeek: usage.sessionsThisWeekByWeekday,
                    lastWeekTotal: usage.sessionsLastWeekTotal,
                    thisWeekTotal: usage.sessionsThisWeekTotal)
                CostPerHourCard(
                    yesterday: usage.hourlyYesterday,
                    today: usage.hourlyToday,
                    money: money)
                UsageInsightsCard(insights: usage.insights)
                ModelMixCard(rows: usage.costByFamily, money: money)
            }
            DailyUsageChartCard(daily: usage.daily, range: usage.filters.range, money: money)
            UsageBreakdownTable(snapshot: usage, money: money)
            UsageSessionsList(sessions: usage.sessions, money: money)
        }
    }
}
