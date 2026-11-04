import SwiftUI

/// List view: sortable Name / Date Modified / Size / Kind columns.
struct FileListView: View {
    @Bindable var model: BrowserModel
    @FocusState private var isFocused: Bool

    var body: some View {
        Table(of: FileItem.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                nameCell(item)
            }
            .width(min: 180, ideal: 320)

            if model.isShowingWorkspace {
                // A workspace mixes items from different places: show where each one is.
                TableColumn("Location", value: \.locationPath) { item in
                    Text(item.locationPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .width(min: 120, ideal: 220)
            }

            TableColumn("Date Modified", value: \.sortDate) { item in
                Text(item.modificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "--")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Size", value: \.sortSize) { item in
                Text(model.sizeText(for: item))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 90)

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 140)
        } rows: {
            if model.groups.isEmpty {
                ForEach(model.items) { row($0) }
            } else {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.items) { row($0) }
                    } header: {
                        GroupHeader(group: group)
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls, onto: nil)
            return true
        }
        .focused($isFocused)
        .onChange(of: model.focusRequest) { isFocused = true }
        .contextMenu(forSelectionType: URL.self) { urls in
            FileContextMenu(model: model, urls: urls)
        } primaryAction: { urls in
            model.open(urls)
        }
    }

    private func row(_ item: FileItem) -> some TableRowContent<FileItem> {
        TableRow(item)
            .itemProvider { model.beginDrag(item) }
            .dropDestination(for: URL.self) { urls in model.handleDrop(urls, onto: item) }
    }

    private func nameCell(_ item: FileItem) -> some View {
        HStack(spacing: 6) {
            FileIconView(item: item, side: model.iconSize.rowIcon)
            if model.renamingURL == item.url {
                RenameField(item: item) { name in Task { await model.commitRename(item, to: name) } } onCancel: { model.cancelRename() }
            } else {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(item.isHidden ? 0.55 : 1)
            }
        }
    }
}

/// Shared right-click menu for list and card views.
struct FileContextMenu: View {
    let model: BrowserModel
    let urls: Set<URL>

    var body: some View {
        if urls.isEmpty {
            if !model.isShowingWorkspace {
                Button("New Folder") { Task { await model.newFolder() } }
                Button("Paste") { Task { await model.paste() } }.disabled(!model.actions.canPaste)
                Divider()
                DeveloperOpenButtons(model: model, folder: model.currentFolder)
            }
        } else {
            Button("Open") { model.open(urls) }
            if urls.count == 1, let folder = model.items.first(where: { urls.contains($0.url) && $0.isNavigable }) {
                DeveloperOpenButtons(model: model, folder: folder.url)
            }
            Button("Quick Look") {
                model.selection = urls
                model.toggleQuickLook()
            }
            Divider()
            Button("Rename") {
                model.selection = urls
                model.beginRename()
            }
            .disabled(urls.count != 1)
            Button("Copy") {
                model.selection = urls
                model.copySelection()
            }
            Button("Cut") {
                model.selection = urls
                model.cutSelection()
            }
            if !model.isShowingWorkspace {
                Button("Paste") { Task { await model.paste() } }.disabled(!model.actions.canPaste)
            }
            Divider()
            if model.isShowingWorkspace {
                if urls.count == 1, let item = model.items.first(where: { urls.contains($0.url) }) {
                    Button("Show in Enclosing Folder") { model.showInEnclosingFolder(item) }
                }
                Button("Remove from Workspace") {
                    model.selection = urls
                    Task { await model.removeSelectionFromWorkspace() }
                }
            } else {
                AddToWorkspaceMenu(model: model, urls: urls)
                Button("Move to Trash") {
                    model.selection = urls
                    Task { await model.trashSelection() }
                }
            }
        }
    }
}

/// "Open in Terminal" and "Open in <editor>" for one folder.
struct DeveloperOpenButtons: View {
    let model: BrowserModel
    let folder: URL

    var body: some View {
        Button(model.developerTools.openTitle(.terminal)) { model.openInTerminal(folder) }
        Button(model.developerTools.openTitle(.editor)) { model.openInEditor(folder) }
    }
}

/// "Add to Workspace ▸" with every workspace, plus one made from the items.
struct AddToWorkspaceMenu: View {
    let model: BrowserModel
    let urls: Set<URL>

    var body: some View {
        Menu("Add to Workspace") {
            ForEach(model.workspaces.workspaces) { workspace in
                Button(workspace.name) { Task { await model.addToWorkspace(Array(urls), workspace.id) } }
            }
            if !model.workspaces.workspaces.isEmpty { Divider() }
            Button("New Workspace with Selection") {
                let workspace = model.workspaces.create()
                Task { await model.addToWorkspace(Array(urls), workspace.id) }
            }
        }
    }
}
