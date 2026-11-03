import AppKit
import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Browsing a workspace")
struct WorkspaceBrowsingTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults
    let store: WorkspaceStore
    let actions: FileActions

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        store = WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json"))
        actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
    }

    private func makePane(start: URL? = nil) -> BrowserModel {
        BrowserModel(start: start ?? dir.url, actions: actions, defaults: defaults, workspaces: store)
    }

    private func names(_ model: BrowserModel) -> [String] { model.items.map(\.name).sorted() }

    @Test("A workspace shows items from different places on one page, with its name as the title")
    func showsGatheredItems() async throws {
        let brief = try dir.file("docs/brief.pdf")
        let brand = try dir.folder("assets/Brand")
        let launch = store.create(named: "Product Launch")
        store.add([brief, brand], to: launch.id)
        let pane = makePane()

        await pane.openWorkspace(launch.id)

        #expect(pane.isShowingWorkspace)
        #expect(pane.title == "Product Launch")
        #expect(names(pane) == ["Brand", "brief.pdf"])
        #expect(pane.statusText == "2 items")
        #expect(!pane.canGoUp)
    }

    @Test("Items that are gone are listed as missing, not as items")
    func missingEntries() async throws {
        let kept = try dir.file("keep.txt")
        let gone = try dir.file("gone.txt")
        let workspace = store.create(named: "W")
        store.add([kept, gone], to: workspace.id)
        try FileManager.default.removeItem(at: gone)
        let pane = makePane()

        await pane.openWorkspace(workspace.id)

        #expect(names(pane) == ["keep.txt"])
        #expect(pane.missingEntries.map(\.name) == ["gone.txt"])
    }

    @Test("Opening a folder from a workspace goes into it, and Back returns to the workspace")
    func backReturnsToWorkspace() async throws {
        let brand = try dir.folder("assets/Brand")
        let workspace = store.create(named: "W")
        store.add([brand], to: workspace.id)
        let pane = makePane()
        await pane.openWorkspace(workspace.id)

        pane.open([brand.canonical])
        #expect(!pane.isShowingWorkspace)
        #expect(pane.currentFolder == brand.canonical)

        pane.goBack()
        #expect(pane.isShowingWorkspace)
        #expect(pane.workspaceID == workspace.id)
    }

    @Test("Remove from Workspace (⌘⌫) removes the entries and never trashes the files")
    func removeNeverTrashes() async throws {
        let brief = try dir.file("brief.pdf")
        let workspace = store.create(named: "W")
        store.add([brief], to: workspace.id)
        let pane = makePane()
        await pane.openWorkspace(workspace.id)
        pane.selection = [brief.canonical]

        await pane.trashSelection()

        #expect(FileManager.default.fileExists(atPath: brief.path))
        #expect(store.workspace(workspace.id)?.entries.isEmpty == true)
        #expect(pane.items.isEmpty)
    }

    @Test("Paste and New Folder do nothing in a workspace")
    func folderOnlyOperations() async throws {
        let source = try dir.file("a/x.txt")
        let workspace = store.create(named: "W")
        let pane = makePane()
        await pane.openWorkspace(workspace.id)
        actions.copyToClipboard([source])

        await pane.paste()
        await pane.newFolder()

        #expect(pane.items.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted() == ["a", "store"])
    }

    @Test("Dropping items onto a workspace adds them; nothing is copied or moved")
    func dropAdds() async throws {
        let brief = try dir.file("docs/brief.pdf")
        let workspace = store.create(named: "W")
        let pane = makePane()
        await pane.openWorkspace(workspace.id)

        await pane.addToWorkspace([brief], workspace.id)

        #expect(FileManager.default.fileExists(atPath: brief.path))
        #expect(names(pane) == ["brief.pdf"])
    }

    @Test("F5 into a pane showing a workspace adds the items instead of copying them")
    func copyToWorkspacePane() async throws {
        let source = try dir.file("left/a.txt")
        let workspace = store.create(named: "W")
        let window = BrowserWindowModel(
            restoring: nil, defaultStart: source.deletingLastPathComponent(), actions: actions,
            defaults: defaults, workspaces: store)
        window.toggleSplit()
        await window.panes[1].openWorkspace(workspace.id)
        await window.panes[0].reload()
        window.panes[0].selection = [source.canonical]

        await window.copyToOtherPane()
        await window.moveToOtherPane()

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path) == ["a.txt"])
        #expect(store.workspace(workspace.id)?.entries.count == 1)
    }

    @Test("If the open workspace is deleted, the pane goes back to its folder")
    func deletedWhileOpen() async throws {
        let workspace = store.create(named: "W")
        let pane = makePane()
        await pane.openWorkspace(workspace.id)

        store.delete(workspace.id)
        await pane.reload()

        #expect(!pane.isShowingWorkspace)
        #expect(pane.currentFolder == dir.url.canonical)
    }
}
