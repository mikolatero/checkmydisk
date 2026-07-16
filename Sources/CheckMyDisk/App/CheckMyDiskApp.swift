import SwiftUI
import UserNotifications

@main
struct CheckMyDiskApp: App {
    @StateObject private var store = DriveStore()
    @StateObject private var softwareUpdateController = SoftwareUpdateController()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(softwareUpdateController)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    store.startMonitoring()
                }
        }

        Settings {
            PreferencesView()
                .environmentObject(store)
                .environmentObject(softwareUpdateController)
                .frame(width: 520)
        }
    }
}
