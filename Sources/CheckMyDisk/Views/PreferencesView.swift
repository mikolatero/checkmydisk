import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @Environment(DriveStore.self) private var store
    @Environment(SoftwareUpdateController.self) private var softwareUpdateController
    @State private var helperStatus = HelperClient.shared.status
    @State private var helperError: String?

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            SMAppService.mainApp.status == .enabled
        } set: { enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Registration can fail (e.g. when launched from a non-permanent
                // location); the toggle re-reads the real status on the next render.
            }
        }
    }

    private var helperStatusText: LocalizedStringKey {
        switch helperStatus {
        case .enabled: "Installed"
        case .requiresApproval: "Needs approval in System Settings"
        default: "Not installed"
        }
    }

    private var helperStatusColor: Color {
        switch helperStatus {
        case .enabled: .green
        case .requiresApproval: .orange
        default: .secondary
        }
    }

    private func setHelper(installed: Bool) {
        do {
            if installed {
                try HelperClient.shared.register()
            } else {
                try HelperClient.shared.unregister()
            }
            helperError = nil
        } catch {
            helperError = error.localizedDescription
        }
        helperStatus = HelperClient.shared.status
    }

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

            Section("Privileged Helper") {
                LabeledContent("SATA/USB access with root") {
                    Text(helperStatusText).foregroundStyle(helperStatusColor)
                }
                if helperStatus == .enabled {
                    Button("Remove Helper") { setHelper(installed: false) }
                } else {
                    Button("Install Helper…") { setHelper(installed: true) }
                }
                if let helperError {
                    Text(helperError).font(.caption).foregroundStyle(.red)
                }
                Text("Installs a small privileged tool so smartctl can read SATA/USB drives that require root. Needs approval in System Settings; the app works without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: launchAtLoginBinding)
                Text("Keeps CheckMyDisk in the menu bar to monitor drives in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Monitoring") {
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
                    .onChange(of: store.settings.notificationsEnabled) { _, enabled in
                        if enabled { store.requestNotificationAuthorization() }
                    }
            }

            Section("Scheduled Self-tests") {
                Toggle("Run self-tests automatically", isOn: $store.settings.scheduledSelfTestsEnabled)
                LabeledContent("Short test every") {
                    Stepper(value: $store.settings.shortTestIntervalDays, in: 0...90) {
                        Text(store.settings.shortTestIntervalDays == 0 ? String(localized: "Off") : String(localized: "\(store.settings.shortTestIntervalDays) days"))
                    }
                }
                LabeledContent("Full test every") {
                    Stepper(value: $store.settings.longTestIntervalDays, in: 0...365, step: 5) {
                        Text(store.settings.longTestIntervalDays == 0 ? String(localized: "Off") : String(localized: "\(store.settings.longTestIntervalDays) days"))
                    }
                }
                Text("Runs in the background; results appear in the Self-tests view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
