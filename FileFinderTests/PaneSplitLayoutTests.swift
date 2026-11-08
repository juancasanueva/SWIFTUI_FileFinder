import CoreGraphics
import Testing
@testable import FileFinder

@Suite("Pane split layout")
struct PaneSplitLayoutTests {
    @Test("One pane takes the whole width")
    func onePane() {
        #expect(PaneSplitLayout.widths(total: 900, fraction: 0.5, count: 1) == [900])
    }

    @Test("Two panes split evenly at the default fraction, beside the divider")
    func evenSplit() {
        let total = 900 + PaneSplitLayout.divider
        let widths = PaneSplitLayout.widths(total: total, fraction: PaneSplitLayout.even, count: 2)
        #expect(widths == [450, 450])
        #expect(widths.reduce(0, +) + PaneSplitLayout.divider == total)
    }

    @Test("Dragging keeps each pane at least the minimum width")
    func clampedToMinimum() {
        let total = 1000 + PaneSplitLayout.divider
        #expect(PaneSplitLayout.widths(total: total, fraction: 0.05, count: 2) == [280, 720])
        #expect(PaneSplitLayout.widths(total: total, fraction: 0.95, count: 2) == [720, 280])
    }

    @Test("Too narrow for both minimums: the panes share the width evenly")
    func tooNarrow() {
        #expect(PaneSplitLayout.widths(total: 400 + PaneSplitLayout.divider, fraction: 0.2, count: 2) == [200, 200])
    }

    @Test("The divider's position gives the fraction, kept inside the minimums")
    func fractionFromDivider() {
        let total = 1000 + PaneSplitLayout.divider
        #expect(PaneSplitLayout.fraction(dividerAt: 400, total: total) == 0.4)
        #expect(PaneSplitLayout.fraction(dividerAt: 10, total: total) == 0.28)
        #expect(PaneSplitLayout.fraction(dividerAt: 990, total: total) == 0.72)
    }

    @Test("The divider between the panes is thick enough to see and grab")
    func visibleDivider() {
        #expect(PaneSplitLayout.divider >= 6)
    }
}

@Suite("Terminal split layout")
struct TerminalSplitLayoutTests {
    @Test("The terminal keeps the height asked for, between its minimum and what the panes leave")
    func clamped() {
        let total = 800 + PaneSplitLayout.divider
        #expect(TerminalSplitLayout.terminalHeight(total: total, requested: 300) == 300)
        #expect(TerminalSplitLayout.terminalHeight(total: total, requested: 50) == TerminalSplitLayout.minTerminal)
        #expect(TerminalSplitLayout.terminalHeight(total: total, requested: 2000) == 800 - TerminalSplitLayout.minPanes)
    }

    @Test("Too short for both minimums: the terminal gets its minimum, or what there is")
    func tooShort() {
        #expect(TerminalSplitLayout.terminalHeight(total: 300, requested: 400) == TerminalSplitLayout.minTerminal)
        #expect(TerminalSplitLayout.terminalHeight(total: 100, requested: 400) == 100 - PaneSplitLayout.divider)
    }

    @Test("Dragging the divider to y gives the terminal the height below it")
    func dragged() {
        let total = 800 + PaneSplitLayout.divider
        #expect(TerminalSplitLayout.terminalHeight(dividerAt: 500, total: total) == 300)
    }
}
