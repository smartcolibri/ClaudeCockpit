import SwiftUI
import Charts
import CockpitShared
import RTKKit

// MARK: - Compression gauge

/// The signature element, ported from RTKInfos.
///
/// A single horizontal bar that tells the whole story: the raw `input` is
/// compressed down to `output`, and the span rtk reclaimed is painted in
/// emerald. On appearance the output block animates from full width down to
/// its real size, so the eye sees the compression happen. This is the one
/// place the RTK screen spends its boldness; everything around it stays quiet.
struct CompressionGauge: View {
    let input: Int
    let output: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var compressed = false

    private var saved: Int { max(0, input - output) }
    private var outputRatio: Double {
        guard input > 0 else { return 0 }
        return min(1, Double(output) / Double(input))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: String(localized: "Compression"))

            GeometryReader { geo in
                let width = geo.size.width
                let outputWidth = compressed ? max(4, width * outputRatio) : width
                ZStack(alignment: .leading) {
                    // Full track: the raw input footprint.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.emerald.opacity(0.14))
                    // The reclaimed span carries the count.
                    Text("\(AppFormat.tokens(saved)) saved")
                        .font(.data(11))
                        .foregroundStyle(Theme.emerald)
                        .frame(maxWidth: .infinity)
                        .opacity(compressed ? 1 : 0)
                    // The output block: what actually remains.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.emerald)
                        .frame(width: outputWidth)
                }
            }
            .frame(height: 30)

            HStack(spacing: 0) {
                endLabel(value: AppFormat.tokens(input), caption: String(localized: "Input"), align: .leading)
                Spacer(minLength: 12)
                endLabel(value: AppFormat.tokens(output), caption: String(localized: "Output"), align: .trailing)
            }
        }
        .onAppear {
            guard !compressed else { return }
            if reduceMotion {
                compressed = true
            } else {
                withAnimation(.easeOut(duration: 0.65).delay(0.12)) { compressed = true }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compression")
        .accessibilityValue("\(AppFormat.tokens(input)) input compressed to \(AppFormat.tokens(output)) output, \(AppFormat.tokens(saved)) tokens saved")
    }

    private func endLabel(value: String, caption: String, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 1) {
            Text(value).font(.data(13)).foregroundStyle(Theme.ink)
            Text(caption.uppercased())
                .font(.label(9))
                .tracking(1.2)
                .foregroundStyle(Theme.slate)
        }
    }
}

// MARK: - 7-day intensity chart

/// Seven daily buckets of tokens saved, each bar tinted by how much it weighs
/// against the strongest day. Quiet days read as neutral mist, never judged.
struct WeekIntensityChart: View {
    let days: [DayStat]

    private var maxSaved: Int { days.map(\.savedTokens).max() ?? 0 }

    /// Relative weight of a day, expressed on the 0…100 scale
    /// `Theme.savingsIntensity` expects.
    private func intensity(_ day: DayStat) -> Double {
        guard maxSaved > 0 else { return 0 }
        return 100 * Double(day.savedTokens) / Double(maxSaved)
    }

    var body: some View {
        Group {
            if days.isEmpty {
                Text("No activity in the last seven days.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else {
                Chart(days) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Tokens saved", day.savedTokens),
                        width: .ratio(0.55)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(Theme.savingsIntensity(intensity(day)))
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Theme.cardStroke)
                        AxisValueLabel {
                            if let raw = value.as(Double.self) {
                                Text(AppFormat.tokens(Int(raw)))
                                    .font(.label(9))
                                    .foregroundStyle(Theme.mist)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(AppFormat.weekday(date))
                                    .font(.label(9))
                                    .foregroundStyle(Theme.mist)
                            }
                        }
                    }
                }
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Tokens saved over seven days")
                .accessibilityValue(summary)
            }
        }
    }

    private var summary: String {
        days.map { String(localized: "\(AppFormat.weekday($0.date)): \(AppFormat.tokens($0.savedTokens))", locale: AppFormat.locale) }
            .joined(separator: ", ")
    }
}

// MARK: - By-command bars

