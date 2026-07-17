import SwiftUI

@main
struct CheckMyDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("CheckMyDisk", id: "main") {
            ContentView()
                .environment(appDelegate.store)
                .environment(appDelegate.softwareUpdateController)
                .frame(minWidth: 1240, minHeight: 760)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContentView()
                .environment(appDelegate.store)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.store)
        }

        Settings {
            PreferencesView()
                .environment(appDelegate.store)
                .environment(appDelegate.softwareUpdateController)
                .frame(width: 520)
        }
    }
}
