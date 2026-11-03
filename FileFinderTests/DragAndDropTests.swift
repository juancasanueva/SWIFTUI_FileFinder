import AppKit
import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Drag and drop", .serialized)   // the drag session is app-wide, like a real drag
struct DragAndDropTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults
    let actions: FileActions

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        BrowserModel.endDrag()
    }

    private func pane(at folder: URL) async -> BrowserModel {
        let model = BrowserModel(start: folder, actions: actions, defaults: defaults)
        await model.reload()
        return model
    }

    @Test("Dropping moves the items into the folder")
    func dropMoves() async throws {
        let source = try dir.file("left/a.txt")
        let target = try dir.folder("right")
        let right = await pane(at: target)

        let accepted = await right.drop([source], into: target, copying: false)

        #expect(accepted)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(right.items.map(\.name) == ["a.txt"])
    }

    @Test("Dropping with ⌥ copies the items")
    func dropCopies() async throws {
        let source = try dir.file("left/a.txt")
        let target = try dir.folder("right")
        let right = await pane(at: target)

        _ = await right.drop([source], into: target, copying: true)

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(right.items.map(\.name) == ["a.txt"])
    }

    @Test("Dragging one item of a selection drags the whole selection")
    func dragCarriesSelection() async throws {
        let a = try dir.file("left/a.txt")
        let b = try dir.file("left/b.txt")
        let target = try dir.folder("right")
        let left = await pane(at: a.deletingLastPathComponent())
        let right = await pane(at: target)
        left.selection = [a.canonical, b.canonical]
        let item = try #require(left.items.first { $0.name == "a.txt" })

        _ = left.beginDrag(item)
        _ = await right.drop([a], into: target, copying: false)

        #expect(right.items.map(\.name) == ["a.txt", "b.txt"])
    }

    @Test("Dragging an unselected item drags only that item")
    func dragUnselectedItem() async throws {
        let a = try dir.file("left/a.txt")
        let b = try dir.file("left/b.txt")
        let target = try dir.folder("right")
        let left = await pane(at: a.deletingLastPathComponent())
        let right = await pane(at: target)
        left.selection = [b.canonical]
        let item = try #require(left.items.first { $0.name == "a.txt" })

        _ = left.beginDrag(item)
        _ = await right.drop([a], into: target, copying: false)

        #expect(right.items.map(\.name) == ["a.txt"])
    }

    @Test("Items dropped from another app are used as they are")
    func externalDrop() async throws {
        let a = try dir.file("left/a.txt")
        let target = try dir.folder("right")
        let right = await pane(at: target)
        let other = try dir.file("left/other.txt")
        let left = await pane(at: a.deletingLastPathComponent())
        _ = left.beginDrag(try #require(left.items.first { $0.name == "other.txt" }))

        _ = await right.drop([a], into: target, copying: true)   // not the dragged item: from elsewhere

        #expect(right.items.map(\.name) == ["a.txt"])
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("Dropping a folder onto itself is ignored")
    func dropOntoItself() async throws {
        let folder = try dir.folder("Box")
        let model = await pane(at: dir.url)

        let accepted = await model.drop([folder], into: folder, copying: false)

        #expect(!accepted)
        #expect(model.alertMessage == nil)
    }

    @Test("Dropping onto a folder with a name clash asks")
    func dropAsksOnConflict() async throws {
        let source = try dir.file("left/a.txt", bytes: 1)
        let target = try dir.folder("right")
        try dir.file("right/a.txt", bytes: 2)
        let right = await pane(at: target)

        let dropping = Task { await right.drop([source], into: target, copying: true) }
        while right.pendingConflict == nil { await Task.yield() }
        right.answerConflict(ConflictDecision(resolution: .keepBoth))
        _ = await dropping.value

        #expect(right.items.map(\.name) == ["a 2.txt", "a.txt"])
    }
}
