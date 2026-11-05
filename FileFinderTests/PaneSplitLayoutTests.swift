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
        let widths = PaneSplitLayout.widths(total: 901, fraction: PaneSplitLayout.even, count: 2)
        #expect(widths == [450, 450])
        #expect(widths.reduce(0, +) + PaneSplitLayout.divider == 901)
    }

    @Test("Dragging keeps each pane at least the minimum width")
    func clampedToMinimum() {
        let total: CGFloat = 1001
        #expect(PaneSplitLayout.widths(total: total, fraction: 0.05, count: 2) == [280, 720])
        #expect(PaneSplitLayout.widths(total: total, fraction: 0.95, count: 2) == [720, 280])
    }

    @Test("Too narrow for both minimums: the panes share the width evenly")
    func tooNarrow() {
        #expect(PaneSplitLayout.widths(total: 401, fraction: 0.2, count: 2) == [200, 200])
    }

    @Test("The divider's position gives the fraction, kept inside the minimums")
    func fractionFromDivider() {
        #expect(PaneSplitLayout.fraction(dividerAt: 400, total: 1001) == 0.4)
        #expect(PaneSplitLayout.fraction(dividerAt: 10, total: 1001) == 0.28)
        #expect(PaneSplitLayout.fraction(dividerAt: 990, total: 1001) == 0.72)
    }
}
