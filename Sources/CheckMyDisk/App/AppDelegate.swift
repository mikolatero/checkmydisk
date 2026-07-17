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
        // Skip background monitoring when the app is only hosting unit tests: the
        // test host must launch instantly, and spawning smartctl on the machine's
        // real drives can hang the XCTest runner's connection.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        store.startMonitoring()
    }

    /// Keep the process (and the monitor loop) alive when the last window closes;
    /// the menu-bar item remains the entry point to reopen the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
