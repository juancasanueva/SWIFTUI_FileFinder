import Foundation

/// A snapshot of one file-system entry inside a folder listing.
nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Bundles such as `.app` or `.pages`: directories that open as a single document.
    let isPackage: Bool
    let isHidden: Bool
    /// Logical file size in bytes; `nil` for folders (see `FolderSizeCalculator`).
    let size: Int64?
    let modificationDate: Date?
    let creationDate: Date?
    let kind: String

    var id: URL { url }

    /// True when double-clicking should navigate into the item instead of opening it.
    var isNavigable: Bool { isDirectory && !isPackage }

    // Non-optional keys so `Table` columns can sort with `KeyPathComparator`.
    var sortDate: Date { modificationDate ?? .distantPast }
    var sortSize: Int64 { size ?? -1 }

    static let finderOrder = FinderOrder()
}

/// Folders first, then names compared the way Finder does ("b2" before "b10").
nonisolated struct FinderOrder: SortComparator, Hashable, Sendable {
    var order: SortOrder = .forward

    func compare(_ lhs: FileItem, _ rhs: FileItem) -> ComparisonResult {
        if lhs.isNavigable != rhs.isNavigable {
            return lhs.isNavigable ? .orderedAscending : .orderedDescending
        }
        let result = lhs.name.localizedStandardCompare(rhs.name)
        return order == .forward ? result : result.reversed
    }
}

private extension ComparisonResult {
    nonisolated var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
