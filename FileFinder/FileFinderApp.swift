import SwiftUI

@main
struct FileFinderApp: App {
    private let updater = AppUpdater.shared

    var body: some Scene {
        WindowGroup {
            BrowserWindow()
        }
        .commands {
            BrowserCommands()
            if let updater { UpdateCommands(updater: updater) }
        }

        Window("Smart Clean", id: SmartCleanWindow.id) {
            SmartCleanWindow()
        }

        Settings {
            SettingsView(tools: .shared, updater: updater)
        }
    }
}
