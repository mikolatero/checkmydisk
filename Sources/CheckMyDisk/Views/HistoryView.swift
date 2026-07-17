import Charts
import SwiftUI

struct HistoryView: View {
    @Environment(DriveStore.self) private var store
    let snapshot: DriveSnapshot

    @State private var range: HistoryRange = .week
    @State private var points: [HistoryPoint] = []
    @State private var hasLoaded = false

    enum HistoryRange: String, CaseIterable, Identifiable {
        case day
        case week
        case month
        case all

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .day: "24 h"
            case .week: "7 days"
            case .month: "30 days"
            case .all: "All"
            }
        }

        var since: Date? {
            switch self {
            case .day: Date().addingTimeInterval(-86_400)
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .month: Date().addingTimeInterval(-30 * 86_400)
            case .all: nil
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                if points.count < 2 {
                    emptyState
                } else {
                    if points.contains(where: { $0.temperature != nil }) {
                        SectionBox(String(localized: "Temperature")) {
                            temperatureChart
                        }
                    }
                    SectionBox(String(localized: "Health & Performance")) {
                        healthChart
                    }
                    if points.contains(where: { $0.lifetime != nil }) {
                        SectionBox(String(localized: "SSD Lifetime Left")) {
                            if let estimate = TrendAnalyzer.estimateRemainingLife(from: points, asOf: Date()) {
                                Label(String(localized: "~\(estimate.daysRemaining) days of life left at the current wear rate"), systemImage: "hourglass")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            lifetimeChart
                        }
                    }
                }

                if let sct = snapshot.sctTemperatureHistory {
                    SectionBox(String(localized: "Firmware Temperature History")) {
                        Text("Recorded by the drive itself, independent of CheckMyDisk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        sctChart(sct)
                    }
                }
            }
            .padding(16)
        }
        .task(id: "\(snapshot.device.id)|\(range.rawValue)") {
            // Reset per (device, range) so a switch shows "Loading…" again instead
            // of the previous selection's data or a premature "not enough history".
            hasLoaded = false
            points = []
            points = await store.history(for: snapshot.device.id, since: range.since)
            hasLoaded = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(hasLoaded ? String(localized: "Not enough history for this range yet. Data accumulates with every check while the app is open.") : String(localized: "Loading history..."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    private var temperatureChart: some View {
        let thresholds = HealthEvaluator.temperatureThresholds(for: snapshot)
        return Chart {
            ForEach(points.filter { $0.temperature != nil }) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("°C", point.temperature ?? 0)
                )
                .foregroundStyle(.cyan)
                .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("Warning", thresholds.warning))
                .foregroundStyle(.yellow.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .annotation(position: .topLeading) {
                    Text("\(thresholds.warning) °C")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
        }
        .chartYAxisLabel("°C")
        .frame(height: 180)
    }

    private var healthChart: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("%", point.health),
                series: .value("Series", String(localized: "Health"))
            )
            .foregroundStyle(by: .value("Series", String(localized: "Health")))
            LineMark(
                x: .value("Date", point.date),
                y: .value("%", point.performance),
                series: .value("Series", String(localized: "Performance"))
            )
            .foregroundStyle(by: .value("Series", String(localized: "Performance")))
        }
        .chartForegroundStyleScale([
            String(localized: "Health"): Color.green,
            String(localized: "Performance"): Color.blue
        ])
        .chartYScale(domain: 0...100)
        .chartYAxisLabel("%")
        .frame(height: 180)
    }

    private var lifetimeChart: some View {
        Chart(points.filter { $0.lifetime != nil }) { point in
            AreaMark(
                x: .value("Date", point.date),
                y: .value("%", point.lifetime ?? 0)
            )
            .foregroundStyle(.green.opacity(0.35))
            .interpolationMethod(.monotone)
            LineMark(
                x: .value("Date", point.date),
                y: .value("%", point.lifetime ?? 0)
            )
            .foregroundStyle(.green)
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartYAxisLabel("%")
        .frame(height: 160)
    }

    private func sctChart(_ history: SCTTemperatureHistory) -> some View {
        // The table ends with the most recent sample; offsets count back from the
        // time of the snapshot.
        let samples: [(offset: Int, temperature: Int)] = history.temperatures.enumerated().compactMap { index, value in
            guard let value else { return nil }
            let minutesAgo = (history.temperatures.count - 1 - index) * history.intervalMinutes
            return (offset: -minutesAgo, temperature: value)
        }
        return Chart(samples, id: \.offset) { sample in
            LineMark(
                x: .value("Minutes", Double(sample.offset) / 60),
                y: .value("°C", sample.temperature)
            )
            .foregroundStyle(.orange)
        }
        .chartXAxisLabel(String(localized: "Hours before last check"))
        .chartYAxisLabel("°C")
        .frame(height: 150)
    }
}
