import AppKit
import SwiftUI

struct SidebarView: View {
    let model: BrowserModel
    @State private var favorites: [SidebarItem] = []
    @State private var locations: [SidebarItem] = []

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private var selection: Binding<URL?> {
        Binding(
            get: { model.currentFolder },
            set: { url in if let url { model.navigate(to: url) } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Favorites") {
                ForEach(favorites) { row($0) }
            }
            Section("Locations") {
                ForEach(locations) { row($0) }
            }
            Section {
                row(SidebarLocations.trash(home: home))
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        .task { await refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await refresh() }
        }
    }

    /// Builds the sections off the main actor: it touches the disk (cloud folders, volume names).
    private func refresh() async {
        let home = home
        (favorites, locations) = await Self.sections(home: home)
    }

    @concurrent private nonisolated static func sections(home: URL) async -> ([SidebarItem], [SidebarItem]) {
        (SidebarLocations.favorites(home: home),
         SidebarLocations.locations(home: home, volumes: SidebarLocations.mountedVolumes()))
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .tag(item.url)
    }
}
