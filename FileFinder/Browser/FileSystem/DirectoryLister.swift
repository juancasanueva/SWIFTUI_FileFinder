import Foundation

/// Reads the direct children of a folder into `FileItem` snapshots.
nonisolated enum DirectoryLister {
    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .localizedTypeDescriptionKey, .addedToDirectoryDateKey,
    ]

    static func contents(of folder: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: resourceKeys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        return urls.compactMap(item(at:))
    }

    static func item(at url: URL) -> FileItem? {
        guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        let isDirectory = values.isDirectory ?? false
        return FileItem(
            url: url.canonical,
            name: values.name ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: values.isPackage ?? false,
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
            size: isDirectory ? nil : Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate,
            creationDate: values.creationDate,
            kind: values.localizedTypeDescription ?? (isDirectory ? "Folder" : "Document"),
            dateAdded: values.addedToDirectoryDate
        )
    }
}
