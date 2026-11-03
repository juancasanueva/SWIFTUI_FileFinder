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
        window.switchPane()
        let right = window.active
        right.navigate(to: try dir.folder("right"))

        window.toggleSplit()

        #expect(window.active === right)
        #expect(window.panes.count == 1)
    }

    @Test("Tab switches the active pane; with one pane it does nothing")
    func switchPane() {
        let window = makeWindow()
        window.switchPane()
        #expect(window.activeIndex == 0)

        window.toggleSplit()
        window.switchPane()
        #expect(window.activeIndex == 1)
        window.switchPane()
        #expect(window.activeIndex == 0)
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

    @Test("The window state round-trips, restoring both panes and the active one")
    func restoresState() throws {
        let left = try dir.folder("left")
        let right = try dir.folder("right")
        let window = makeWindow()
        window.active.navigate(to: left)
        window.toggleSplit()
        window.switchPane()
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
