import AppKit
import SwiftUI

struct SidebarView: View {
    let model: BrowserModel
    let window: BrowserWindowModel
    @State private var favorites: [SidebarItem] = []
    @State private var locations: [SidebarItem] = []
    /// Bumped on every mount/unmount; restarting the refresh task drops older, slower results.
    @State private var volumeChanges = 0

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private var selection: Binding<BrowserLocation?> {
        Binding(
            get: { model.location },
            set: { location in
                switch location {
                case .folder(let url): model.navigate(to: url)
                case .workspace(let id): Task { await model.openWorkspace(id) }
                case nil: break
                }
            })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(Array(window.workspaces.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    workspaceRow(workspace, number: index + 1)
                }
            } header: {
                HStack {
                    Text("Workspaces")
                    Spacer()
                    Button("New Workspace", systemImage: "plus") { window.requestNewWorkspace() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("New Workspace (⌥⌘N)")
                }
            }
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
        .task(id: volumeChanges) { await refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumeChanges += 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumeChanges += 1
        }
    }

    /// Builds the sections off the main actor: it touches the disk (cloud folders, volume names).
    private func refresh() async {
        let home = home
        let sections = await Self.sections(home: home)
        guard !Task.isCancelled else { return }  // a newer refresh is on its way
        (favorites, locations) = sections
    }

    @concurrent private nonisolated static func sections(home: URL) async -> ([SidebarItem], [SidebarItem]) {
        (SidebarLocations.favorites(home: home),
         SidebarLocations.locations(home: home, volumes: SidebarLocations.mountedVolumes()))
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .tag(BrowserLocation.folder(item.url))
    }

    private func workspaceRow(_ workspace: Workspace, number: Int) -> some View {
        Label(workspace.name, systemImage: "square.stack.3d.up")
            .badge(number <= 9 ? Text("⌃\(number)").font(.caption2) : nil)
            .tag(BrowserLocation.workspace(workspace.id))
            // Dropping items onto a workspace adds them; nothing is copied or moved.
            .dropDestination(for: URL.self) { urls, _ in
                Task { await model.addToWorkspace(BrowserModel.draggedItems(for: urls), workspace.id) }
                return true
            }
            .contextMenu {
                Button("Rename…") { window.requestRename(workspace.id) }
                Button("Delete Workspace") { Task { await window.deleteWorkspace(workspace.id) } }
            }
    }
}
