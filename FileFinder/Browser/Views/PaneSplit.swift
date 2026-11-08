import SwiftUI

/// Pane widths for a window's one or two panes.
nonisolated enum PaneSplitLayout {
    static let minWidth: CGFloat = 280
    /// Thick enough to see at a glance and to grab.
    static let divider: CGFloat = 6
    /// Where the divider sits when the second pane opens or the divider is double-clicked.
    static let even = 0.5

    /// One pane gets `total`; two share the width beside the divider, the left one taking
    /// `fraction`, each kept at `minWidth` or more when there is room for both.
    static func widths(total: CGFloat, fraction: Double, count: Int) -> [CGFloat] {
        guard count == 2 else { return [total] }
        let available = max(0, total - divider)
        let left = available >= 2 * minWidth
            ? min(max((available * fraction).rounded(), minWidth), available - minWidth)
            : (available / 2).rounded(.down)
        return [left, available - left]
    }

    /// The fraction for a divider dragged to `x`, kept inside both panes' minimum widths.
    static func fraction(dividerAt x: CGFloat, total: CGFloat) -> Double {
        let available = max(0, total - divider)
        guard available >= 2 * minWidth else { return even }
        return min(max(x / available, minWidth / available), (available - minWidth) / available)
    }
}

/// Heights for the panes above and the terminal panel below.
nonisolated enum TerminalSplitLayout {
    static let minTerminal: CGFloat = 200
    static let minPanes: CGFloat = 160
    /// The terminal's height when it opens or the divider is double-clicked.
    static let defaultHeight: CGFloat = 240

    /// The terminal's height for `requested`, kept at its minimum or more and leaving the panes
    /// theirs; when there isn't room for both, the terminal gets its minimum or all there is.
    static func terminalHeight(total: CGFloat, requested: CGFloat) -> CGFloat {
        let available = max(0, total - PaneSplitLayout.divider)
        let most = available - minPanes
        guard most >= minTerminal else { return min(minTerminal, available) }
        return min(max(requested, minTerminal), most)
    }

    /// The terminal's height for a divider dragged to `y`.
    static func terminalHeight(dividerAt y: CGFloat, total: CGFloat) -> CGFloat {
        terminalHeight(total: total, requested: total - PaneSplitLayout.divider - y)
    }
}

/// The bar between two panes, or between the panes and the terminal: thick enough to see, with
/// a grip in the middle that says it can be dragged. Stronger than the system separator, which
/// is nearly invisible in dark mode.
struct SplitDividerBar: View {
    /// `.horizontal` for side-by-side content (an upright bar), `.vertical` for stacked content.
    let axis: Axis

    var body: some View {
        let upright = axis == .horizontal
        Rectangle()
            .fill(Color.primary.opacity(0.2))
            .frame(width: upright ? PaneSplitLayout.divider : nil, height: upright ? nil : PaneSplitLayout.divider)
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(0.55))
                    .frame(width: upright ? 2 : 28, height: upright ? 28 : 2)
            }
    }
}

/// The panes above and the terminal panel below, when it is open. The divider drags, and a
/// double-click on it puts the terminal back to its usual height.
struct TerminalSplit<Top: View, Bottom: View>: View {
    let top: Top
    /// `nil` while the terminal is closed.
    let bottom: Bottom?
    @State private var terminalHeight = TerminalSplitLayout.defaultHeight

    init(@ViewBuilder top: () -> Top, bottom: () -> Bottom?) {
        self.top = top()
        self.bottom = bottom()
    }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.height
            // One structure whether or not the terminal is open, so the panes keep their state.
            VStack(spacing: 0) {
                top.frame(maxHeight: .infinity)
                if let bottom {
                    divider(total: total)
                    bottom.frame(height: TerminalSplitLayout.terminalHeight(total: total, requested: terminalHeight))
                }
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    private static var space: String { "TerminalSplit" }

    private func divider(total: CGFloat) -> some View {
        SplitDividerBar(axis: .vertical)
            .overlay {
                Color.clear
                    .frame(height: 12)
                    .contentShape(.rect)
                    .pointerStyle(.rowResize)
                    .onTapGesture(count: 2) { terminalHeight = TerminalSplitLayout.defaultHeight }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .onChanged {
                                terminalHeight = TerminalSplitLayout.terminalHeight(dividerAt: $0.location.y, total: total)
                            })
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

/// The window's panes side by side. A second pane opens at half the width; the divider drags,
/// and a double-click on it evens the panes out again.
struct PaneSplit<Content: View>: View {
    let panes: [BrowserModel]
    @ViewBuilder let content: (BrowserModel) -> Content
    @State private var fraction = PaneSplitLayout.even

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let widths = PaneSplitLayout.widths(total: total, fraction: fraction, count: panes.count)
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.objectID) { index, pane in
                    if index > 0 { divider(total: total) }
                    content(pane)
                        .frame(width: widths[min(index, widths.count - 1)])
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        .frame(minWidth: panes.count == 2 ? 2 * PaneSplitLayout.minWidth + PaneSplitLayout.divider : PaneSplitLayout.minWidth)
        .onChange(of: panes.count) { fraction = PaneSplitLayout.even }
    }

    private static var space: String { "PaneSplit" }

    private func divider(total: CGFloat) -> some View {
        SplitDividerBar(axis: .horizontal)
            .overlay {
                // A grab area wider than the bar, over the panes' edges.
                Color.clear
                    .frame(width: 12)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .onTapGesture(count: 2) { fraction = PaneSplitLayout.even }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                            .onChanged { fraction = PaneSplitLayout.fraction(dividerAt: $0.location.x, total: total) })
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}
