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
