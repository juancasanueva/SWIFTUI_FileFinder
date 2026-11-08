import AppKit
import SwiftUI

/// Right-hand preview of the selection: a real preview and details for one item, a two-level
/// look inside a folder, or a summary of several items.
struct PreviewPane: View {
    let model: BrowserModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch model.previewSubject {
                case .item(let item):
                    ItemPreview(model: model, item: item)
                case .multiple(let count, let totalBytes):
                    header(icon: Image(systemName: "doc.on.doc"), title: "\(count) items")
                    DetailRow(label: "Size", value: StatusText.formatBytes(totalBytes))
                case .workspace(let name, let itemCount):
                    header(icon: Image(systemName: "square.stack.3d.up"), title: name)
                    DetailRow(label: "Items", value: itemCount == 1 ? "1 item" : "\(itemCount) items")
                    Text("A workspace gathers items from anywhere. Nothing is copied or moved.")
                        .font(.caption).foregroundStyle(.secondary)
                case .currentFolder(let url, let itemCount):
                    header(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)), title: model.title)
                    DetailRow(label: "Items", value: itemCount == 1 ? "1 item" : "\(itemCount) items")
                    DetailRow(label: "Where", value: url.deletingLastPathComponent().path)
                    FolderContentsPreview(folder: url)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(icon: Image, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            icon.resizable().aspectRatio(contentMode: .fit).frame(width: 64, height: 64)
            Text(title).font(.headline).textSelection(.enabled)
        }
    }
}

private struct ItemPreview: View {
    let model: BrowserModel
    let item: FileItem

    private var icon: some View {
        FileIconView(item: item, side: 220, preview: true)
            .frame(maxWidth: .infinity)
    }

    var body: some View {
        // Text files show their contents where other files show a picture.
        switch item.isNavigable ? nil : TextPreviewKind(url: item.url) {
        case .markdown:
            MarkdownDocumentView(model: model, url: item.url, fallback: AnyView(icon))
        case .code(let language):
            CodePreview(url: item.url, language: language, fallback: AnyView(icon))
        case nil:
            icon
        }
        Text(item.name).font(.headline).textSelection(.enabled)
        Text(item.kind).foregroundStyle(.secondary)
        Divider()
        if item.isNavigable {
            DetailRow(label: "Size", value: model.cardSubtitle(for: item))
        } else {
            DetailRow(label: "Size", value: model.sizeText(for: item))
        }
        if let created = item.creationDate {
            DetailRow(label: "Created", value: created.formatted(date: .abbreviated, time: .shortened))
        }
        if let modified = item.modificationDate {
            DetailRow(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened))
        }
        DetailRow(label: "Where", value: item.url.deletingLastPathComponent().path)
        if item.isNavigable {
            FolderContentsPreview(folder: item.url)
        }
    }
}

/// A folder's contents two levels deep, loaded off the main actor.
private struct FolderContentsPreview: View {
    let folder: URL
    @State private var preview: FolderPreview?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Contents").font(.subheadline.bold())
            if let preview {
                if preview.entries.isEmpty {
                    Text("Empty").foregroundStyle(.secondary)
                }
                ForEach(preview.entries) { entry in
                    row(entry.item, indent: 0)
                    ForEach(entry.children) { child in row(child, indent: 1) }
                    if entry.moreChildren > 0 { more(entry.moreChildren, indent: 1) }
                }
                if preview.moreEntries > 0 { more(preview.moreEntries, indent: 0) }
            } else if failed {
                Text("Can't read this folder.").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: folder) {
            preview = nil
            failed = false
            do { preview = try await Self.load(folder) } catch { failed = true }
        }
    }

    private func row(_ item: FileItem, indent: Int) -> some View {
        HStack(spacing: 6) {
            FileIconView(item: item, side: 16)
            Text(item.name).lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, CGFloat(indent) * 18)
        .font(.callout)
    }

    private func more(_ count: Int, indent: Int) -> some View {
        Text("\(count) more…")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(indent) * 18 + 22)
    }

    @concurrent private nonisolated static func load(_ folder: URL) async throws -> FolderPreview {
        try FolderPreviewLoader.load(folder)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
        }
    }
}
