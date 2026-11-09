import AppKit
import SwiftUI

/// Column view, like Finder's: one column per folder from where browsing started down to the
/// current folder. The current folder's column is the live one (selection, rename, menus);
/// the columns before it show the way here, and the column after it shows what is selected.
struct ColumnBrowserView: View {
    @Bindable var model: BrowserModel
    static let columnWidth: CGFloat = 230

    var body: some View {
        let folders = model.columnFolders
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(folders.dropLast().enumerated()), id: \.element) { index, folder in
                        // The column shows the next folder on the way selected.
                        PathColumn(folder: folder, selected: folders[index + 1], showHidden: model.showHidden) { url in
                            model.reveal(url)
                        }
                        Divider()
                    }
                    CurrentColumn(model: model)
                    Divider()
                    selectionColumn
                    Color.clear.frame(width: 1).id(Self.endID)
                }
            }
            .onAppear { proxy.scrollTo(Self.endID, anchor: .trailing) }
            .onChange(of: folders) { proxy.scrollTo(Self.endID, anchor: .trailing) }
            // A newly selected item opens a column at the end; other changes leave the scroll alone.
            .onChange(of: model.selection) { _, selection in
                if selection.count == 1 { proxy.scrollTo(Self.endID, anchor: .trailing) }
            }
        }
    }

    private static let endID = "end"

    /// After the current column: a selected folder's contents, or a selected file's details.
    @ViewBuilder
    private var selectionColumn: some View {
        if model.selection.count == 1, let item = model.selectedItems.first {
            if item.isNavigable {
                PathColumn(folder: item.url, selected: nil, showHidden: model.showHidden) { url in
                    model.reveal(url)
                }
                .id(item.url)  // a new folder's column never shows the last one's items
                Divider()
            } else {
                FileDetailsColumn(model: model, item: item)
                Divider()
            }
        }
    }
}

/// The current folder: selectable like the list view, with ↑↓ to move, → to enter a folder
/// and ← to go back up.
private struct CurrentColumn: View {
    @Bindable var model: BrowserModel
    @FocusState private var isFocused: Bool

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                ColumnRow(item: item, iconSide: model.iconSize.rowIcon, renameField: renameField(item))
                .tag(item.url)
                .itemProvider { model.beginDrag(item) }
            }
        }
        .listStyle(.plain)
        .frame(width: ColumnBrowserView.columnWidth)
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onChange(of: model.focusRequest) { isFocused = true }
        .onKeyPress(.rightArrow) {
            guard !model.isTyping else { return .ignored }
            return model.enterSelectedFolderSelectingFirst() ? .handled : .ignored
        }
        .onKeyPress(.leftArrow) {
            guard !model.isTyping, model.canGoUp else { return .ignored }
            model.goUp()
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls, onto: nil)
            return true
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            FileContextMenu(model: model, urls: urls)
        } primaryAction: { urls in
            model.open(urls)
        }
    }

    private func renameField(_ item: FileItem) -> AnyView? {
        guard model.renamingURL == item.url else { return nil }
        return AnyView(RenameField(item: item) { name in Task { await model.commitRename(item, to: name) } } onCancel: {
            model.cancelRename()
        })
    }
}

/// A folder before or after the current one, read-only. Clicking an item opens its folder with
/// the item selected.
private struct PathColumn: View {
    let folder: URL
    let selected: URL?
    let showHidden: Bool
    let onPick: (URL) -> Void
    @State private var items: [FileItem] = []
    @State private var failed = false

    var body: some View {
        List(selection: Binding(get: { selected }, set: { url in if let url { onPick(url) } })) {
            ForEach(items) { item in
                ColumnRow(item: item, iconSide: 16)
                    .tag(item.url)
                    // Also for the highlighted row, whose click doesn't change the selection.
                    .simultaneousGesture(TapGesture().onEnded { onPick(item.url) })
            }
        }
        .listStyle(.plain)
        .overlay {
            if failed {
                Text("Can't open this folder").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: ColumnBrowserView.columnWidth)
        .task(id: "\(folder.path)|\(showHidden)") {
            do {
                items = try await Self.load(folder, showHidden: showHidden)
                failed = false
            } catch {
                items = []
                failed = true
            }
        }
    }

    @concurrent private nonisolated static func load(_ folder: URL, showHidden: Bool) async throws -> [FileItem] {
        try DirectoryLister.contents(of: folder, showHidden: showHidden).sorted(using: FileItem.finderOrder)
    }
}

/// One row: icon, name (or the rename field) and a chevron for folders.
private struct ColumnRow: View {
    let item: FileItem
    let iconSide: CGFloat
    var renameField: AnyView?

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(item: item, side: iconSide, preview: true)
            if let renameField {
                renameField
            } else {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(item.isHidden ? 0.55 : 1)
            }
            Spacer(minLength: 4)
            if item.isNavigable {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// The last column when a file is selected: a preview and the basics.
private struct FileDetailsColumn: View {
    let model: BrowserModel
    let item: FileItem

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                FileIconView(item: item, side: 140, preview: true)
                Text(item.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text(item.kind).font(.caption).foregroundStyle(.secondary)
                Text(model.sizeText(for: item)).font(.caption).foregroundStyle(.secondary)
                if let modified = item.modificationDate {
                    Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
        }
        .frame(width: ColumnBrowserView.columnWidth + 40)
    }
}
