/// How the sidebar treats a selection change: a click opens the row at once, while the arrow
/// keys only move a highlight that Return opens, so browsing by keyboard doesn't open every row
/// on the way. The view decides whether a change came from the keyboard; this decides the rest.
struct SidebarHighlight {
    /// The row the arrow keys moved to. Nil shows the pane's own location.
    private var location: BrowserLocation?

    /// The row the sidebar shows as selected.
    func shown(current: BrowserLocation?) -> BrowserLocation? {
        location ?? current
    }

    /// A selection change. Returns the location to open, or nil when it only moves the highlight.
    mutating func select(_ newLocation: BrowserLocation?, byKeyboard: Bool) -> BrowserLocation? {
        if byKeyboard {
            location = newLocation
            return nil
        }
        location = nil
        return newLocation
    }

    /// Return. Returns the highlighted location to open, or nil to leave the key to the list.
    mutating func pressReturn() -> BrowserLocation? {
        defer { location = nil }
        return location
    }

    /// Focus left the sidebar without Return: go back to showing the pane's location.
    mutating func focusLost() {
        location = nil
    }
}
