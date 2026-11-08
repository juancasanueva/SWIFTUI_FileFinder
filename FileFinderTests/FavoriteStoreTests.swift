import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Favorite folders")
struct FavoriteStoreTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    private func makeStore() -> FavoriteStore {
        FavoriteStore(defaults: defaults, home: dir.url)
    }

    @Test("Add Favorite puts the folder at the end of Favorites, and it is still there after a relaunch")
    func addsFolder() throws {
        let projects = try dir.folder("Projects")
        let store = makeStore()

        #expect(store.add([projects]) == 1)
        #expect(store.items.map(\.title) == ["Projects"])
        #expect(store.items.map(\.url) == [projects.canonical])
        #expect(store.items.map(\.systemImage) == ["folder"])

        #expect(makeStore().items.map(\.url) == [projects.canonical])
    }

    @Test("A folder already in Favorites, a built-in favorite or a file is not added")
    func skipsDuplicates() throws {
        let projects = try dir.folder("Projects")
        let downloads = try dir.folder("Downloads")
        let file = try dir.file("notes.txt")
        let store = makeStore()
        store.add([projects])

        #expect(store.add([projects, downloads, file, dir.url.appending(path: "missing")]) == 0)
        #expect(store.items.map(\.url) == [projects.canonical])
    }

    @Test("Remove from Favorites takes the folder out, for good")
    func removes() throws {
        let projects = try dir.folder("Projects")
        let clients = try dir.folder("Clients")
        let store = makeStore()
        store.add([projects, clients])

        store.remove(projects)
        #expect(store.items.map(\.title) == ["Clients"])
        #expect(makeStore().items.map(\.title) == ["Clients"])
        #expect(store.contains(clients))
        #expect(!store.contains(projects))
    }
}
