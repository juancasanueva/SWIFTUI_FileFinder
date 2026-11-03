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
    }
}
