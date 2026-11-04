import SwiftUI

@main
struct FileFinderApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserWindow()
        }
        .commands {
            BrowserCommands()
        }

        Window("Smart Clean", id: SmartCleanWindow.id) {
            SmartCleanWindow()
        }

        Settings {
            SettingsView(tools: .shared)
        }
    }
}
