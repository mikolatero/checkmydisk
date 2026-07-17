import AppKit
import SwiftUI

/// Dropdown shown from the menu-bar status item: per-drive health at a glance plus
/// quick actions. It reads the shared store, so it updates live with the monitor
/// loop even while the main window is closed.
struct MenuBarContentView: View {
    @Environment(DriveStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.devices.isEmpty {
            Text(store.isLoading ? "Checking drives…" : "No SMART-capable drives found")
        } else {
            ForEach(store.devices) { device in
                let state = store.assessments[device.id]?.smartStatus ?? .unknown
                let name = store.snapshots[device.id]?.modelName ?? device.displayName
                Label("\(name) — \(state.rawValue)", systemImage: icon(for: state))
            }
        }

        Divider()

        Button("Open CheckMyDisk") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Refresh Now") {
            store.refreshNow()
        }

        Divider()

        Button("Quit CheckMyDisk") {
            NSApp.terminate(nil)
        }
    }

    private func icon(for state: DriveHealthState) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .warning, .failing: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// The menu-bar status-item icon. Its SF Symbol reflects the worst drive state so
/// the shape — not colour alone — signals that something needs attention.
struct MenuBarLabel: View {
    @Environment(DriveStore.self) private var store

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(Text(store.worstState.rawValue))
    }

    private var symbol: String {
        switch store.worstState {
        case .failed: "xmark.octagon.fill"
        case .warning, .failing: "exclamationmark.triangle.fill"
        default: "internaldrive"
        }
    }
}
