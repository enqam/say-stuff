import Charts
import SwiftUI
import UniformTypeIdentifiers

/// How fast you talk, over time, from local speech stats.
struct SpeakingCard: View {
    @ObservedObject var stats = SpeechStats.shared
    @State private var period: Period = .month
    @State private var grouping: SpeechStats.Grouping = .language

    enum Period: Hashable {
        case week, month, all

        var start: Date? {
            switch self {
            case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .all: nil
            }
        }
    }

    var body: some View {
        let samples = stats.samples(since: period.start)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Speaking")
                Spacer()
                if !stats.samples.isEmpty {
                    ChipPicker(options: [(Period.week, "7 days"), (.month, "30 days"), (.all, "All")], selection: $period)
                    Button("Export") { export() }.buttonStyle(PillButtonStyle())
                }
            }
            if let pace = SpeechStats.Pace(samples) {
                Card {
                    headline(pace)
                    let days = SpeechStats.days(samples)
                    if days.count >= 2 {
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14)
                        chart(days, average: pace.rate)
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack {
                        ChipPicker(options: SpeechStats.Grouping.allCases.map { ($0, $0.rawValue) }, selection: $grouping)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    let groups = SpeechStats.groups(samples, by: grouping)
                    ForEach(groups) { group in
                        CardRow(title: group.name,
                                detail: "\(group.pace.dictations) dictations · \(group.pace.words.formatted()) words · \(percent(group.pace.fillerShare)) fillers",
                                showsDivider: group.id != groups.last?.id) {
                            Text(rate(group.pace.rate))
                                .font(.mono(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Text("Words as transcribed, before cleanup, from your first word to your last. Without pauses = only the time your voice is above the room's noise. Dictations under three words or a second are left out of the rates.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text(stats.samples.isEmpty ? "Dictate a few times to see how fast you talk."
                                           : "No dictations in this period.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func headline(_ pace: SpeechStats.Pace) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.2f", pace.rate))
                        .font(.mono(28, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("words/s")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("\(Int((pace.rate * 60).rounded())) wpm · \(pace.words.formatted()) words · \(pace.dictations) dictations")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                stat("Without pauses", rate(pace.articulation))
                stat("Pauses", String(format: "%.1f/min · %.1fs", pace.pausesPerMinute, pace.meanPause))
                stat("Fillers", percent(pace.fillerShare))
            }
        }
        .padding(14)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.mono(11.5)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func chart(_ days: [SpeechStats.Day], average: Double) -> some View {
        Chart {
            RuleMark(y: .value("Average", average))
                .foregroundStyle(Theme.textTertiary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(days) { day in
                LineMark(x: .value("Day", day.date, unit: .day), y: .value("Words/s", day.rate))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Day", day.date, unit: .day), y: .value("Words/s", day.rate))
                    .foregroundStyle(Theme.accent)
                    .symbolSize(days.count > 40 ? 8 : 18)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.mono(10)).foregroundStyle(Theme.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(height: 110)
        .padding(14)
    }

    private func rate(_ value: Double) -> String { String(format: "%.2f w/s", value) }
    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SayStuff speaking.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try stats.csv().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[Speech] Export failed: \(error)")
        }
    }
}
