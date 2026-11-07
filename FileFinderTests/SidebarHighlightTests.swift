import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Sidebar keyboard highlight")
struct SidebarHighlightTests {
    private let current = BrowserLocation.folder(URL(filePath: "/current"))
    private let downloads = BrowserLocation.folder(URL(filePath: "/Downloads"))
    private let workspace = BrowserLocation.workspace(UUID())

    @Test("With no highlight, the sidebar shows the pane's own location")
    func showsCurrentLocation() {
        let highlight = SidebarHighlight()
        #expect(highlight.shown(current: current) == current)
    }

    @Test("An arrow key only moves the highlight; nothing opens")
    func arrowKeyHighlights() {
        var highlight = SidebarHighlight()
        #expect(highlight.select(downloads, byKeyboard: true) == nil)
        #expect(highlight.shown(current: current) == downloads)
    }

    @Test("A click opens the row at once and drops the highlight")
    func clickOpens() {
        var highlight = SidebarHighlight()
        _ = highlight.select(downloads, byKeyboard: true)
        #expect(highlight.select(workspace, byKeyboard: false) == workspace)
        #expect(highlight.shown(current: current) == current)
    }

    @Test("Return opens the highlighted row and drops the highlight")
    func returnOpensHighlight() {
        var highlight = SidebarHighlight()
        _ = highlight.select(downloads, byKeyboard: true)
        #expect(highlight.pressReturn() == downloads)
        #expect(highlight.shown(current: current) == current)
    }

    @Test("Return with nothing highlighted is left to the list")
    func returnWithoutHighlight() {
        var highlight = SidebarHighlight()
        #expect(highlight.pressReturn() == nil)
    }

    @Test("Leaving the sidebar drops the highlight back to the pane's location")
    func focusLostDropsHighlight() {
        var highlight = SidebarHighlight()
        _ = highlight.select(downloads, byKeyboard: true)
        highlight.focusLost()
        #expect(highlight.shown(current: current) == current)
        #expect(highlight.pressReturn() == nil)
    }
}
