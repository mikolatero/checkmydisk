import SwiftUI

enum SidebarRoute: Hashable {
    case fleet
    case drive(deviceID: String, section: DriveSection)
}

struct ContentView: View {
    @Environment(DriveStore.self) private var store

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 390)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItemGroup {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    store.refreshNow()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh drive diagnostics")
            }
        }
    }
}

struct SidebarView: View {
    @Environment(DriveStore.self) private var store

    private var selection: Binding<SidebarRoute?> {
        Binding {
            if store.showFleet { return .fleet }
            return store.selectedDeviceID.map { .drive(deviceID: $0, section: store.selectedSection) }
        } set: { newValue in
            Task { @MainActor in
                switch newValue {
                case .fleet:
                    store.showFleet = true
                case let .drive(deviceID, section):
                    store.showFleet = false
                    if store.selectedDeviceID != deviceID {
                        store.selectedDeviceID = deviceID
                    }
                    if store.selectedSection != section {
                        store.selectedSection = section
                    }
                case nil:
                    break
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                Section {
                    Label("All Drives", systemImage: "square.grid.2x2.fill")
                        .tag(SidebarRoute.fleet)
                }
                ForEach(store.devices) { device in
                    Section {
                        ForEach(DriveSection.allCases) { section in
                            Label {
                                Text(section.localizedTitle)
                            } icon: {
                                Image(systemName: icon(for: section))
                                    .foregroundStyle(color(for: section))
                            }
                            .badge(badgeCount(for: device, section: section) ?? 0)
                            .tag(SidebarRoute.drive(deviceID: device.id, section: section))
                        }
                    } header: {
                        deviceHeader(for: device)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: store.satStatus.isInstalled ? "checkmark.seal.fill" : "questionmark.diamond.fill")
                        .foregroundStyle(store.satStatus.isInstalled ? .green : .yellow)
                    Text(store.satStatus.isInstalled ? "SAT driver detected" : "SAT driver not detected")
                        .lineLimit(1)
                }
                HStack {
                    Text("Last checked:")
                    Spacer()
                    Text(lastCheckedText)
                }
                .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 300)
    }

    private func deviceHeader(for device: SmartDeviceSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: deviceIcon(for: device))
            Text(displayName(for: device))
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(displayName(for: device))
            Spacer(minLength: 8)
            if store.deviceErrors[device.id] != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(store.deviceErrors[device.id] ?? "")
                    .accessibilityLabel(Text("Read error"))
            }
            statusIcon(for: device)
        }
    }

    private var lastCheckedText: String {
        guard let date = store.selectedSnapshot?.checkedAt else { return String(localized: "Never") }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func displayName(for device: SmartDeviceSummary) -> String {
        store.snapshots[device.id]?.modelName ?? device.displayName
    }

    private func deviceIcon(for device: SmartDeviceSummary) -> String {
        if store.snapshots[device.id]?.isRotational == true {
            return "internaldrive"
        }
        return device.type.lowercased() == "nvme" ? "memorychip" : "internaldrive"
    }

    private func icon(for section: DriveSection) -> String {
        switch section {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .indicators: "chart.bar.fill"
        case .errors: "list.bullet.rectangle"
        case .statistics: "tablecells"
        case .selfTests: "play.circle.fill"
        case .history: "chart.xyaxis.line"
        }
    }

    private func color(for section: DriveSection) -> Color {
        switch section {
        case .dashboard: .green
        case .indicators: .orange
        case .errors: .yellow
        case .statistics: .cyan
        case .selfTests: .blue
        case .history: .purple
        }
    }

    private func badgeCount(for device: SmartDeviceSummary, section: DriveSection) -> Int? {
        let snapshot = store.snapshots[device.id]
        return switch section {
        case .dashboard, .history: nil
        case .indicators: snapshot?.attributes.count
        case .errors: snapshot?.errorLog.count
        case .statistics: snapshot?.deviceStatistics.count
        case .selfTests: snapshot?.selfTests.count
        }
    }

    @ViewBuilder
    private func statusIcon(for device: SmartDeviceSummary) -> some View {
        if let state = store.assessments[device.id]?.smartStatus {
            Image(systemName: state == .ok ? "checkmark" : "exclamationmark.triangle.fill")
                .foregroundStyle(stateColor(state))
                .accessibilityLabel(Text(state.rawValue))
        }
    }
}

struct DetailView: View {
    @Environment(DriveStore.self) private var store

    var body: some View {
        Group {
            if store.showFleet {
                FleetView()
            } else if let snapshot = store.selectedSnapshot, let assessment = store.selectedAssessment {
                switch store.selectedSection {
                case .dashboard:
                    DashboardView(snapshot: snapshot, assessment: assessment)
                case .indicators:
                    HealthIndicatorsView(snapshot: snapshot)
                case .errors:
                    ErrorsLogView(snapshot: snapshot)
                case .statistics:
                    DeviceStatisticsView(snapshot: snapshot)
                case .selfTests:
                    SelfTestsView(snapshot: snapshot)
                case .history:
                    HistoryView(snapshot: snapshot)
                }
            } else {
                EmptyStateView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = currentError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.bar)
                    .accessibilityLabel(Text("Error: \(error)"))
            }
        }
    }

    private var currentError: String? {
        if let deviceID = store.selectedDeviceID, let deviceError = store.deviceErrors[deviceID] {
            return deviceError
        }
        return store.lastError
    }
}

struct EmptyStateView: View {
    @Environment(DriveStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text(store.isLoading ? "Checking drives..." : "No SMART-capable drives found")
                .font(.title2.weight(.semibold))
            Text("Backend: \(store.smartctlDescription)")
                .font(.callout)
                .foregroundStyle(.secondary)
            CompatibilityPanel(status: store.satStatus)
                .frame(maxWidth: 680)
        }
        .padding(32)
    }
}

func stateColor(_ state: DriveHealthState) -> Color {
    switch state {
    case .ok: .green
    case .warning: .yellow
    case .failing: .orange
    case .failed: .red
    case .unknown: .secondary
    }
}

/// SF Symbol per health state, so status is conveyed by shape and not colour
/// alone (accessibility / colour-blindness).
func stateIcon(_ state: DriveHealthState) -> String {
    switch state {
    case .ok: "checkmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .failing: "exclamationmark.triangle.fill"
    case .failed: "xmark.octagon.fill"
    case .unknown: "questionmark.circle"
    }
}
