import SwiftUI

/// List view: sortable Name / Date Modified / Size / Kind columns.
struct FileListView: View {
    @Bindable var model: BrowserModel

    var body: some View {
        Table(model.items, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                nameCell(item)
            }
            .width(min: 180, ideal: 320)

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
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            FileContextMenu(model: model, urls: urls)
        } primaryAction: { urls in
            model.open(urls)
        }
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
            Button("New Folder") { Task { await model.newFolder() } }
            Button("Paste") { Task { await model.paste() } }.disabled(!model.actions.canPaste)
        } else {
            Button("Open") { model.open(urls) }
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
            Button("Paste") { Task { await model.paste() } }.disabled(!model.actions.canPaste)
            Divider()
            Button("Move to Trash") {
                model.selection = urls
                Task { await model.trashSelection() }
            }
        }
    }
}
