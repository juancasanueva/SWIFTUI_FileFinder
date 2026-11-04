import AppKit
import SwiftUI

/// Menu bar commands and keyboard shortcuts for the key browser window.
struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser
    @FocusedValue(\.browserWindow) private var window

    private var hasSelection: Bool { !(browser?.selection.isEmpty ?? true) }
    private var isTyping: Bool { browser?.isTyping ?? false }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { Task { await browser?.newFolder() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser == nil || isTyping || browser?.isShowingWorkspace == true)
            Button("New Workspace…") { window?.requestNewWorkspace() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(window == nil || isTyping)
            Button("Open") { browser?.openSelection() }
                .keyboardShortcut("o")
                .disabled(!hasSelection || isTyping)
            Divider()
            // Listed before the View menu, so it wins ⌥⌘T over Show/Hide Toolbar.
            Button("Tidy This Folder…") { Task { await browser?.prepareTidy() } }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!(browser?.canTidy ?? false) || isTyping)
            Button("Tidy Downloads…") { Task { await browser?.tidyDownloads() } }
                .disabled(browser == nil || isTyping)
            Divider()
            Button("Copy to Other Pane") { Task { await window?.copyToOtherPane() } }
                .keyboardShortcut(Self.functionKey(NSF5FunctionKey), modifiers: [])
                .disabled(!(window?.isSplit ?? false) || !hasSelection || isTyping)
            Button("Move to Other Pane") { Task { await window?.moveToOtherPane() } }
                .keyboardShortcut(Self.functionKey(NSF6FunctionKey), modifiers: [])
                .disabled(!(window?.isSplit ?? false) || !hasSelection || isTyping)
            Divider()
            // In a workspace ⌘⌫ only removes entries; nothing is ever trashed from there.
            Button(browser?.isShowingWorkspace == true ? "Remove from Workspace" : "Move to Trash") {
                Task { await browser?.trashSelection() }
            }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!hasSelection || isTyping)
        }

        // Replacing the pasteboard group would break copy/paste inside text fields, so these
        // forward to the field editor whenever one is active.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { textOr(#selector(NSText.cut(_:))) { browser?.cutSelection() } }
                .keyboardShortcut("x")
            Button("Copy") { textOr(#selector(NSText.copy(_:))) { browser?.copySelection() } }
                .keyboardShortcut("c")
            Button("Paste") { textOr(#selector(NSText.paste(_:))) { Task { await browser?.paste() } } }
                .keyboardShortcut("v")
            Button("Move Item Here") { Task { await browser?.paste(forceMove: true) } }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(isTyping)
            Button("Select All") { textOr(#selector(NSText.selectAll(_:))) { browser?.selectAll() } }
                .keyboardShortcut("a")
        }

        CommandGroup(before: .toolbar) {
            Button(window?.isSplit == true ? "Close Split View" : "Split View") { window?.toggleSplit() }
                .keyboardShortcut("d")
                .disabled(window == nil || isTyping)
            // A bare Tab: disabled while typing so text fields keep Tab (path completion).
            Button("Switch Pane") { window?.switchPane() }
                .keyboardShortcut(.tab, modifiers: [])
                .disabled(!(window?.isSplit ?? false) || isTyping)
            Button("Swap Panes") { window?.swapPanes() }
                .keyboardShortcut("u")
                .disabled(!(window?.isSplit ?? false) || isTyping)
            Divider()
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
            Button(browser?.showPreview == true ? "Hide Preview" : "Show Preview") {
                browser?.showPreview.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
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
                .disabled(!(browser?.canGoUp ?? false) || isTyping)
            Divider()
            Button("Home") { go(to: "") }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { go(to: "Desktop") }.keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Documents") { go(to: "Documents") }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Downloads") { go(to: "Downloads") }.keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("Go to Folder…") { browser?.isEditingPath = true }
                .keyboardShortcut("l")
            Divider()
            ForEach(Array((window?.workspaces.workspaces ?? []).prefix(9).enumerated()), id: \.element.id) { index, workspace in
                Button(workspace.name) { Task { await window?.openWorkspace(number: index + 1) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
        }
    }

    private static func functionKey(_ code: Int) -> KeyEquivalent {
        KeyEquivalent(Character(Unicode.Scalar(UInt32(code)) ?? " "))
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
