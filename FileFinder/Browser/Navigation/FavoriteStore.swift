import Foundation

/// Folders the user added to the sidebar's Favorites, below the built-in ones.
/// Shared by every window and kept in UserDefaults.
@Observable
final class FavoriteStore {
    static let shared = FavoriteStore()
    static let defaultsKey = "favoriteFolders"

    private(set) var folders: [URL]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let home: URL

    init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        self.home = home
        folders = (defaults.stringArray(forKey: Self.defaultsKey) ?? []).map { URL(filePath: $0).canonical }
    }

    /// The added folders as sidebar rows, in the order they were added.
    var items: [SidebarItem] {
        folders.map { url in
            SidebarItem(
                title: FileManager.default.displayName(atPath: url.path), systemImage: "folder", url: url)
        }
    }

    func contains(_ url: URL) -> Bool {
        folders.contains(url.canonical)
    }

    /// Adds the folders that aren't in Favorites yet, built-in ones included; files and missing
    /// folders are skipped. Returns how many were added.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        let builtIn = Set(SidebarLocations.favorites(home: home).map(\.url))
        var added = 0
        for url in urls.map(\.canonical) where !folders.contains(url) && !builtIn.contains(url) && Self.isFolder(url) {
            folders.append(url)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    func remove(_ url: URL) {
        let count = folders.count
        folders.removeAll { $0 == url.canonical }
        if folders.count != count { save() }
    }

    private func save() {
        defaults.set(folders.map(\.path), forKey: Self.defaultsKey)
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
