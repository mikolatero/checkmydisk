import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @Environment(DriveStore.self) private var store
    let snapshot: DriveSnapshot
    let assessment: DriveAssessment

    @State private var saveErrorMessage: String?
    @State private var showSaveError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !snapshot.messages.isEmpty {
                    SectionBox(String(localized: "smartctl Messages")) {
                        MessagesView(messages: snapshot.messages, isInformational: snapshot.hasBasicHealthData)
                    }
                }
                SectionBox(String(localized: "General Information")) {
                    InfoGrid(rows: generalRows)
                }
                if !store.selectedVolumes.isEmpty {
                    SectionBox(String(localized: "Volumes")) {
                        VolumesView(volumes: store.selectedVolumes)
                    }
                }
                SectionBox(String(localized: "Problems Summary")) {
                    ProblemsSummaryView(assessment: assessment)
                }
                SectionBox(String(localized: "Important Health Indicators")) {
                    IndicatorsCompactList(attributes: Array(snapshot.attributes.prefix(10)))
                }
                SectionBox(String(localized: "USB / FireWire / SAT Support")) {
                    CompatibilityPanel(status: store.satStatus)
                }
            }
            .padding(16)
        }
        .alert(String(localized: "Could not save the report"), isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: snapshot.isRotational == true ? "internaldrive.fill" : "memorychip.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(driveKindText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text("Advanced S.M.A.R.T. Status:")
                        .fontWeight(.bold)
                    StatusBadge(state: assessment.smartStatus, text: assessment.smartStatus.rawValue)
                }
                .font(.callout)
                Text(problemCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 16) {
                MetricGauge(title: String(localized: "Health"), percent: assessment.overallHealth)
                MetricGauge(title: String(localized: "Performance"), percent: assessment.overallPerformance)
                if let lifetime = assessment.ssdLifetimeLeft {
                    MetricGauge(title: String(localized: "Lifetime Left"), percent: lifetime)
                }
                if let temperature = snapshot.temperature {
                    TemperatureGauge(
                        temperature: temperature,
                        thresholds: HealthEvaluator.temperatureThresholds(for: snapshot)
                    )
                }
            }

            Menu {
                Button(String(localized: "Text Report...")) { saveReport(format: .text) }
                Button(String(localized: "JSON Report...")) { saveReport(format: .json) }
            } label: {
                Label("Save Report...", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
        }
        .padding(14)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var driveKindText: String {
        if let rotational = snapshot.isRotational {
            return rotational ? "HDD" : "SSD"
        }
        return snapshot.device.protocolName
    }

    private var problemCountText: String {
        let count = assessment.issueCount
        return count == 0
            ? String(localized: "No active issues")
            : String(localized: "\(count) active issue(s)")
    }

    private var generalRows: [(String, String)] {
        var rows: [(String, String)] = [
            (String(localized: "Device Path"), snapshot.device.name),
            (String(localized: "Protocol"), snapshot.device.protocolName),
            (String(localized: "Model"), snapshot.modelName),
            (String(localized: "Serial No."), snapshot.serialNumber ?? "-"),
            (String(localized: "Firmware"), snapshot.firmwareVersion ?? "-"),
            (String(localized: "Total Capacity"), snapshot.userCapacityBytes.map(ReportBuilder.formatBytes) ?? "-"),
            (String(localized: "Sector Size"), snapshot.sectorSize ?? "-")
        ]
        if let wwn = snapshot.wwn {
            rows.append((String(localized: "WWN"), wwn))
        }
        if let formFactor = snapshot.formFactor {
            rows.append((String(localized: "Form Factor"), formFactor))
        }
        if let rotationRate = snapshot.rotationRate {
            rows.append((String(localized: "Rotation Rate"), rotationRate == 0 ? "SSD" : "\(rotationRate) rpm"))
        }
        if let interfaceSpeed = snapshot.interfaceSpeed {
            rows.append((String(localized: "Interface Speed"), interfaceSpeed))
        }
        if let version = snapshot.sataVersion ?? snapshot.ataVersion ?? snapshot.nvmeVersion {
            rows.append((String(localized: "Standard Version"), version))
        }
        if let trim = snapshot.trimSupported {
            rows.append((String(localized: "TRIM"), trim ? String(localized: "Supported") : String(localized: "Not supported")))
        }
        rows.append(contentsOf: [
            (String(localized: "Data Written"), DriveUsageMetrics.formattedBytesWritten(for: snapshot) ?? "-"),
            (String(localized: "Data Read"), DriveUsageMetrics.formattedBytesRead(for: snapshot) ?? "-"),
            (String(localized: "Power On Time"), snapshot.powerOnHours.map { formatHours($0) } ?? "-"),
            (String(localized: "Power Cycles Count"), snapshot.powerCycles.map(String.init) ?? "-"),
            (String(localized: "Temperature"), temperatureText)
        ])
        if let nvme = snapshot.nvme {
            if let spare = nvme.availableSpare {
                let threshold = nvme.availableSpareThreshold.map { " (threshold \($0)%)" } ?? ""
                rows.append((String(localized: "Available Spare"), "\(spare)%\(threshold)"))
            }
            if let busy = nvme.controllerBusyTime {
                rows.append((String(localized: "Controller Busy Time"), formatMinutes(busy)))
            }
            if let hostReads = nvme.hostReads {
                rows.append((String(localized: "Host Read Commands"), hostReads.formatted()))
            }
            if let hostWrites = nvme.hostWrites {
                rows.append((String(localized: "Host Write Commands"), hostWrites.formatted()))
            }
            if let unsafeShutdowns = nvme.unsafeShutdowns {
                rows.append((String(localized: "Unsafe Shutdowns"), unsafeShutdowns.formatted()))
            }
        }
        return rows
    }

    private var temperatureText: String {
        guard let temperature = snapshot.temperature else { return "-" }
        var text = "\(temperature) °C"
        if let min = snapshot.temperatureLifetimeMin, let max = snapshot.temperatureLifetimeMax {
            text += String(localized: " (lifetime \(min)–\(max) °C)")
        }
        return text
    }

    private func formatHours(_ hours: UInt64) -> String {
        let days = hours / 24
        return days > 0 ? "\(hours) h (~\(days) days)" : "\(hours) h"
    }

    private func formatMinutes(_ minutes: UInt64) -> String {
        let hours = minutes / 60
        return hours > 0 ? "\(minutes) min (~\(hours) h)" : "\(minutes) min"
    }

    private enum ReportFormat {
        case text
        case json
    }

    private func saveReport(format: ReportFormat) {
        let panel = NSSavePanel()
        let sanitizedModel = snapshot.modelName.replacingOccurrences(of: "/", with: "-")
        switch format {
        case .text:
            panel.nameFieldStringValue = "CheckMyDisk-\(sanitizedModel)-Report.txt"
            panel.allowedContentTypes = [.plainText]
        case .json:
            panel.nameFieldStringValue = "CheckMyDisk-\(sanitizedModel)-Report.json"
            panel.allowedContentTypes = [.json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .text:
                let text = ReportBuilder.textReport(snapshot: snapshot, assessment: assessment, anonymize: store.settings.anonymizeReports)
                try text.write(to: url, atomically: true, encoding: .utf8)
            case .json:
                let data = try ReportBuilder.jsonReport(snapshot: snapshot, assessment: assessment, anonymize: store.settings.anonymizeReports)
                try data.write(to: url, options: .atomic)
            }
        } catch {
            saveErrorMessage = error.localizedDescription
            showSaveError = true
        }
    }
}

