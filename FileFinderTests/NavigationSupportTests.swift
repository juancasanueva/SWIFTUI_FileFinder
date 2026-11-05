import Foundation
import Testing
@testable import FileFinder

@Suite("Path input")
struct PathInputTests {
    @Test("Resolves absolute, home-relative and relative folder paths")
    func resolvesPaths() throws {
        let dir = try TemporaryDirectory()
        let sub = try dir.folder("Projects/App")
        let home = FileManager.default.homeDirectoryForCurrentUser

        #expect(PathInput.resolve(sub.path, relativeTo: dir.url)?.path == sub.path)
        #expect(PathInput.resolve("Projects/App", relativeTo: dir.url)?.path == sub.path)
        #expect(PathInput.resolve("~", relativeTo: dir.url)?.path == home.path)
    }

    @Test("Rejects paths that do not exist or are files")
    func rejectsInvalidPaths() throws {
        let dir = try TemporaryDirectory()
        try dir.file("notes.txt")

        #expect(PathInput.resolve("missing", relativeTo: dir.url) == nil)
        #expect(PathInput.resolve("notes.txt", relativeTo: dir.url) == nil)
        #expect(PathInput.resolve("   ", relativeTo: dir.url) == nil)
    }

    @Test("Tab completes a unique folder prefix, case-insensitively")
    func completesUniquePrefix() throws {
        let dir = try TemporaryDirectory()
        try dir.folder("Documents")
        try dir.file("Docs.txt")

        #expect(PathInput.complete("\(dir.url.path)/doc", relativeTo: dir.url)
                == "\(dir.url.path)/Documents/")
    }

    @Test("Tab extends to the longest common prefix when several folders match")
    func completesCommonPrefix() throws {
        let dir = try TemporaryDirectory()
        try dir.folder("Project-Alpha")
        try dir.folder("Project-Beta")

        #expect(PathInput.complete("Pro", relativeTo: dir.url) == "Project-")
    }

    @Test("Tab leaves the text unchanged when nothing matches")
    func completionWithoutMatch() throws {
        let dir = try TemporaryDirectory()
        #expect(PathInput.complete("zzz", relativeTo: dir.url) == "zzz")
    }

    @Test("Breadcrumbs list every folder from the root down")
    func breadcrumbs() {
        let crumbs = PathInput.breadcrumbs(for: URL(filePath: "/Users/me/Downloads", directoryHint: .isDirectory))
        #expect(crumbs.map(\.path) == ["/", "/Users", "/Users/me", "/Users/me/Downloads"])
    }
}

@Suite("Status bar text")
struct StatusTextTests {
    let english = Locale(identifier: "en_US")

    @Test("Shows item count and free space like the reference app")
    func itemsAndSpace() {
        let text = StatusText.make(itemCount: 21, selectedCount: 0, availableBytes: 304_400_000_000, locale: english)
        #expect(text == "21 items · 304.4 GB available")
    }

    @Test("Uses singular for one item and shows the selection")
    func singularAndSelection() {
        #expect(StatusText.make(itemCount: 1, selectedCount: 0, availableBytes: nil, locale: english) == "1 item")
        #expect(StatusText.make(itemCount: 5, selectedCount: 2, availableBytes: nil, locale: english)
                == "2 of 5 selected")
    }
}

@Suite("Sidebar locations")
struct SidebarLocationsTests {
    @Test("Favorites are Applications first, as in Finder, then Desktop, Documents and Downloads in the user's home")
    func favorites() throws {
        let home = try TemporaryDirectory()
        let items = SidebarLocations.favorites(home: home.url)
        #expect(items.map(\.title) == ["Applications", "Desktop", "Documents", "Downloads"])
        #expect(items.first?.url.path == "/Applications")
        #expect(items.dropFirst().map(\.url) == ["Desktop", "Documents", "Downloads"].map { home.url.appending(path: $0).canonical })
    }

    @Test("Locations include iCloud Drive and cloud providers only when present, plus home and the boot disk")
    func locations() throws {
        let home = try TemporaryDirectory()
        let withoutCloud = SidebarLocations.locations(home: home.url, volumes: [])
        #expect(!withoutCloud.contains { $0.title == "iCloud Drive" })

        try home.folder("Library/Mobile Documents/com~apple~CloudDocs")
        try home.folder("Library/CloudStorage/GoogleDrive-me@example.com")
        let withCloud = SidebarLocations.locations(home: home.url, volumes: [])
        let titles = withCloud.map(\.title)

        #expect(titles.first == "iCloud Drive")
        #expect(titles.contains("Google Drive"))
        #expect(titles.contains(home.url.lastPathComponent))
        #expect(withCloud.contains { $0.url.path == "/" })
    }

    @Test("Trash points at the user's trash folder")
    func trash() throws {
        let home = try TemporaryDirectory()
        #expect(SidebarLocations.trash(home: home.url).url.lastPathComponent == ".Trash")
    }
}

@Suite("Directory watcher")
struct DirectoryWatcherTests {
    @Test("Emits a change when a file is created in the watched folder", .timeLimit(.minutes(1)))
    func emitsOnCreate() async throws {
        let dir = try TemporaryDirectory()
        // The watch starts as soon as the stream is created, before anything iterates it.
        let changes = DirectoryWatcher.changes(of: dir.url, debounce: .milliseconds(50))

        try await confirmation("folder changed") { changed in
            let waiter = Task {
                for await _ in changes { changed(); break }
            }
            try dir.file("new.txt")
            await waiter.value
        }
    }
}

@Suite("Subtree watcher")
struct SubtreeWatcherTests {
    @Test("Maps deep change paths to the direct child folder that contains them")
    func changedChildren() {
        let root = URL(filePath: "/Users/me/Projects")
        let names = SubtreeWatcher.changedChildren(
            paths: [
                "/Users/me/Projects/app/src/main.swift",   // deep inside "app"
                "/Users/me/Projects/web/index.html",       // deep inside "web"
                "/Users/me/Projects/notes.txt",            // direct child: handled by the folder watcher
                "/Users/me/Projects",                      // the folder itself
                "/Users/me/Elsewhere/x",                   // outside
            ],
            in: root)
        #expect(names == ["app", "web"])
    }

    @Test("Works when the watched folder is the root of the disk")
    func changedChildrenAtRoot() {
        let names = SubtreeWatcher.changedChildren(paths: ["/Users/me/file", "/tmp"], in: URL(filePath: "/"))
        #expect(names == ["Users"])
    }

    @Test("Reports a change made deep inside the watched folder", .timeLimit(.minutes(1)))
    func emitsDeepChange() async throws {
        let dir = try TemporaryDirectory()
        try dir.folder("app/src")
        let changes = SubtreeWatcher.changes(of: dir.url, latency: 0.1)

        try await confirmation("deep change") { changed in
            let waiter = Task {
                for await paths in changes where !SubtreeWatcher.changedChildren(paths: paths, in: dir.url).isEmpty {
                    changed()
                    break
                }
            }
            try dir.file("app/src/new.swift")
            await waiter.value
        }
    }
}