/// One rtk filter: rank, name, run count, tokens saved and a proportional
/// emerald bar sized against the heaviest filter.
struct CommandImpactRow: View {
    let rank: Int
    let stat: CommandStat
    let maxSaved: Int

    private var ratio: Double {
        guard maxSaved > 0 else { return 0 }
        return min(1, Double(stat.savedTokens) / Double(maxSaved))
    }

    var body: some View {
        HStack(spacing: 10) {
            rankBadge
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(stat.name)
                        .font(.data(12))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(AppFormat.integer(stat.count)) ×")
                        .font(.data(11))
                        .foregroundStyle(Theme.slate)
                        .frame(width: 64, alignment: .trailing)
                    Text(AppFormat.tokens(stat.savedTokens))
                        .font(.data(12))
                        .foregroundStyle(Theme.emerald)
                        .frame(width: 66, alignment: .trailing)
                    Text(AppFormat.percent(stat.savingsPct, fraction: false))
                        .font(.data(11))
                        .foregroundStyle(Theme.savingsIntensity(stat.savingsPct))
                        .frame(width: 52, alignment: .trailing)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.emerald.opacity(0.12))
                        Capsule()
                            .fill(Theme.savingsIntensity(stat.savingsPct))
                            .frame(width: max(3, geo.size.width * ratio))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stat.name)
        .accessibilityValue("\(String(localized: "\(stat.count) runs", locale: AppFormat.locale)), \(AppFormat.tokens(stat.savedTokens)) saved, \(AppFormat.percent(stat.savingsPct, fraction: false))")
    }

    /// The top three get an emerald halo, the rest stay neutral mist.
    private var rankBadge: some View {
        Text(verbatim: "\(rank)")
            .font(.data(10))
            .foregroundStyle(rank <= 3 ? Theme.emerald : Theme.mist)
            .frame(width: 20, height: 20)
            .background(Circle().fill(rank <= 3 ? Theme.emerald.opacity(0.14) : Color.primary.opacity(0.04)))
    }
}

// MARK: - Live trace

/// Side panel listing the most recent rtk commands, newest first.
struct RTKTracePanel: View {
    let records: [CommandRecord]
    var isStale: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if records.isEmpty {
                Text("No commands recorded.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.slate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(records) { record in
                                TraceRow(record: record).id(record.id)
                            }
                        }
                    }
                    .onChange(of: records.first?.id) { _, newValue in
                        guard let newValue else { return }
                        if reduceMotion {
                            proxy.scrollTo(newValue, anchor: .top)
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(newValue, anchor: .top) }
                        }
                    }
                }
            }
        }
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isStale ? Theme.mist : Theme.emerald)
                .frame(width: 7, height: 7)
                .scaleEffect(pulse ? 1.9 : 1)
                .opacity(pulse ? 1 : 0.85)
                .accessibilityHidden(true)
            SectionLabel(text: String(localized: "Live trace"))
            Spacer()
            Text("\(records.count) cmd")
                .font(.data(10))
                .foregroundStyle(Theme.slate)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onChange(of: records.first?.id) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.easeIn(duration: 0.1)) { pulse = true }
            withAnimation(.easeOut(duration: 0.6).delay(0.1)) { pulse = false }
        }
    }
}

/// One line of the trace: time, command, tokens saved, savings percentage.
private struct TraceRow: View {
    let record: CommandRecord

    var body: some View {
        HStack(spacing: 8) {
            Text(AppFormat.timeWithSeconds(record.timestamp))
                .font(.data(10))
                .foregroundStyle(Theme.slate)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.originalCommand)
                    .font(.data(11))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(record.rtkCommand)
                    .font(.data(9))
                    .foregroundStyle(Theme.mist)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(AppFormat.tokens(record.savedTokens))
                .font(.data(10))
                .foregroundStyle(Theme.emerald)
                .frame(width: 54, alignment: .trailing)
            Text(AppFormat.percent(record.savingsPct, fraction: false))
                .font(.data(10))
                .foregroundStyle(Theme.savingsIntensity(record.savingsPct))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.02))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.originalCommand)
        .accessibilityValue("\(AppFormat.percent(record.savingsPct, fraction: false)) saved at \(AppFormat.timeWithSeconds(record.timestamp))")
    }
}
