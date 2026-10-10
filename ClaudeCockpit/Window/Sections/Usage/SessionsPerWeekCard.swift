import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// "This week vs last week", one point per weekday. Last week is context (mist),
/// this week is the emphasis series. Independent of the range filter: a week-over-week
/// comparison against an arbitrary range would mean nothing.
struct SessionsPerWeekCard: View {
    let lastWeek: [Int] // 7 values, Monday...Sunday
    let thisWeek: [Int] // 7 values, Monday...Sunday
    /// Distinct sessions over each week. Deliberately not `lastWeek.reduce(0, +)`: the
    /// per-weekday values dedupe within a day, so a session spanning midnight counts twice.
    let lastWeekTotal: Int
    let thisWeekTotal: Int

    /// Monday first, in the app's language.
    private static let weekdays: [String] = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppFormat.locale
        let symbols = calendar.shortWeekdaySymbols
        return Array(symbols.dropFirst()) + symbols.prefix(1)
    }()
    private static let lastWeekSeries = String(localized: "Last week")
    private static let thisWeekSeries = String(localized: "This week")

    private struct Point: Identifiable {
        let weekday: String
        let index: Int
        let value: Int
        let series: String
        var id: String { "\(series)-\(index)" }
    }

    private func value(_ values: [Int], _ index: Int) -> Int {
        index < values.count ? values[index] : 0
    }

    private var points: [Point] {
        Self.weekdays.indices.flatMap { i in
            [
                Point(weekday: Self.weekdays[i], index: i, value: value(lastWeek, i), series: Self.lastWeekSeries),
                Point(weekday: Self.weekdays[i], index: i, value: value(thisWeek, i), series: Self.thisWeekSeries),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: String(localized: "Sessions per week"))
                Spacer()
                legendChip(Self.lastWeekSeries, color: UsagePalette.context)
                legendChip(Self.thisWeekSeries, color: Theme.blue)
            }
            Chart(points) { point in
                LineMark(
                    x: .value("Day", point.weekday),
                    y: .value("Sessions", point.value))
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale([
                Self.lastWeekSeries: UsagePalette.context,
                Self.thisWeekSeries: Theme.blue,
            ])
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.cardStroke)
                    AxisValueLabel().foregroundStyle(Theme.slate)
                }
            }
            .chartXAxis {
                AxisMarks { AxisValueLabel().foregroundStyle(Theme.slate) }
            }
            .frame(minHeight: 160)
            HStack(alignment: .bottom) {
                total(Self.lastWeekSeries, lastWeekTotal, color: Theme.ink)
                Spacer()
                total(Self.thisWeekSeries, thisWeekTotal, color: Theme.blue, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelStyle()
    }

    private func legendChip(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.slate)
        }
    }

    private func total(
        _ label: String,
        _ value: Int,
        color: Color,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            SectionLabel(text: label)
            Text(AppFormat.integer(value))
                .font(.display(20))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
