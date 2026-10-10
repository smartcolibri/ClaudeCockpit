import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// Mean cost per hour of day over the period: which hours the spend gathers in.
struct CostByHourCard: View {
    @Environment(CockpitStore.self) private var store
    @State private var hovered: String?

    static let chartHeight: CGFloat = 110

    var body: some View {
        UsageCard(title: String(localized: "Mean cost per hour of day"), icon: "clock.fill") {
            UsageSource { usage in
                let period = usage.period
                VStack(alignment: .leading, spacing: 8) {
                    chart(period)
                    TileCaption(text: caption(period))
                }
            }
        }
    }

    private func chart(_ period: UsagePeriod) -> some View {
        let means = period.meanCostPerHour
        let total = period.hourly.reduce(0) { $0 + $1.estimatedCostUSD }
        return Chart {
            ForEach(0..<24, id: \.self) { hour in
                BarMark(x: .value("Hour", String(hour)), y: .value("Cost", means[hour]), width: .ratio(0.7))
                    .foregroundStyle(Theme.blue.opacity(hovered == nil || hovered == String(hour) ? 1 : 0.5))
            }
            if let key = hovered, let hour = Int(key), (0..<24).contains(hour) {
                RuleMark(x: .value("Hour", key))
                    .foregroundStyle(Theme.slate.opacity(0.18))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartTooltip(lines: [
                            "\(AppFormat.hour(hour)) – \(AppFormat.hour((hour + 1) % 24))",
                            String(localized: "\(store.money(means[hour])) per day on average", locale: AppFormat.locale),
                            String(localized: "\(AppFormat.percent(total > 0 ? period.hourly[hour].estimatedCostUSD / total : 0)) of the cost", locale: AppFormat.locale),
                        ])
                    }
            }
        }
        .chartXScale(domain: (0..<24).map(String.init))
        .chartXAxis {
            // Blank labels rather than `values:`, which a categorical axis ignores.
            AxisMarks { value in
                AxisValueLabel(centered: true) {
                    if let key = value.as(String.self), let hour = Int(key), hour % 6 == 0 {
                        Text(verbatim: AppFormat.hour(hour)).foregroundStyle(Theme.slate)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartHover(String.self) { hovered = $0 }
        .frame(height: Self.chartHeight)
        .accessibilityLabel(String(localized: "Mean cost per hour of day"))
        .accessibilityValue(caption(period))
    }

    private func caption(_ period: UsagePeriod) -> String {
        guard let peak = period.peakHour else { return String(localized: "No spend in this period.") }
        return String(localized: "Peak: \(AppFormat.hour(peak))–\(AppFormat.hour((peak + 1) % 24)) · \(AppFormat.percent(period.peakHourShare)) of the cost",
                      locale: AppFormat.locale)
    }
}

/// Sessions per weekday over the period, Monday first. A weekday the period has not reached
/// yet ("this week" on a Wednesday) gets no bar rather than a zero.
struct SessionsByWeekdayCard: View {
    @Environment(CockpitStore.self) private var store
    @State private var hovered: String?

    /// Short and full weekday names in the app's language, Monday first.
    private static let names: [(short: String, full: String)] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppFormat.locale
        let short = calendar.shortStandaloneWeekdaySymbols
        let full = calendar.standaloneWeekdaySymbols
        return (0..<7).map { index in
            let day = (index + 1) % 7
            return (short[day], full[day].localizedCapitalized)
        }
    }()

    var body: some View {
        UsageCard(title: String(localized: "Sessions per weekday"), icon: "calendar", tint: Theme.violet) {
            UsageSource { usage in
                let period = usage.period
                VStack(alignment: .leading, spacing: 8) {
                    chart(period)
                    TileCaption(text: caption(period))
                }
            }
        }
    }

    private func chart(_ period: UsagePeriod) -> some View {
        let names = Self.names
        return Chart {
            ForEach(0..<7, id: \.self) { index in
                if period.weekdayDays[index] > 0 {
                    BarMark(x: .value("Weekday", names[index].short), y: .value("Sessions", period.sessionsByWeekday[index]), width: .ratio(0.6))
                        .foregroundStyle(Theme.violet.opacity(hovered == nil || hovered == names[index].short ? 1 : 0.5))
                }
            }
            if let key = hovered, let index = names.firstIndex(where: { $0.short == key }), period.weekdayDays[index] > 0 {
                RuleMark(x: .value("Weekday", key))
                    .foregroundStyle(Theme.slate.opacity(0.18))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartTooltip(lines: [
                            names[index].full,
                            String(localized: "\(period.sessionsByWeekday[index]) sessions", locale: AppFormat.locale),
                            String(localized: "over \(period.weekdayDays[index]) days", locale: AppFormat.locale),
                        ])
                    }
            }
        }
        .chartXScale(domain: names.map(\.short))
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(centered: true).foregroundStyle(Theme.slate)
            }
        }
        .chartYAxis(.hidden)
        .chartHover(String.self) { hovered = $0 }
        .frame(height: CostByHourCard.chartHeight)
        .accessibilityLabel(String(localized: "Sessions per weekday"))
        .accessibilityValue((0..<7).filter { period.weekdayDays[$0] > 0 }
            .map { "\(names[$0].full) \(period.sessionsByWeekday[$0])" }.joined(separator: ", "))
    }

    private func caption(_ period: UsagePeriod) -> String {
        guard let share = period.weekdayShare else { return String(localized: "No sessions in this period.") }
        return String(localized: "\(AppFormat.percent(share)) on weekdays", locale: AppFormat.locale)
    }
}
