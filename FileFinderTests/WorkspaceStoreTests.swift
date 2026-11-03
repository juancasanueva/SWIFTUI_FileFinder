import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Workspace store")
struct WorkspaceStoreTests {
    let dir: TemporaryDirectory
    let storeFile: URL

    init() throws {
        dir = try TemporaryDirectory()
        storeFile = dir.url.appending(path: "store/workspaces.json")
    }

    private func makeStore() -> WorkspaceStore { WorkspaceStore(fileURL: storeFile) }

    @Test("New workspaces get Untitled names; names are trimmed and can't be emptied")
    func naming() throws {
        let store = makeStore()
        let first = store.create()
        let second = store.create()
        #expect(first.name == "Untitled Workspace")
        #expect(second.name == "Untitled Workspace 2")

        store.rename(first.id, to: "  Taxes 2026  ")
        #expect(store.workspace(first.id)?.name == "Taxes 2026")
        store.rename(first.id, to: "   ")
        #expect(store.workspace(first.id)?.name == "Taxes 2026")

        #expect(store.create(named: "Japan Trip").name == "Japan Trip")
    }

    @Test("Adding gathers items from anywhere without copying or moving them; duplicates are skipped")
    func addEntries() throws {
        let store = makeStore()
        let workspace = store.create(named: "Launch")
        let doc = try dir.file("docs/brief.pdf", bytes: 3)
        let folder = try dir.folder("assets/Brand")

        #expect(store.add([doc, folder], to: workspace.id) == 2)
        #expect(store.add([doc], to: workspace.id) == 0)

        let entries = try #require(store.workspace(workspace.id)?.entries)
        #expect(entries.compactMap { store.resolve($0)?.lastPathComponent } == ["brief.pdf", "Brand"])
        #expect(FileManager.default.fileExists(atPath: doc.path))
        #expect(try Data(contentsOf: doc).count == 3)
    }

    @Test("Removing entries and deleting a workspace never touch the files")
    func removeAndDelete() throws {
        let store = makeStore()
        let workspace = store.create(named: "Launch")
        let doc = try dir.file("brief.pdf")
        let other = try dir.file("notes.txt")
        store.add([doc, other], to: workspace.id)
        let first = try #require(store.workspace(workspace.id)?.entries.first)

        store.remove([first.id], from: workspace.id)
        #expect(store.workspace(workspace.id)?.entries.count == 1)

        store.delete(workspace.id)
        #expect(store.workspaces.isEmpty)
        #expect(FileManager.default.fileExists(atPath: doc.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("Workspaces persist across launches")
    func persistence() throws {
        let doc = try dir.file("brief.pdf")
        let store = makeStore()
        let workspace = store.create(named: "Launch")
        store.add([doc], to: workspace.id)

        let reopened = makeStore()

        #expect(reopened.workspaces.map(\.name) == ["Launch"])
        let entry = try #require(reopened.workspaces.first?.entries.first)
        #expect(reopened.resolve(entry)?.path == doc.resolvingSymlinksInPath().path)
    }

    @Test("An entry follows its item when it is moved or renamed")
    func followsMoves() throws {
        let store = makeStore()
        let workspace = store.create(named: "Launch")
        let doc = try dir.file("brief.pdf")
        store.add([doc], to: workspace.id)
        let moved = try dir.folder("archive").appending(path: "brief-final.pdf")
        try FileManager.default.moveItem(at: doc, to: moved)

        let entry = try #require(store.workspace(workspace.id)?.entries.first)

        #expect(store.resolve(entry)?.lastPathComponent == "brief-final.pdf")
        #expect(store.workspace(workspace.id)?.entries.first?.path.hasSuffix("archive/brief-final.pdf") == true)
    }

    @Test("An entry whose item is gone resolves to nothing")
    func missingItem() throws {
        let store = makeStore()
        let workspace = store.create(named: "Launch")
        let doc = try dir.file("brief.pdf")
        store.add([doc], to: workspace.id)
        try FileManager.default.removeItem(at: doc)

        let entry = try #require(store.workspace(workspace.id)?.entries.first)

        #expect(store.resolve(entry) == nil)
        #expect(entry.name == "brief.pdf")   // still shown by its last known name
    }

    @Test("A damaged store file is set aside, not overwritten")
    func corruptFile() throws {
        try FileManager.default.createDirectory(at: storeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storeFile)

        let store = makeStore()
        #expect(store.workspaces.isEmpty)
        store.create(named: "Fresh")

        let backups = try FileManager.default.contentsOfDirectory(atPath: storeFile.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("workspaces.json.damaged") }
        #expect(backups.count == 1)
    }
}
