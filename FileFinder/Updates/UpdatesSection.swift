import SwiftUI

/// Its own view so it re-renders as the updater's state changes.
struct UpdatesSection: View {
    let updater: any AppUpdating

    private var automaticChecks: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        )
    }

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: automaticChecks)
            LabeledContent(UpdateCheckPresentation(lastCheck: updater.lastUpdateCheckDate, now: .now).label) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!UpdateCommandEnablement.isEnabled(canCheckForUpdates: updater.canCheckForUpdates))
            }
        }
    }
}
