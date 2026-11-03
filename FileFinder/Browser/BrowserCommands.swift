import AppKit
import SwiftUI

/// Menu bar commands and keyboard shortcuts for the key browser window.
struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser

    private var hasSelection: Bool { !(browser?.selection.isEmpty ?? true) }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open") { browser?.openSelection() }
                .keyboardShortcut("o")
                .disabled(!hasSelection)
            Button("Move to Trash") { browser?.trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasSelection)
        }

        // Replacing the pasteboard group would break copy/paste inside text fields, so these
        // forward to the field editor whenever one is active.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { textOr(#selector(NSText.cut(_:))) { browser?.cutSelection() } }
                .keyboardShortcut("x")
            Button("Copy") { textOr(#selector(NSText.copy(_:))) { browser?.copySelection() } }
                .keyboardShortcut("c")
            Button("Paste") { textOr(#selector(NSText.paste(_:))) { browser?.paste() } }
                .keyboardShortcut("v")
            Button("Move Item Here") { browser?.paste(forceMove: true) }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Select All") { textOr(#selector(NSText.selectAll(_:))) { browser?.selectAll() } }
                .keyboardShortcut("a")
        }

        CommandGroup(before: .toolbar) {
            Button("as List") { browser?.viewMode = .list }
                .keyboardShortcut("1")
            Button("as Cards") { browser?.viewMode = .cards }
                .keyboardShortcut("2")
            Divider()
            Button("Bigger Icons") { if let next = browser?.iconSize.bigger { browser?.iconSize = next } }
                .keyboardShortcut("+")
                .disabled(browser?.iconSize.bigger == nil)
            Button("Smaller Icons") { if let next = browser?.iconSize.smaller { browser?.iconSize = next } }
                .keyboardShortcut("-")
                .disabled(browser?.iconSize.smaller == nil)
            Divider()
            Button(browser?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files") {
                browser?.showHidden.toggle()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(browser?.canGoBack ?? false))
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(browser?.canGoForward ?? false))
            Button("Enclosing Folder") { browser?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(!(browser?.canGoUp ?? false))
            Divider()
            Button("Home") { go(to: "") }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { go(to: "Desktop") }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Documents") { go(to: "Documents") }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Downloads") { go(to: "Downloads") }.keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("Go to Folder…") { browser?.isEditingPath = true }
                .keyboardShortcut("l")
        }
    }

    private func go(to homeRelativePath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        browser?.navigate(to: homeRelativePath.isEmpty ? home : home.appending(path: homeRelativePath))
    }

    /// Sends a standard text action when a text field is being edited, otherwise runs `action`.
    private func textOr(_ selector: Selector, _ action: () -> Void) {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            action()
        }
    }
}
