import CoreGraphics

/// Column math for the card grid, shared by layout and arrow-key navigation so ↑/↓ move
/// exactly one visible row.
enum FileGridLayout {
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 16

    static func minimumItemWidth(for iconSize: IconSize) -> CGFloat { iconSize.cardSide + 48 }

    static func columns(forWidth width: CGFloat, minimumItemWidth: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumItemWidth + spacing)))
    }
}
