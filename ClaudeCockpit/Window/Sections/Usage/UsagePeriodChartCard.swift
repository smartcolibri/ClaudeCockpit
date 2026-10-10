import SwiftUI
import Charts
import CockpitShared
import UsageKit

/// Cost over the period, one bar per hour, day, week or month (`UsagePeriod.granularity`),
/// stacked by model family; or the same bars in tokens, stacked by kind. Tokens are split by
/// kind rather than by model: the model split is already the cost view's and the donut's,
/// while the kind split is what explains a token total dominated by cache reads.
struct UsagePeriodChartCard: View {
    @Environment(CockpitStore.self) private var store
    @State private var mode: Mode = .cost
    @State private var hovered: String?

    enum Mode: Hashable { case cost, tokens }

    static let chartHeight: CGFloat = 190

    private struct Point: Identifiable {
        let key: String
        let series: String
        let value: Double
        var id: String { "\(key)-\(series)" }
    }

    var body: some View {
        UsageCard(title: title, icon: "chart.bar.fill") {
            Picker(String(localized: "Chart values"), selection: $mode) {
                Text("Cost").tag(Mode.cost)
                Text("Tokens").tag(Mode.tokens)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            UsageSource { usage in
                VStack(alignment: .leading, spacing: 8) {
                    chart(usage.period)
                    legend(usage)
                }
            }
        }
    }

    // MARK: Title

    private var title: String {
        let granularity = store.usage?.period.granularity ?? .day
        let range = (store.usage?.filters.range ?? store.usageFilters.range).displayName
        switch (mode, granularity) {
        case (.cost, .hour): return String(localized: "Cost per hour — \(range)", locale: AppFormat.locale)
        case (.cost, .day): return String(localized: "Cost per day — \(range)", locale: AppFormat.locale)
        case (.cost, .week): return String(localized: "Cost per week — \(range)", locale: AppFormat.locale)
        case (.cost, .month): return String(localized: "Cost per month — \(range)", locale: AppFormat.locale)
        case (.tokens, .hour): return String(localized: "Tokens per hour — \(range)", locale: AppFormat.locale)
        case (.tokens, .day): return String(localized: "Tokens per day — \(range)", locale: AppFormat.locale)
        case (.tokens, .week): return String(localized: "Tokens per week — \(range)", locale: AppFormat.locale)
        case (.tokens, .month): return String(localized: "Tokens per month — \(range)", locale: AppFormat.locale)
        }
    }

    // MARK: Chart

    private static func key(_ bucket: UsagePeriod.Bucket) -> String { String(bucket.index) }

    private func points(_ buckets: [UsagePeriod.Bucket]) -> [Point] {
        switch mode {
        case .cost:
            buckets.flatMap { bucket in
                ModelFamily.allCases.compactMap { family in
                    bucket.costByFamily[family].map { Point(key: Self.key(bucket), series: family.label, value: $0) }
                }
            }
        case .tokens:
            buckets.flatMap { bucket in
                UsageSeries.allCases.map { Point(key: Self.key(bucket), series: $0.displayName, value: Double(bucket.tokens($0))) }
            }
        }
    }

    private func value(_ bucket: UsagePeriod.Bucket) -> Double {
        mode == .cost ? bucket.costUSD : Double(bucket.totalTokens)
    }

    private func chart(_ period: UsagePeriod) -> some View {
        let buckets = period.buckets
        // Whole units once the scale reaches ten, as on the Overview.
        let digits = (buckets.map(value).max() ?? 0) >= 10 ? 0 : 2
        let hoveredBucket = buckets.first { Self.key($0) == hovered }
        return Chart {
            ForEach(points(buckets)) { point in
                BarMark(x: .value("Period", point.key), y: .value("Value", point.value), width: .ratio(0.72))
                    .foregroundStyle(by: .value("Series", point.series))
                    .opacity(hovered == nil || hovered == point.key ? 1 : 0.5)
            }
            if let bucket = hoveredBucket {
                RuleMark(x: .value("Period", Self.key(bucket)))
                    .foregroundStyle(Theme.slate.opacity(0.18))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartTooltip(lines: tooltip(bucket, period.granularity))
                    }
            }
        }
        .chartForegroundStyleScale(domain: seriesDomain, range: seriesColors)
        .chartLegend(.hidden)
        .chartXScale(domain: buckets.map(Self.key))
        .chartXAxis {
            // On a categorical axis `AxisMarks(values:)` still labels every category: the
            // thinning is done by leaving the others blank.
            let shown = Set(labelKeys(buckets))
            AxisMarks { value in
                AxisValueLabel(centered: true) {
                    if let key = value.as(String.self), shown.contains(key), let index = Int(key), buckets.indices.contains(index) {
                        Text(verbatim: Self.label(buckets[index], period.granularity)).foregroundStyle(Theme.slate)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Theme.cardStroke)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(verbatim: mode == .cost ? store.money(amount, digits: digits) : AppFormat.tokens(Int(amount)))
                            .foregroundStyle(Theme.slate)
                    }
                }
            }
        }
        .chartHover(String.self) { hovered = $0 }
        .frame(height: Self.chartHeight)
        .accessibilityLabel(title)
        .accessibilityValue(summary(period))
    }

    private var seriesDomain: [String] {
        mode == .cost ? ModelFamily.allCases.map(\.label) : UsageSeries.allCases.map(\.displayName)
    }

    private var seriesColors: [Color] {
        mode == .cost ? ModelFamily.allCases.map(\.color) : UsageSeries.allCases.map(\.color)
    }

    /// About eight labels whatever the bar count.
    private func labelKeys(_ buckets: [UsagePeriod.Bucket]) -> [String] {
        let stride = max(1, Int((Double(buckets.count) / 8).rounded(.up)))
        return buckets.filter { $0.index % stride == 0 }.map(Self.key)
    }

    static func label(_ bucket: UsagePeriod.Bucket, _ granularity: UsagePeriod.Granularity) -> String {
        switch granularity {
        case .hour: AppFormat.hour(Calendar.current.component(.hour, from: bucket.start))
        case .day, .week: AppFormat.shortDate(bucket.start)
        case .month: bucket.start.formatted(.dateTime.month(.abbreviated).year(.twoDigits).locale(AppFormat.locale))
        }
    }

    /// The bucket's span: one hour or day, or its first and last day.
    static func span(_ bucket: UsagePeriod.Bucket, _ granularity: UsagePeriod.Granularity) -> String {
        let calendar = Calendar.current
        switch granularity {
        case .hour:
            let hour = calendar.component(.hour, from: bucket.start)
            return "\(AppFormat.hour(hour)) – \(AppFormat.hour((hour + 1) % 24))"
        case .day:
            return AppFormat.shortDate(bucket.start)
        case .week, .month:
            let last = calendar.date(byAdding: .day, value: -1, to: bucket.end) ?? bucket.start
            return calendar.isDate(last, inSameDayAs: bucket.start)
                ? AppFormat.shortDate(bucket.start)
                : "\(AppFormat.shortDate(bucket.start)) – \(AppFormat.shortDate(last))"
        }
    }

    private func tooltip(_ bucket: UsagePeriod.Bucket, _ granularity: UsagePeriod.Granularity) -> [String] {
        let head = "\(Self.span(bucket, granularity)) · \(store.money(bucket.costUSD))"
        let detail: [String] = switch mode {
        case .cost:
            ModelFamily.allCases.compactMap { family in
                bucket.costByFamily[family].map { "\(family.label) \(store.money($0))" }
            }
        case .tokens:
            [String(localized: "\(AppFormat.tokens(bucket.totalTokens)) tokens", locale: AppFormat.locale)]
                + UsageSeries.allCases.map { "\($0.displayName) \(AppFormat.tokens(bucket.tokens($0)))" }
        }
        return [head] + detail + [String(localized: "\(bucket.sessionCount) sessions", locale: AppFormat.locale)]
    }

    // MARK: Legend

    private func legend(_ usage: UsageSnapshot) -> some View {
        let items: [(String, Color, Double)] = switch mode {
        case .cost:
            usage.costByFamily.map { ($0.family.label, $0.family.color, $0.costUSD) }
        case .tokens:
            usage.totals.tokenParts.map { ($0.0.displayName, $0.0.color, Double($0.1)) }
        }
        let total = items.reduce(0) { $0 + $1.2 }
        return HStack(spacing: 12) {
            ForEach(items, id: \.0) { name, color, amount in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
                    Text(verbatim: "\(name) \(AppFormat.percent(total > 0 ? amount / total : 0))")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(Theme.slate)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ period: UsagePeriod) -> String {
        let total = period.buckets.reduce(0) { $0 + value($1) }
        let peak = period.buckets.max { value($0) < value($1) }
        var parts = [mode == .cost ? store.money(total) : AppFormat.tokens(Int(total))]
        if let peak, value(peak) > 0 {
            parts.append("\(Self.span(peak, period.granularity)) \(mode == .cost ? store.money(value(peak)) : AppFormat.tokens(Int(value(peak))))")
        }
        return parts.joined(separator: ", ")
    }
}
