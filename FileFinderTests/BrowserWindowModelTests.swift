import AppKit
import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Dual pane window")
struct BrowserWindowModelTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    private func makeWindow(start: URL? = nil, restoring state: WindowState? = nil) -> BrowserWindowModel {
        let actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        return BrowserWindowModel(
            restoring: state, defaultStart: start ?? dir.url, actions: actions, defaults: defaults)
    }

    @Test("Empty Trash (⇧⌘⌫ or the sidebar) only asks; the Trash's contents are deleted once confirmed, and a pane showing it refreshes")
    func emptyTrash() async throws {
        let trash = try dir.folder(".Trash")
        try dir.file(".Trash/old.txt", bytes: 3)
        try dir.file(".Trash/folder/inner.txt", bytes: 3)
        let actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))),
            trashFolder: trash)
        let window = BrowserWindowModel(defaultStart: trash, actions: actions, defaults: defaults)
        await window.active.reload()
        #expect(window.active.items.count == 2)
        let runner = KeyActionRunner(browser: window.active, window: window)

        #expect(runner.canPerform(.emptyTrash))
        runner.perform(.emptyTrash)
        #expect(window.isConfirmingEmptyTrash)
        #expect(FileManager.default.fileExists(atPath: trash.appending(path: "old.txt").path))

        window.cancelEmptyTrash()
        #expect(!window.isConfirmingEmptyTrash)
        await window.confirmEmptyTrash()   // not asked anymore: nothing happens
        #expect(FileManager.default.fileExists(atPath: trash.appending(path: "old.txt").path))

        window.requestEmptyTrash()
        await window.confirmEmptyTrash()

        #expect(!window.isConfirmingEmptyTrash)
        #expect(FileManager.default.fileExists(atPath: trash.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        #expect(window.active.items.isEmpty)
        #expect(window.active.alertMessage == nil)
    }

    @Test("Empty Trash can't run while typing, so ⇧⌘⌫ stays with the text field")
    func emptyTrashWhileTyping() {
        let window = makeWindow()
        window.active.isEditingPath = true
        #expect(!KeyActionRunner(browser: window.active, window: window).canPerform(.emptyTrash))
    }

    @Test("⌘D splits into two panes on the same folder, and again returns to one")
    func toggleSplit() throws {
        let window = makeWindow()
        #expect(!window.isSplit)

        window.toggleSplit()
        #expect(window.isSplit)
        #expect(window.panes.map(\.currentFolder) == [dir.url.canonical, dir.url.canonical])
        #expect(window.panes[0].actions === window.panes[1].actions)

        window.toggleSplit()
        #expect(!window.isSplit)
    }

    @Test("A new window opens with two panes on the start folder when the setting is on, one when off")
    func twoPanesByDefault() throws {
        #expect(!makeWindow().isSplit)

        defaults.set(true, forKey: BrowserWindowModel.twoPanesByDefaultKey)
        let window = makeWindow()
        #expect(window.isSplit)
        #expect(window.panes.map(\.currentFolder) == [dir.url.canonical, dir.url.canonical])
        #expect(window.activeIndex == 0)
    }

    @Test("A restored window keeps its saved layout whatever the two-pane setting says")
    func restoredLayoutWinsOverSetting() throws {
        defaults.set(true, forKey: BrowserWindowModel.twoPanesByDefaultKey)
        #expect(!makeWindow(restoring: WindowState(folders: [dir.url.path], activeIndex: 0)).isSplit)

        defaults.set(false, forKey: BrowserWindowModel.twoPanesByDefaultKey)
        let split = WindowState(folders: [dir.url.path, dir.url.path], activeIndex: 1)
        #expect(makeWindow(restoring: split).isSplit)
    }

    @Test("Closing the split keeps the active pane")
    func unsplitKeepsActivePane() throws {
        let window = makeWindow()
        window.toggleSplit()
        window.focusPane(at: 1)
        let right = window.active
        right.navigate(to: try dir.folder("right"))

        window.toggleSplit()

        #expect(window.active === right)
        #expect(window.panes.count == 1)
    }

    @Test("⌥⌘← and ⌥⌘→ focus the left and right pane; a missing pane is ignored")
    func focusPane() {
        let window = makeWindow()
        window.focusPane(at: 1)
        #expect(window.activeIndex == 0)

        window.toggleSplit()
        let rightRequests = window.panes[1].focusRequest
        window.focusPane(at: 1)
        #expect(window.activeIndex == 1)
        #expect(window.panes[1].focusRequest == rightRequests + 1)
        window.focusPane(at: 1)
        #expect(window.activeIndex == 1)
        let leftRequests = window.panes[0].focusRequest
        window.focusPane(at: 0)
        #expect(window.activeIndex == 0)
        #expect(window.panes[0].focusRequest == leftRequests + 1)
    }

    @Test("⌥⌘← moves from the right pane to the left one, then to the sidebar; ⌥⌘→ walks back")
    func focusChainThroughSidebar() {
        let window = makeWindow()
        window.toggleSplit()
        window.focusPane(at: 1)

        window.focusLeft()
        #expect(window.activeIndex == 0)
        #expect(window.sidebarFocusRequest == 0)

        window.focusLeft()
        #expect(window.sidebarFocusRequest == 1)
        #expect(window.activeIndex == 0)

        // The sidebar reports its focus; ⌥⌘← there does nothing more.
        window.isSidebarFocused = true
        window.focusLeft()
        #expect(window.sidebarFocusRequest == 1)

        let leftRequests = window.panes[0].focusRequest
        window.focusRight()
        #expect(window.activeIndex == 0)
        #expect(window.panes[0].focusRequest == leftRequests + 1)

        window.isSidebarFocused = false
        window.focusRight()
        #expect(window.activeIndex == 1)
    }

    @Test("Focusing a pane clears a stale sidebar focus, so ⌥⌘← reaches the sidebar again")
    func focusPaneClearsSidebarFocus() {
        let window = makeWindow()
        window.isSidebarFocused = true

        window.focusPane(at: 0)
        #expect(!window.isSidebarFocused)

        window.focusLeft()
        #expect(window.sidebarFocusRequest == 1)
    }

    @Test("With one pane, ⌥⌘← focuses the sidebar and ⌥⌘→ returns to the pane")
    func focusChainSinglePane() {
        let window = makeWindow()
        window.focusLeft()
        #expect(window.sidebarFocusRequest == 1)

        window.isSidebarFocused = true
        let requests = window.panes[0].focusRequest
        window.focusRight()
        #expect(window.panes[0].focusRequest == requests + 1)

        window.isSidebarFocused = false
        window.focusRight()
        #expect(window.activeIndex == 0)
        #expect(window.panes[0].focusRequest == requests + 1)
    }

    @Test("With the sidebar hidden, ⌥⌘← from the left pane has nowhere to go and does nothing")
    func focusLeftWithHiddenSidebar() {
        let window = makeWindow()
        window.isSidebarVisible = false
        #expect(!window.canFocusLeft)
        window.focusLeft()
        #expect(window.sidebarFocusRequest == 0)

        // The right pane can still move to the left one.
        window.toggleSplit()
        window.focusPane(at: 1)
        #expect(window.canFocusLeft)
        window.focusLeft()
        #expect(window.activeIndex == 0)
        #expect(!window.canFocusLeft)

        window.isSidebarVisible = true
        #expect(window.canFocusLeft)
    }

    @Test("In the sidebar, ⌥⌘← has nowhere to go, even when the right pane is active")
    func focusLeftFromSidebar() {
        let window = makeWindow()
        window.toggleSplit()
        window.focusPane(at: 1)
        window.isSidebarFocused = true
        #expect(!window.canFocusLeft)
        window.focusLeft()
        #expect(window.activeIndex == 1)
        #expect(window.sidebarFocusRequest == 0)
    }

    @Test("Hiding the sidebar clears its focus")
    func hidingSidebarClearsFocus() {
        let window = makeWindow()
        window.isSidebarFocused = true
        window.isSidebarVisible = false
        #expect(!window.isSidebarFocused)
    }

    @Test("⌥⌘→ has somewhere to go only with two panes or from the sidebar")
    func canFocusRight() {
        let window = makeWindow()
        #expect(!window.canFocusRight)
        window.isSidebarFocused = true
        #expect(window.canFocusRight)
        window.isSidebarFocused = false
        window.toggleSplit()
        #expect(window.canFocusRight)
    }

    @Test("⌘U swaps the panes; the active pane stays active on its new side")
    func swapPanes() throws {
        let window = makeWindow()
        window.toggleSplit()
        let left = window.panes[0]
        let right = window.panes[1]

        window.swapPanes()

        #expect(window.panes[0] === right)
        #expect(window.panes[1] === left)
        #expect(window.active === left)
        #expect(window.activeIndex == 1)
    }

    @Test("F5 copies the selection into the other pane's folder")
    func copyToOtherPane() async throws {
        let source = try dir.file("left/a.txt", bytes: 3)
        let target = try dir.folder("right")
        let window = makeWindow(start: source.deletingLastPathComponent())
        window.toggleSplit()
        window.panes[1].navigate(to: target)
        await window.panes[0].reload()
        window.panes[0].selection = [source.canonical]

        await window.copyToOtherPane()

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: target.appending(path: "a.txt")).count == 3)
        #expect(window.panes[1].items.map(\.name) == ["a.txt"])
        #expect(window.panes[1].selection == [target.appending(path: "a.txt").canonical])
    }

    // MARK: - Function key bar

    @Test("F7 makes a new folder in the active pane and starts renaming it")
    func f7MakesFolder() async throws {
        let window = makeWindow()
        await window.active.reload()

        await window.perform(.makeFolder)

        let created = dir.url.appending(path: "untitled folder").canonical
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(window.active.selection == [created])
        #expect(window.active.renamingURL == created)
    }

    @Test("F8 moves the active pane's selection to the Trash")
    func f8Trashes() async throws {
        let file = try dir.file("old.log")
        let window = makeWindow()
        await window.active.reload()
        window.active.selection = [file.canonical]

        await window.perform(.delete)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(window.active.items.isEmpty)
    }

    @Test("F9 makes a new Markdown file in the active pane and starts renaming it")
    func f9MakesMarkdownFile() async throws {
        let window = makeWindow()
        await window.active.reload()

        await window.perform(.makeMarkdownFile)

        let created = dir.url.appending(path: "new.md").canonical
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(window.active.selection == [created])
        #expect(window.active.renamingURL == created)
    }

    @Test("F10 makes a new text file in the active pane and starts renaming it")
    func f10MakesTextFile() async throws {
        let window = makeWindow()
        await window.active.reload()

        await window.perform(.makeTextFile)

        let created = dir.url.appending(path: "new.txt").canonical
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(window.active.selection == [created])
        #expect(window.active.renamingURL == created)
    }

    @Test("F9 and F10 are off while a workspace is showing, and make no file there")
    func newFileKeysOffInWorkspace() async throws {
        let store = WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json"))
        let workspace = store.create(named: "W")
        let window = BrowserWindowModel(
            defaultStart: dir.url, actions: FileActions(
                clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())")))),
            defaults: defaults, workspaces: store)
        await window.active.openWorkspace(workspace.id)
        #expect(window.active.isShowingWorkspace)

        #expect(!window.canPerform(.makeMarkdownFile))
        #expect(!window.canPerform(.makeTextFile))

        let before = try FileManager.default.subpathsOfDirectory(atPath: dir.url.path).sorted()
        await window.perform(.makeMarkdownFile)
        await window.perform(.makeTextFile)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: dir.url.path).sorted() == before)
        #expect(window.active.renamingURL == nil)
    }

    @Test("Bar commands are available only when their action can run")
    func barAvailability() async throws {
        let a = try dir.file("a.txt")
        let b = try dir.file("b.txt")
        let window = makeWindow()
        await window.active.reload()

        // Nothing selected, one pane: only Mkdir, New MD and New TXT.
        #expect(FunctionKeyCommand.allCases.filter(window.canPerform) == [.makeFolder, .makeMarkdownFile, .makeTextFile])

        window.active.selection = [a.canonical]
        #expect(FunctionKeyCommand.allCases.filter(window.canPerform) == [.rename, .makeFolder, .delete, .makeMarkdownFile, .makeTextFile])

        window.active.selection = [a.canonical, b.canonical]
        #expect(!window.canPerform(.rename))

        window.toggleSplit()
        window.active.selection = [a.canonical]
        #expect(FunctionKeyCommand.allCases.allSatisfy(window.canPerform))

        window.active.beginRename()
        #expect(!FunctionKeyCommand.allCases.contains(where: window.canPerform))
    }

    @Test("The bar shows F5 Copy and F6 Move only with two panes")
    func copyAndMoveShownOnlyWhenSplit() {
        let window = makeWindow()
        #expect(window.barCommands == [.rename, .makeFolder, .delete, .makeMarkdownFile, .makeTextFile])

        window.toggleSplit()
        #expect(window.barCommands == [.rename, .copy, .move, .makeFolder, .delete, .makeMarkdownFile, .makeTextFile])

        window.toggleSplit()
        #expect(window.barCommands == [.rename, .makeFolder, .delete, .makeMarkdownFile, .makeTextFile])
    }

    @Test("A disabled bar command does nothing")
    func disabledCommandDoesNothing() async throws {
        let file = try dir.file("keep.txt")
        let window = makeWindow()
        await window.active.reload()

        await window.perform(.delete)   // nothing selected
        window.active.selection = [file.canonical]
        window.active.beginRename()
        await window.perform(.delete)   // renaming

        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("The bar shows each command's key from the keymap; F7, F8, F9 and F10 are fixed")
    func barKeyLabels() throws {
        let defaults: [KeyAction: Shortcut] = [
            .rename: try #require(Shortcut("f2")), .copyToOtherPane: try #require(Shortcut("f5")),
            .moveToOtherPane: try #require(Shortcut("f6")),
        ]
        #expect(FunctionKeyCommand.allCases.map { $0.keyLabel(defaults.get) }
            == ["F2", "F5", "F6", "F7", "F8", "F9", "F10"])
        #expect(FunctionKeyCommand.allCases.map(\.title) == ["Rename", "Copy", "Move", "Mkdir", "Delete", "New MD", "New TXT"])

        let rebound: [KeyAction: Shortcut] = [.rename: try #require(Shortcut("cmd+r"))]
        #expect(FunctionKeyCommand.rename.keyLabel(rebound.get) == "⌘R")
        #expect(FunctionKeyCommand.copy.keyLabel(rebound.get) == nil)
    }

    @Test("F6 moves the selection into the other pane's folder")
    func moveToOtherPane() async throws {
        let source = try dir.file("left/a.txt")
        let target = try dir.folder("right")
        let window = makeWindow(start: source.deletingLastPathComponent())
        window.toggleSplit()
        window.panes[1].navigate(to: target)
        await window.panes[0].reload()
        window.panes[0].selection = [source.canonical]

        await window.moveToOtherPane()

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(window.panes[0].items.isEmpty)
        #expect(window.panes[1].items.map(\.name) == ["a.txt"])
    }

    @Test("F6 moves keyboard focus to the other pane, on the moved file")
    func moveToOtherPaneFocusesMovedFile() async throws {
        let source = try dir.file("left/a.txt")
        let target = try dir.folder("right")
        let window = makeWindow(start: source.deletingLastPathComponent())
        window.toggleSplit()
        window.panes[1].navigate(to: target)
        await window.panes[0].reload()
        window.panes[0].selection = [source.canonical]
        let focusRequests = window.panes[1].focusRequest

        await window.moveToOtherPane()

        #expect(window.activeIndex == 1)
        #expect(window.panes[1].focusRequest == focusRequests + 1)
        #expect(window.panes[1].selection == [target.appending(path: "a.txt").canonical])
    }

    @Test("F5 moves keyboard focus to the other pane, on the copied file")
    func copyToOtherPaneFocusesCopiedFile() async throws {
        let source = try dir.file("left/a.txt")
        let target = try dir.folder("right")
        let window = makeWindow(start: source.deletingLastPathComponent())
        window.toggleSplit()
        window.panes[1].navigate(to: target)
        await window.panes[0].reload()
        window.panes[0].selection = [source.canonical]
        let focusRequests = window.panes[1].focusRequest

        await window.copyToOtherPane()

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(window.activeIndex == 1)
        #expect(window.panes[1].focusRequest == focusRequests + 1)
        #expect(window.panes[1].selection == [target.appending(path: "a.txt").canonical])
    }

    @Test("A failed F6 leaves keyboard focus in the source pane")
    func failedMoveToOtherPaneKeepsFocus() async throws {
        let folder = try dir.folder("left/Box")
        let window = makeWindow(start: folder.deletingLastPathComponent())
        window.toggleSplit()
        window.panes[1].navigate(to: try dir.folder("left/Box/inner"))   // into itself
        await window.panes[0].reload()
        window.panes[0].selection = [folder.canonical]

        await window.moveToOtherPane()

        #expect(window.activeIndex == 0)
    }

    @Test("F5 and F6 do nothing with a single pane")
    func transferNeedsTwoPanes() async throws {
        let source = try dir.file("a.txt")
        let window = makeWindow()
        await window.active.reload()
        window.active.selection = [source.canonical]

        await window.copyToOtherPane()
        await window.moveToOtherPane()

        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path) == ["a.txt"])
    }

    @Test("F5 into a folder with a clash asks through the active pane")
    func copyToOtherPaneAsks() async throws {
        let source = try dir.file("left/a.txt", bytes: 1)
        let target = try dir.folder("right")
        try dir.file("right/a.txt", bytes: 2)
        let window = makeWindow(start: source.deletingLastPathComponent())
        window.toggleSplit()
        window.panes[1].navigate(to: target)
        await window.panes[0].reload()
        window.panes[0].selection = [source.canonical]

        let copying = Task { await window.copyToOtherPane() }
        while window.panes[0].pendingConflict == nil { await Task.yield() }
        window.panes[0].answerConflict(ConflictDecision(resolution: .keepBoth))
        await copying.value

        #expect(window.panes[1].items.map(\.name) == ["a 2.txt", "a.txt"])
    }

    @Test("A failed F6 shows the error in the active pane")
    func moveToOtherPaneFailureAlerts() async throws {
        let folder = try dir.folder("left/Box")
        let window = makeWindow(start: folder.deletingLastPathComponent())
        window.toggleSplit()
        window.panes[1].navigate(to: try dir.folder("left/Box/inner"))   // into itself
        await window.panes[0].reload()
        window.panes[0].selection = [folder.canonical]

        await window.moveToOtherPane()

        #expect(window.panes[0].alertMessage != nil)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("Cancelling an F5 copy shows no error")
    func cancelledCopyToOtherPaneIsQuiet() async throws {
        let source = try dir.file("left/a.bin", bytes: 1000)
        let target = try dir.folder("right")
        let actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))),
            copier: { _, _, _, shouldCancel in
                while !shouldCancel() { Thread.sleep(forTimeInterval: 0.01) }
                throw CancellationError()
            })
        let window = BrowserWindowModel(
            restoring: nil, defaultStart: source.deletingLastPathComponent(), actions: actions, defaults: defaults)
        window.toggleSplit()
        window.panes[1].navigate(to: target)
        await window.panes[0].reload()
        window.panes[0].selection = [source.canonical]

        let copying = Task { await window.copyToOtherPane() }
        while actions.currentTransfer == nil { await Task.yield() }
        actions.cancelCurrentTransfer()
        await copying.value

        #expect(window.panes[0].alertMessage == nil)
        #expect(window.panes[1].alertMessage == nil)
    }

    @Test("Closing the split releases a conflict prompt waiting in the closed pane")
    func closingSplitReleasesPrompt() async throws {
        let source = try dir.file("left/a.txt", bytes: 1)
        let target = try dir.folder("right")
        let existing = try dir.file("right/a.txt", bytes: 2)
        let window = makeWindow(start: source.deletingLastPathComponent())
        window.toggleSplit()
        let right = window.panes[1]
        right.navigate(to: target)

        let dropping = Task { await right.drop([source], into: target, copying: true) }
        while right.pendingConflict == nil { await Task.yield() }
        window.toggleSplit()   // the left pane is active, so the right one closes
        _ = await dropping.value

        #expect(try Data(contentsOf: existing).count == 2)
        let later = try await window.actions.copy([source], into: try dir.folder("other"))
        #expect(later.count == 1)
    }

    @Test("The window state round-trips, restoring both panes and the active one")
    func restoresState() throws {
        let left = try dir.folder("left")
        let right = try dir.folder("right")
        let window = makeWindow()
        window.active.navigate(to: left)
        window.toggleSplit()
        window.focusPane(at: 1)
        window.active.navigate(to: right)

        let restored = makeWindow(restoring: try WindowState(encoded: window.state.encoded))

        #expect(restored.panes.map(\.currentFolder) == [left.canonical, right.canonical])
        #expect(restored.activeIndex == 1)
    }

    @Test("A restored pane whose folder is gone falls back to the default start folder")
    func restoreFallsBack() throws {
        let state = WindowState(folders: [dir.url.appending(path: "gone").path, dir.url.path], activeIndex: 0)
        let restored = makeWindow(restoring: state)

        #expect(restored.panes.map(\.currentFolder) == [dir.url.canonical, dir.url.canonical])
    }

    @Test("Undecodable saved state is ignored")
    func badStateIsIgnored() {
        #expect((try? WindowState(encoded: "not json")) == nil)
    }
}

private extension Dictionary where Key == KeyAction, Value == Shortcut {
    func get(_ action: KeyAction) -> Shortcut? { self[action] }
}
