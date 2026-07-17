import AppKit

/// Owns the long-lived app state and starts monitoring at launch, independent of
/// any window. This is what lets health checks and worsening-state notifications
/// keep running once the main window is closed: the app stays resident through its
/// menu-bar item instead of quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = DriveStore()
    let softwareUpdateController = SoftwareUpdateController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.startMonitoring()
    }

    /// Keep the process (and the monitor loop) alive when the last window closes;
    /// the menu-bar item remains the entry point to reopen the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
