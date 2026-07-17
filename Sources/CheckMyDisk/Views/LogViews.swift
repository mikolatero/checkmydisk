import SwiftUI

struct ErrorsLogView: View {
    let snapshot: DriveSnapshot

    var body: some View {
        TableOrEmpty(title: "S.M.A.R.T. Error Log", isEmpty: snapshot.errorLog.isEmpty, emptyText: "This drive did not report SMART errors or does not expose an error log.") {
            Table(snapshot.errorLog) {
                TableColumn("#") { Text("\($0.id)") }
                    .width(min: 36, ideal: 44)
                TableColumn("Lifetime (h)") { Text($0.lifetimeHours.map(String.init) ?? "-") }
                    .width(min: 80, ideal: 100)
                TableColumn("Errors") { Text($0.errors).textSelection(.enabled) }
                TableColumn("Prior command") { Text($0.priorCommand).textSelection(.enabled) }
                TableColumn("LBA") { Text($0.lba ?? "-").textSelection(.enabled) }
            }
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
    @Environment(DriveStore.self) private var store
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

                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.5))

            if store.settings.scheduledSelfTestsEnabled {
                Label("Automatic self-tests are enabled in Settings.", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }

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
                Table(snapshot.selfTests) {
                    TableColumn("#") { Text("\($0.id)") }
                        .width(min: 36, ideal: 44)
                    TableColumn("Lifetime (h)") { Text($0.lifetimeHours.map(String.init) ?? "-") }
                        .width(min: 80, ideal: 100)
                    TableColumn("Test type") { Text($0.testType) }
                    TableColumn("Progress") { Text($0.remainingPercent.map { "\(100 - $0)%" } ?? "100%") }
                        .width(min: 70, ideal: 90)
                    TableColumn("Status") { Text($0.status).textSelection(.enabled) }
                    TableColumn("LBA of 1st error") { Text($0.lbaOfFirstError ?? "-").textSelection(.enabled) }
                }
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
    let title: LocalizedStringKey
    let isEmpty: Bool
    let emptyText: LocalizedStringKey
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
        // Pinned to the top; otherwise the whole block floats vertically
        // centered in the detail column.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
