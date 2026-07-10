import SwiftUI

struct ErrorsLogView: View {
    let snapshot: DriveSnapshot

    var body: some View {
        TableOrEmpty(title: "S.M.A.R.T. Error Log", isEmpty: snapshot.errorLog.isEmpty, emptyText: "This drive did not report SMART errors or does not expose an error log.") {
            VStack(spacing: 1) {
                LogHeader(columns: ["#", "lifetime (h)", "errors", "prior command", "LBA"])
                ForEach(snapshot.errorLog) { entry in
                    HStack {
                        cell("\(entry.id)", width: 42)
                        cell(entry.lifetimeHours.map(String.init) ?? "-", width: 110)
                        cell(entry.errors, width: 260)
                        cell(entry.priorCommand, width: 220)
                        cell(entry.lba ?? "-", width: 140)
                        Spacer()
                    }
                    .padding(9)
                    .background(.quaternary.opacity(0.5))
                }
            }
            .padding(12)
        }
    }
}

struct DeviceStatisticsView: View {
    let snapshot: DriveSnapshot

    var grouped: [String: [DeviceStatistic]] {
        Dictionary(grouping: snapshot.deviceStatistics, by: \.section)
    }

    var body: some View {
        TableOrEmpty(title: "Device Statistics", isEmpty: snapshot.deviceStatistics.isEmpty, emptyText: "Device Statistics are optional and this drive did not expose them through smartctl.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(grouped.keys.sorted(), id: \.self) { section in
                        SectionBox(section) {
                            VStack(spacing: 6) {
                                ForEach(grouped[section] ?? []) { stat in
                                    HStack {
                                        Text(stat.name)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        Text(stat.value)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

struct SelfTestsView: View {
    @EnvironmentObject private var store: DriveStore
    let snapshot: DriveSnapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    Task { await store.startSelfTest(kind: "short") }
                } label: {
                    Label("Start Short Self-test", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(store.isSelfTestPolling)

                Button {
                    Task { await store.startSelfTest(kind: "long") }
                } label: {
                    Label("Start Full Self-test", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(store.isSelfTestPolling)

                if store.isSelfTestPolling || snapshot.activeSelfTest?.isRunning == true {
                    Button(role: .destructive) {
                        Task { await store.cancelSelfTest() }
                    } label: {
                        Label("Stop Self-test", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5))

            if store.isSelfTestPolling || snapshot.activeSelfTest?.isRunning == true {
                SelfTestProgressBanner(
                    status: snapshot.activeSelfTest,
                    isPolling: store.isSelfTestPolling,
                    kind: store.selfTestKind(for: snapshot.device.id)
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            TableOrEmpty(title: "Self-tests", isEmpty: snapshot.selfTests.isEmpty, emptyText: "No self-test history was reported. Some NVMe and USB devices do not expose self-test capabilities.") {
                VStack(spacing: 1) {
                    LogHeader(columns: ["#", "lifetime (h)", "test type", "progress", "status", "LBA of 1st error"])
                    ForEach(snapshot.selfTests) { entry in
                        HStack {
                            cell("\(entry.id)", width: 42)
                            cell(entry.lifetimeHours.map(String.init) ?? "-", width: 110)
                            cell(entry.testType, width: 130)
                            cell(entry.remainingPercent.map { "\(100 - $0)%" } ?? "100%", width: 90)
                            cell(entry.status, width: 260)
                            cell(entry.lbaOfFirstError ?? "-", width: 140)
                            Spacer()
                        }
                        .padding(9)
                        .background(.quaternary.opacity(0.5))
                    }
                }
                .padding(12)
            }
        }
    }
}

struct SelfTestProgressBanner: View {
    let status: ActiveSelfTestStatus?
    let isPolling: Bool
    var kind: String?

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                Text(status?.title ?? String(localized: "Self-test started. Waiting for drive status..."))
                    .font(.callout.weight(.semibold))
                HStack(spacing: 10) {
                    ProgressView(value: Double(status?.progressPercent ?? 0), total: 100)
                        .tint(.green)
                        .frame(width: 220)
                    Text(status?.progressPercent.map { "\($0)%" } ?? String(localized: "refreshing"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let minutes = status?.estimatedMinutes(forKind: kind) {
                        Text("ETA: ~\(minutes) min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(isPolling ? "Auto refresh on" : "Checking")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct TableOrEmpty<Content: View>: View {
    let title: String
    let isEmpty: Bool
    let emptyText: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
            if isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                content
            }
        }
    }
}

struct LogHeader: View {
    let columns: [String]

    var body: some View {
        HStack {
            ForEach(columns, id: \.self) { column in
                Text(column)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: width(for: column), alignment: .leading)
            }
            Spacer()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.quaternary)
    }

    private func width(for column: String) -> CGFloat {
        switch column {
        case "#": 42
        case "lifetime (h)": 110
        case "test type": 130
        case "progress": 90
        case "status", "errors": 260
        case "prior command": 220
        default: 140
        }
    }
}

func cell(_ text: String, width: CGFloat) -> some View {
    Text(text)
        .lineLimit(2)
        .frame(width: width, alignment: .leading)
        .textSelection(.enabled)
}
