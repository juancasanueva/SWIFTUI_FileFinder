import Foundation

/// One entry of a folder preview, with its own contents when it is a folder.
nonisolated struct PreviewEntry: Identifiable, Equatable, Sendable {
    let item: FileItem
    let children: [FileItem]
    /// Visible children beyond the ones shown.
    let moreChildren: Int
    var id: URL { item.url }
}

/// A folder's contents two levels deep, as the preview pane shows it.
nonisolated struct FolderPreview: Equatable, Sendable {
    let entries: [PreviewEntry]
    /// Visible entries beyond the ones shown.
    let moreEntries: Int
}

/// Builds the two-level preview of a folder. Synchronous: call it off the main actor.
nonisolated enum FolderPreviewLoader {
    static func load(_ folder: URL, limit: Int = 12, childLimit: Int = 5) throws -> FolderPreview {
        let all = try DirectoryLister.contents(of: folder, showHidden: false).sorted(using: FileItem.finderOrder)
        let entries = all.prefix(limit).map { item -> PreviewEntry in
            guard item.isNavigable else { return PreviewEntry(item: item, children: [], moreChildren: 0) }
            // An unreadable sub-folder just shows nothing inside.
            let children = ((try? DirectoryLister.contents(of: item.url, showHidden: false)) ?? [])
                .sorted(using: FileItem.finderOrder)
            return PreviewEntry(
                item: item, children: Array(children.prefix(childLimit)),
                moreChildren: max(0, children.count - childLimit))
        }
        return FolderPreview(entries: entries, moreEntries: max(0, all.count - limit))
    }
}
