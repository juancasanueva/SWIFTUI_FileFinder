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

    @Test("Show in Enclosing Folder opens the item's real folder with it selected")
    func showInEnclosingFolder() async throws {
        let brief = try dir.file("docs/brief.pdf")
        let workspace = store.create(named: "W")
        store.add([brief], to: workspace.id)
        let pane = makePane()
        await pane.openWorkspace(workspace.id)
        let item = try #require(pane.items.first)

        pane.showInEnclosingFolder(item)

        #expect(!pane.isShowingWorkspace)
        #expect(pane.currentFolder == brief.deletingLastPathComponent().canonical)
        #expect(pane.selection == [item.url])
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

@MainActor
@Suite("Workspace window state")
struct WorkspaceWindowStateTests {
    @Test("A pane showing a workspace is restored after relaunch")
    func restoresWorkspacePane() async throws {
        let dir = try TemporaryDirectory()
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let store = WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json"))
        let doc = try dir.file("docs/brief.pdf")
        let workspace = store.create(named: "Launch")
        store.add([doc], to: workspace.id)
        let window = BrowserWindowModel(restoring: nil, defaultStart: dir.url, defaults: defaults, workspaces: store)
        window.toggleSplit()
        await window.panes[1].openWorkspace(workspace.id)

        let encoded = window.state.encoded
        let restored = BrowserWindowModel(
            restoring: try WindowState(encoded: encoded), defaultStart: dir.url, defaults: defaults, workspaces: store)
        await restored.panes[1].reload()

        #expect(!restored.panes[0].isShowingWorkspace)
        #expect(restored.panes[1].workspaceID == workspace.id)
        #expect(restored.panes[1].items.map(\.name) == ["brief.pdf"])
    }

    @Test("A restored pane whose workspace was deleted shows its folder")
    func deletedWorkspaceFallsBack() throws {
        let dir = try TemporaryDirectory()
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let store = WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json"))
        let state = WindowState(folders: [dir.url.path], activeIndex: 0, workspaces: [UUID().uuidString])

        let restored = BrowserWindowModel(restoring: state, defaultStart: dir.url, defaults: defaults, workspaces: store)

        #expect(!restored.panes[0].isShowingWorkspace)
    }

    @Test("State saved before workspaces existed still restores")
    func oldStateStillDecodes() throws {
        let state = try WindowState(encoded: #"{"folders":["/tmp"],"activeIndex":0}"#)
        #expect(state.workspaces == [nil])
    }
}

@MainActor
@Suite("Workspace commands")
struct WorkspaceCommandTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults
    let store: WorkspaceStore

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        store = WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json"))
    }

    private func makeWindow() -> BrowserWindowModel {
        BrowserWindowModel(restoring: nil, defaultStart: dir.url, defaults: defaults, workspaces: store)
    }

    @Test("⌥⌘N asks for a name, then creates the workspace and opens it in the active pane")
    func newWorkspace() async throws {
        let window = makeWindow()

        window.requestNewWorkspace()
        #expect(window.namingRequest == .create)
        await window.finishNaming("Japan Trip")

        #expect(window.namingRequest == nil)
        #expect(store.workspaces.map(\.name) == ["Japan Trip"])
        #expect(window.active.workspaceID == store.workspaces.first?.id)
    }

    @Test("Renaming goes through the same sheet")
    func renameWorkspace() async throws {
        let window = makeWindow()
        let workspace = store.create(named: "Old")

        window.requestRename(workspace.id)
        #expect(window.namingRequest == .rename(workspace.id))
        await window.finishNaming("New")

        #expect(store.workspace(workspace.id)?.name == "New")
    }

    @Test("⌃1–⌃9 open the workspaces in sidebar order; numbers past the list do nothing")
    func openByNumber() async throws {
        let window = makeWindow()
        let first = store.create(named: "A")
        let second = store.create(named: "B")

        await window.openWorkspace(number: 2)
        #expect(window.active.workspaceID == second.id)
        await window.openWorkspace(number: 1)
        #expect(window.active.workspaceID == first.id)
        await window.openWorkspace(number: 9)
        #expect(window.active.workspaceID == first.id)
    }

    @Test("Deleting a workspace sends every pane showing it back to its folder, and keeps the files")
    func deleteWorkspace() async throws {
        let doc = try dir.file("brief.pdf")
        let workspace = store.create(named: "W")
        store.add([doc], to: workspace.id)
        let window = makeWindow()
        window.toggleSplit()
        await window.panes[0].openWorkspace(workspace.id)
        await window.panes[1].openWorkspace(workspace.id)

        await window.deleteWorkspace(workspace.id)

        #expect(window.panes.allSatisfy { !$0.isShowingWorkspace })
        #expect(FileManager.default.fileExists(atPath: doc.path))
    }

    @Test("Add to Workspace from a folder adds the selection without moving it")
    func addSelectionToWorkspace() async throws {
        let doc = try dir.file("brief.pdf")
        let workspace = store.create(named: "W")
        let window = makeWindow()
        await window.active.reload()
        window.active.selection = [doc.canonical]

        await window.active.addToWorkspace(window.active.selectedURLs, workspace.id)

        #expect(store.workspace(workspace.id)?.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: doc.path))
    }
}
