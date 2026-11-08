import AppKit
import SwiftUI

struct SidebarView: View {
    let model: BrowserModel
    let window: BrowserWindowModel
    var favoriteStore: FavoriteStore = .shared
    @Environment(\.openWindow) private var openWindow
    @State private var favorites: [SidebarItem] = []
    @State private var locations: [SidebarItem] = []
    /// Bumped on every mount/unmount; restarting the refresh task drops older, slower results.
    @State private var volumeChanges = 0

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    @FocusState private var isFocused: Bool
    @State private var highlight = SidebarHighlight()

    private var selection: Binding<BrowserLocation?> {
        Binding(
            get: { highlight.shown(current: model.location) },
            set: { location in
                // The selection changes in the middle of the event that caused it.
                let byKeyboard = NSApp.currentEvent?.type == .keyDown
                if let target = highlight.select(location, byKeyboard: byKeyboard) { open(target) }
            })
    }

    private func open(_ location: BrowserLocation) {
        switch location {
        case .folder(let url): model.navigate(to: url)
        case .workspace(let id): Task { await model.openWorkspace(id) }
        }
    }

    private func handleReturn() -> KeyPress.Result {
        guard let target = highlight.pressReturn() else { return .ignored }
        open(target)
        return .handled
    }

    var body: some View {
        List(selection: selection) {
            Section("Workspaces") {
                ForEach(Array(window.workspaces.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    workspaceRow(workspace, number: index + 1)
                }
                newWorkspaceButton
            }
            Section("Favorites") {
                ForEach(favorites) { row($0) }
                ForEach(favoriteStore.items) { item in
                    row(item)
                        .contextMenu {
                            Button("Remove from Favorites") { favoriteStore.remove(item.url) }
                        }
                }
                addFavoriteButton
            }
            Section("Locations") {
                ForEach(locations) { row($0) }
            }
            Section {
                row(SidebarLocations.trash(home: home))
                Button { openWindow(id: SmartCleanWindow.id) } label: {
                    Label("Smart Clean", systemImage: "sparkles.rectangle.stack")
                }
                .buttonStyle(.plain)
                .help("Space back, safely: nine suggestions, Trash first, with Undo")
            }
        }
        .listStyle(.sidebar)
        .focused($isFocused)
        .onKeyPress(.return, action: handleReturn)
        .onChange(of: window.sidebarFocusRequest) { isFocused = true }
        .onChange(of: isFocused) { _, focused in
            window.isSidebarFocused = focused
            if !focused { highlight.focusLost() }
        }
        // Collapsing the sidebar may remove it without a focus change; don't leave the flag set.
        .onDisappear { window.isSidebarFocused = false }
        .safeAreaInset(edge: .bottom, spacing: 0) { settingsButton }
        .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        .task(id: volumeChanges) { await refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumeChanges += 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumeChanges += 1
        }
    }

    /// Sits below the last workspace, outlined so it reads as an action rather than a row.
    private var newWorkspaceButton: some View {
        sectionButton("New Workspace", help: "New Workspace (⌥⌘N)") { window.requestNewWorkspace() }
    }

    /// Sits below the last favorite; picks one or more folders to add.
    private var addFavoriteButton: some View {
        sectionButton("Add Favorite", help: "Add a folder to Favorites; right-click an added folder to remove it") {
            chooseFavorites()
        }
    }

    private func chooseFavorites() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to add to Favorites"
        if !model.isShowingWorkspace { panel.directoryURL = model.currentFolder }
        guard panel.runModal() == .OK else { return }
        favoriteStore.add(panel.urls)
    }

    /// An outlined action at the end of a sidebar section.
    private func sectionButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(.rect)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.separator, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .selectionDisabled()
        .help(help)
    }

    /// Pinned below the list so it stays put while the sections scroll.
    private var settingsButton: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings (⌘,)")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
