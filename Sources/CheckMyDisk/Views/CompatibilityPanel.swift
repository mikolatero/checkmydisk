import SwiftUI

struct CompatibilityPanel: View {
    let status: SATSupportStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("External USB / FireWire SMART", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                Text(status.isInstalled ? "Driver detected" : "Driver not detected")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(status.isInstalled ? .green : .yellow)
            }

            HStack(spacing: 18) {
                statusPill("SATSMARTDriver.kext", ok: status.kextInstalled)
                statusPill("SATSMARTLib.plugin", ok: status.pluginInstalled)
                statusPill("\(status.iokitCapableDevices) capable device(s)", ok: status.iokitCapableDevices > 0)
            }

            Text("macOS does not expose SMART data for many USB/SAT enclosures by default. CheckMyDisk will read any external drive that smartctl can see, and can use pass-through modes such as sat, sat12, sat16, jmicron, or auto when the driver/enclosure supports them.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Link("SAT SMART Driver project", destination: URL(string: "https://github.com/kasbert/OS-X-SAT-SMART-Driver")!)
                .font(.callout.weight(.semibold))
        }
    }

    private func statusPill(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "questionmark.circle.fill")
            .font(.caption)
            .foregroundStyle(ok ? .green : .yellow)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5))
            .clipShape(Capsule())
    }
}
