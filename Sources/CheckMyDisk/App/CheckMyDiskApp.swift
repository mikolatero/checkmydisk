import SwiftUI
import UserNotifications

@main
struct CheckMyDiskApp: App {
    @State private var store = DriveStore()
    @State private var softwareUpdateController = SoftwareUpdateController()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(softwareUpdateController)
                .frame(minWidth: 1240, minHeight: 760)
                .task {
                    store.startMonitoring()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)

        Settings {
            PreferencesView()
                .environment(store)
                .environment(softwareUpdateController)
                .frame(width: 520)
        }
    }
}
