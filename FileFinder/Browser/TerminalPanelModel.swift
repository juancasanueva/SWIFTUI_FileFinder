import Foundation

/// The Ghostty terminal panel at the bottom of a window. Opening it starts a shell in a folder;
/// closing it, or the shell exiting, ends that shell.
@Observable
final class TerminalPanelModel {
    struct Session: Identifiable, Equatable {
        let id = UUID()
        let folder: URL
    }

    private(set) var session: Session? {
        didSet { if session == nil { isFocused = false } }
    }

    /// Whether the shell has keyboard focus; the panel reports it.
    var isFocused = false
    /// Bumped to move keyboard focus into the shell.
    private(set) var focusRequest = 0

    func requestFocus() { focusRequest += 1 }

    /// Asks the open shell to change to a folder; a new id each time, so asking again works.
    struct CDRequest: Equatable {
        let id = UUID()
        let folder: URL
    }

    private(set) var cdRequest: CDRequest?

    func toggle(in folder: URL) {
        session = session == nil ? Session(folder: folder) : nil
    }

    /// Open in Terminal (menu, right-click, `terminal` in the path bar): starts a shell in
    /// `folder`, or, when one is open, asks it to `cd` there, so nothing running in it is lost.
    func open(in folder: URL) {
        if session == nil {
            session = Session(folder: folder)
        } else {
            cdRequest = CDRequest(folder: folder)
        }
    }

    /// The panel's close button. Safe when the shell already ended.
    func close() { session = nil }

    /// Called when a shell ends (`exit`, Ctrl-D). A shell already replaced by a newer one is ignored.
    func shellExited(_ id: Session.ID) {
        if session?.id == id { session = nil }
    }
}

extension BrowserWindowModel {
    /// The Terminal button: a shell in the active pane's folder, or home when it has none
    /// (a workspace with no single folder selected).
    func toggleTerminal() {
        terminal.toggle(in: active.developerFolder ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Whether ⌥⌘↓ has somewhere to go: an open terminal that doesn't have focus yet.
    var canFocusTerminal: Bool { terminal.session != nil && !terminal.isFocused }

    /// Whether ⌥⌘↑ has somewhere to go: back up from the terminal to the files.
    var canFocusFiles: Bool { terminal.isFocused }

    /// ⌥⌘↓: from a pane (or the sidebar) into the terminal.
    func focusTerminal() {
        guard canFocusTerminal else { return }
        terminal.requestFocus()
    }

    /// ⌥⌘↑: from the terminal back to the pane focus came from. The active pane stays the
    /// active one while the terminal has focus, so that is the pane to return to.
    func focusFiles() {
        guard canFocusFiles else { return }
        focusPane(at: activeIndex)
    }
}
