import Foundation
import Testing
@testable import FileFinder

/// Card grid of 7 items in 3 columns:
///   a b c
///   d e f
///   g
@MainActor
@Suite("Card view arrow keys")
struct SelectionMovementTests {
    let dir: TemporaryDirectory
    let model: BrowserModel

    init() async throws {
        dir = try TemporaryDirectory()
        for name in ["a", "b", "c", "d", "e", "f", "g"] { try dir.file("\(name).txt") }
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        model = BrowserModel(start: dir.url, defaults: defaults)
        await model.reload()
    }

    private func select(_ name: String) {
        model.click(try! #require(model.items.first { $0.name == "\(name).txt" }), modifiers: [])
    }

    private var selectedNames: [String] {
        model.selectedItems.map { String($0.name.dropLast(4)) }
    }

    @Test("Right and left move by one item")
    func horizontal() {
        select("b")
        model.moveSelection(.right, columns: 3, extending: false)
        #expect(selectedNames == ["c"])
        model.moveSelection(.right, columns: 3, extending: false)
        #expect(selectedNames == ["d"])   // wraps to the next row, like Finder
        model.moveSelection(.left, columns: 3, extending: false)
        #expect(selectedNames == ["c"])
    }

    @Test("Down and up move by one row")
    func vertical() {
        select("b")
        model.moveSelection(.down, columns: 3, extending: false)
        #expect(selectedNames == ["e"])
        model.moveSelection(.up, columns: 3, extending: false)
        #expect(selectedNames == ["b"])
    }

    @Test("Movement stops at the edges")
    func edges() {
        select("a")
        model.moveSelection(.up, columns: 3, extending: false)
        #expect(selectedNames == ["a"])
        model.moveSelection(.left, columns: 3, extending: false)
        #expect(selectedNames == ["a"])

        select("e")
        model.moveSelection(.down, columns: 3, extending: false)   // no item below e
        #expect(selectedNames == ["e"])

        select("g")
        model.moveSelection(.right, columns: 3, extending: false)
        #expect(selectedNames == ["g"])
    }

    @Test("With nothing selected, → and ↓ select the first item, ← and ↑ the last",
          arguments: [(SelectionMove.right, "a"), (.down, "a"), (.left, "g"), (.up, "g")])
    func fromNoSelection(move: SelectionMove, expected: String) {
        model.selection = []
        model.moveSelection(move, columns: 3, extending: false)
        #expect(selectedNames == [expected])
    }

    @Test("Shift extends the selection from where it started")
    func extending() {
        select("b")
        model.moveSelection(.right, columns: 3, extending: true)
        model.moveSelection(.down, columns: 3, extending: true)
        #expect(selectedNames == ["b", "c", "d", "e", "f"])

        model.moveSelection(.up, columns: 3, extending: true)
        model.moveSelection(.left, columns: 3, extending: true)
        #expect(selectedNames == ["b"])
    }

    @Test("The moved-to item becomes the one to scroll to")
    func cursorTracksMovement() {
        select("a")
        model.moveSelection(.down, columns: 3, extending: false)
        #expect(model.selectionCursor?.lastPathComponent == "d.txt")
    }

    @Test("Column count for the grid width")
    func columnCount() {
        #expect(FileGridLayout.columns(forWidth: 100, minimumItemWidth: 120, spacing: 12) == 1)
        #expect(FileGridLayout.columns(forWidth: 400, minimumItemWidth: 120, spacing: 12) == 3)
        #expect(FileGridLayout.columns(forWidth: 0, minimumItemWidth: 120, spacing: 12) == 1)
    }
}
