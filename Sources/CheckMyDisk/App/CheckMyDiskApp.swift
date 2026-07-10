import SwiftUI
import UserNotifications

@main
struct CheckMyDiskApp: App {
    @StateObject private var store = DriveStore()

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    store.startMonitoring()
                }
        }

        Settings {
            PreferencesView()
                .environmentObject(store)
                .frame(width: 520)
        }
    }
}
