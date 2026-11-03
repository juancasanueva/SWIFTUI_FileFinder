import AppKit
import SwiftUI

struct SidebarView: View {
    let model: BrowserModel
    @State private var volumes = SidebarLocations.mountedVolumes()

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private var selection: Binding<URL?> {
        Binding(
            get: { model.currentFolder },
            set: { url in if let url { model.navigate(to: url) } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Favorites") {
                ForEach(SidebarLocations.favorites(home: home)) { row($0) }
            }
            Section("Locations") {
                ForEach(SidebarLocations.locations(home: home, volumes: volumes)) { row($0) }
            }
            Section {
                row(SidebarLocations.trash(home: home))
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = SidebarLocations.mountedVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = SidebarLocations.mountedVolumes()
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .tag(item.url)
    }
}
