import SwiftUI

/// The app's one updater: Sparkle, or `nil` in the unit-test host, which must never reach Sparkle
/// or the network.
enum AppUpdater {
    static let shared: (any AppUpdating)? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? SparkleUpdateChecker(automaticChecks: AutomaticUpdateChecks())
        : nil
}

/// "Check for Updates…" under "About FileFinder" in the app menu.
struct UpdateCommands: Commands {
    let updater: any AppUpdating

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: updater)
        }
    }
}

/// A view of its own so the menu item re-renders as the updater's state changes.
private struct CheckForUpdatesButton: View {
    let updater: any AppUpdating

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!UpdateCommandEnablement.isEnabled(canCheckForUpdates: updater.canCheckForUpdates))
    }
}