struct StatusBadge: View {
    let state: DriveHealthState
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.black))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(stateColor(state))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(Text(text))
    }
}

struct MetricGauge: View {
    let title: String
    let percent: Int

    var body: some View {
        VStack(spacing: 4) {
            Gauge(value: Double(percent), in: 0...100) {
                Text(title)
            } currentValueLabel: {
                Text("\(percent)%")
                    .font(.system(.caption, design: .rounded).weight(.bold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(stateColor(stateForPercent(percent)))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title): \(percent)%"))
    }
}

struct TemperatureGauge: View {
    let temperature: Int
    let thresholds: (warning: Int, failing: Int)

    private var state: DriveHealthState {
        if temperature >= thresholds.failing { return .failing }
        if temperature >= thresholds.warning { return .warning }
        return .ok
    }

    var body: some View {
        VStack(spacing: 4) {
            Gauge(value: Double(min(temperature, 100)), in: 0...100) {
                Text("Temperature")
            } currentValueLabel: {
                Text("\(temperature)°")
                    .font(.system(.caption, design: .rounded).weight(.bold))
            }
            .gaugeStyle(.accessoryCircular)
            .tint(Gradient(colors: [.green, .yellow, .orange, .red]))
            Text("Temperature")
                .font(.caption)
                .foregroundStyle(state == .ok ? Color.secondary : stateColor(state))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Temperature: \(temperature) °C"))
    }
}

struct MessagesView: View {
    let messages: [SmartMessage]
    /// True when the health data itself was read fine, so these messages are
    /// notices about unsupported optional features, not read failures.
    let isInformational: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                Label {
                    Text(message.text)
                        .foregroundStyle(isInformational ? .secondary : .primary)
                        .textSelection(.enabled)
                } icon: {
                    if isInformational {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: message.severity.lowercased() == "error" ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(message.severity.lowercased() == "error" ? .yellow : .secondary)
                    }
                }
                .font(.callout)
            }
            if isInformational {
                Text("These notices come from smartctl itself: the drive does not support some optional log pages. The health data was read correctly and the assessment is not affected.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct VolumesView: View {
    let volumes: [VolumeInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(volumes) { volume in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Label(volume.name, systemImage: "externaldrive.fill")
                            .fontWeight(.semibold)
                        Spacer()
                        if let available = volume.availableCapacity, let total = volume.totalCapacity {
                            Text("\(ReportBuilder.formatBytes(available)) free of \(ReportBuilder.formatBytes(total))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    if let used = volume.usedCapacity, let total = volume.totalCapacity, total > 0 {
                        ProgressView(value: Double(used), total: Double(total))
                            .tint(Double(used) / Double(total) > 0.9 ? .orange : .blue)
                    }
                }
            }
        }
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct InfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0 + ":")
                        .fontWeight(.semibold)
                    Text(row.1)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
    }
}

struct ProblemsSummaryView: View {
    let assessment: DriveAssessment

    var body: some View {
        if assessment.problems.isEmpty {
            Label("No health-related issues found", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(assessment.problems) { problem in
                    HStack {
                        Text(problem.title)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(problem.state.rawValue)
                            .foregroundStyle(stateColor(problem.state))
                    }
                    Text(problem.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct IndicatorsCompactList: View {
    let attributes: [SmartAttribute]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(attributes) { attribute in
                HStack {
                    Text(String(format: "%03d", attribute.id))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 38, alignment: .leading)
                    Text(attribute.name)
                        .fontWeight(.semibold)
                    Spacer()
                    ProgressView(value: Double(attribute.percent ?? 0), total: 100)
                        .tint(stateColor(attribute.status))
                        .frame(width: 150)
                    Text(attribute.percent.map { "\($0)%" } ?? "-")
                        .frame(width: 42, alignment: .trailing)
                    Text(attribute.status.rawValue)
                        .foregroundStyle(stateColor(attribute.status))
                        .frame(width: 72, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }
}

func stateForPercent(_ percent: Int) -> DriveHealthState {
    if percent >= 90 { return .ok }
    if percent >= 70 { return .warning }
    if percent >= 40 { return .failing }
    return .failed
}
