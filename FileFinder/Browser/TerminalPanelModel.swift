import Foundation

/// The Ghostty terminal panel at the bottom of a window. Opening it starts a shell in a folder;
/// closing it, or the shell exiting, ends that shell.
@Observable
final class TerminalPanelModel {
    struct Session: Identifiable, Equatable {
        let id = UUID()
        let folder: URL
    }

    private(set) var session: Session?

    func toggle(in folder: URL) {
        session = session == nil ? Session(folder: folder) : nil
    }

    /// Open in Terminal (menu, right-click, `terminal` in the path bar): a shell already in
    /// `folder` stays; otherwise a new one starts there.
    func open(in folder: URL) {
        if session?.folder != folder { session = Session(folder: folder) }
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
}
