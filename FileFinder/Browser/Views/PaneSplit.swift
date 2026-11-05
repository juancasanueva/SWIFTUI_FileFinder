import SwiftUI

/// Pane widths for a window's one or two panes.
nonisolated enum PaneSplitLayout {
    static let minWidth: CGFloat = 280
    static let divider: CGFloat = 1
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
        Rectangle()
            .fill(.separator)
            .frame(width: PaneSplitLayout.divider)
            .overlay {
                // A grab area wider than the line, over the panes' edges.
                Color.clear
                    .frame(width: 9)
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
