import SwiftUI

/// One-glance overview of every drive — status, temperature, health, wear and
/// issue count — so a machine with several drives can be triaged at once.
/// Selecting a row opens that drive's dashboard.
struct FleetView: View {
    @Environment(DriveStore.self) private var store
    @State private var selection: SmartDeviceSummary.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("All Drives")
                .font(.headline)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))

            if store.devices.isEmpty {
                EmptyStateView()
            } else {
                Table(store.devices, selection: $selection) {
                    TableColumn("Drive") { device in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.snapshots[device.id]?.modelName ?? device.displayName)
                                .fontWeight(.semibold)
                            Text(device.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 180, ideal: 260)

                    TableColumn("Status") { device in
                        if let state = store.assessments[device.id]?.smartStatus {
                            Label(state.rawValue, systemImage: stateIcon(state))
                                .foregroundStyle(stateColor(state))
                        } else {
                            Text(verbatim: "—").foregroundStyle(.secondary)
                        }
                    }

                    TableColumn("Temperature") { device in
                        Text(store.snapshots[device.id]?.temperature.map { "\($0) °C" } ?? "—")
                    }

                    TableColumn("Health") { device in
                        if store.snapshots[device.id]?.hasBasicHealthData == false {
                            Text(verbatim: "—").foregroundStyle(.secondary)
                        } else {
                            Text(store.assessments[device.id].map { "\($0.overallHealth)%" } ?? "—")
                                .monospacedDigit()
                        }
                    }
                    .width(min: 70, ideal: 90)

                    TableColumn("Lifetime") { device in
                        Text(store.assessments[device.id]?.ssdLifetimeLeft.map { "\($0)%" } ?? "—")
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 90)

                    TableColumn("Issues") { device in
                        let count = store.assessments[device.id]?.issueCount ?? 0
                        Text(count == 0 ? "—" : "\(count)")
                            .foregroundStyle(count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                    .width(min: 60, ideal: 80)
                }
            }
        }
        .onChange(of: selection) { _, id in
            guard let id else { return }
            store.selectedDeviceID = id
            store.selectedSection = .dashboard
            store.showFleet = false
        }
    }
}
