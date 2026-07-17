import SwiftUI

struct PreferencesView: View {
    @Environment(DriveStore.self) private var store
    @Environment(SoftwareUpdateController.self) private var softwareUpdateController

    var body: some View {
        @Bindable var store = store
        Form {
            Section("smartctl Backend") {
                Picker("Mode", selection: $store.settings.smartctlMode) {
                    ForEach(AppSettings.SmartctlMode.allCases) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                TextField("Custom path", text: $store.settings.customSmartctlPath)
                Text("Active: \(store.smartctlDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Command timeout") {
                    Stepper(value: $store.settings.commandTimeoutSeconds, in: 5...300, step: 5) {
                        Text("\(Int(store.settings.commandTimeoutSeconds)) s")
                    }
                }
            }

            Section("Monitoring While Open") {
                Slider(value: $store.settings.refreshIntervalSeconds, in: 60...1800, step: 60) {
                    Text("Refresh interval")
                } minimumValueLabel: {
                    Text("1m")
                } maximumValueLabel: {
                    Text("30m")
                }
                Text("Every \(Int(store.settings.refreshIntervalSeconds / 60)) minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Local notifications on worsening status", isOn: $store.settings.notificationsEnabled)
            }

            Section("History") {
                LabeledContent("Keep history for") {
                    Stepper(value: $store.settings.historyRetentionDays, in: 7...730, step: 7) {
                        Text("\(store.settings.historyRetentionDays) days")
                    }
                }
                Text("Snapshots are stored on every check and feed the History charts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reports") {
                Toggle("Anonymize serial numbers and WWN in reports", isOn: $store.settings.anonymizeReports)
            }

            Section("Software Updates") {
                Button {
                    softwareUpdateController.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.down.circle")
                }
                .disabled(!softwareUpdateController.canCheckForUpdates)
            }

            Text("Changes are saved automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
