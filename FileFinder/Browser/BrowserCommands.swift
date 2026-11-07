import AppKit
import SwiftUI

/// Menu bar commands and keyboard shortcuts for the key browser window.
struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser
    @FocusedValue(\.browserWindow) private var window
    @Environment(\.openWindow) private var openWindow
    /// keybindings.json; the menus follow its changes.
    private let keys = KeyBindingStore.shared

    private var hasSelection: Bool { !(browser?.selection.isEmpty ?? true) }
    private var isTyping: Bool { browser?.isTyping ?? false }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { Task { await browser?.newFolder() } }
                .keyboardShortcut(shortcut(.newFolder))
                .disabled(browser == nil || isTyping || browser?.isShowingWorkspace == true)
            Button("New Workspace…") { window?.requestNewWorkspace() }
                .keyboardShortcut(shortcut(.newWorkspace))
                .disabled(window == nil || isTyping)
            Button("Open") { browser?.openSelection() }
                .keyboardShortcut(shortcut(.open))
                .disabled(!hasSelection || isTyping)
            Button("Rename") { browser?.beginRename() }
                .keyboardShortcut(shortcut(.rename))
                .disabled(browser?.selection.count != 1 || isTyping)
            Divider()
            // Listed before the View menu, so it wins ⌥⌘T over Show/Hide Toolbar.
            Button("Tidy This Folder…") { Task { await browser?.prepareTidy() } }
                .keyboardShortcut(shortcut(.tidyFolder))
                .disabled(!(browser?.canTidy ?? false) || isTyping)
            Button("Tidy Downloads…") { Task { await browser?.tidyDownloads() } }
                .keyboardShortcut(shortcut(.tidyDownloads))
                .disabled(browser == nil || isTyping)
            Button("Smart Clean…") { openWindow(id: SmartCleanWindow.id) }
                .keyboardShortcut(shortcut(.smartClean))
            Divider()
            Button("Open in Terminal") { browser?.openInTerminal() }
                .keyboardShortcut(shortcut(.openInTerminal))
                .disabled(browser?.developerFolder == nil || isTyping)
            Button("Open in external terminal") { browser?.openInExternalTerminal() }
                .keyboardShortcut(shortcut(.openInExternalTerminal))
                .disabled(browser?.developerFolder == nil || isTyping)
            Button(DeveloperTools.shared.openTitle(.editor)) { browser?.openInEditor() }
                .keyboardShortcut(shortcut(.openInEditor))
                .disabled(browser?.developerFolder == nil || isTyping)
            Divider()
            Button("Copy to Other Pane") { Task { await window?.copyToOtherPane() } }
                .keyboardShortcut(shortcut(.copyToOtherPane))
                .disabled(!(window?.isSplit ?? false) || !hasSelection || isTyping)
            Button("Move to Other Pane") { Task { await window?.moveToOtherPane() } }
                .keyboardShortcut(shortcut(.moveToOtherPane))
                .disabled(!(window?.isSplit ?? false) || !hasSelection || isTyping)
            Divider()
            // In a workspace ⌘⌫ only removes entries; nothing is ever trashed from there.
            Button(browser?.isShowingWorkspace == true ? "Remove from Workspace" : "Move to Trash") {
                Task { await browser?.trashSelection() }
            }
                .keyboardShortcut(shortcut(.moveToTrash))
                .disabled(!hasSelection || isTyping)
        }

        // Replacing the pasteboard group would break copy/paste inside text fields, so these
        // forward to the field editor whenever one is active.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { textOr(#selector(NSText.cut(_:))) { browser?.cutSelection() } }
                .keyboardShortcut(shortcut(.cut))
            Button("Copy") { textOr(#selector(NSText.copy(_:))) { browser?.copySelection() } }
                .keyboardShortcut(shortcut(.copy))
            Button("Paste") { textOr(#selector(NSText.paste(_:))) { Task { await browser?.paste() } } }
                .keyboardShortcut(shortcut(.paste))
            Button("Move Item Here") { Task { await browser?.paste(forceMove: true) } }
                .keyboardShortcut(shortcut(.moveItemHere))
                .disabled(isTyping)
            Button("Select All") { textOr(#selector(NSText.selectAll(_:))) { browser?.selectAll() } }
                .keyboardShortcut(shortcut(.selectAll))
        }

        CommandGroup(before: .toolbar) {
            Button(window?.isSplit == true ? "Close Split View" : "Split View") { window?.toggleSplit() }
                .keyboardShortcut(shortcut(.splitView))
                .disabled(window == nil || isTyping)
            // Disabled while typing, so text fields keep their own ⌥⌘ arrow keys.
            // From the left pane, Focus Left Pane goes on to the sidebar; Focus Right Pane comes back.
            Button("Focus Left Pane") { window?.focusLeft() }
                .keyboardShortcut(shortcut(.focusLeftPane))
                .disabled(!(window?.canFocusLeft ?? false) || isTyping)
            Button("Focus Right Pane") { window?.focusRight() }
                .keyboardShortcut(shortcut(.focusRightPane))
                .disabled(!(window?.canFocusRight ?? false) || isTyping)
            Button("Swap Panes") { window?.swapPanes() }
                .keyboardShortcut(shortcut(.swapPanes))
                .disabled(!(window?.isSplit ?? false) || isTyping)
            Divider()
            Button("as List") { browser?.viewMode = .list }
                .keyboardShortcut(shortcut(.viewAsList))
            Button("as Cards") { browser?.viewMode = .cards }
                .keyboardShortcut(shortcut(.viewAsCards))
            Picker("Group By", selection: Binding(
                get: { browser?.groupBy ?? .none },
                set: { browser?.groupBy = $0 }
            )) {
                ForEach(GroupBy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(browser == nil)
            Divider()
            Button("Bigger Icons") { if let next = browser?.iconSize.bigger { browser?.iconSize = next } }
                .keyboardShortcut(shortcut(.biggerIcons))
                .disabled(browser?.iconSize.bigger == nil)
            Button("Smaller Icons") { if let next = browser?.iconSize.smaller { browser?.iconSize = next } }
                .keyboardShortcut(shortcut(.smallerIcons))
                .disabled(browser?.iconSize.smaller == nil)
            Divider()
            Button(browser?.showPreview == true ? "Hide Preview" : "Show Preview") {
                browser?.showPreview.toggle()
            }
            .keyboardShortcut(shortcut(.togglePreview))
            Button(browser?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files") {
                browser?.showHidden.toggle()
            }
            .keyboardShortcut(shortcut(.toggleHiddenFiles))
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut(shortcut(.goBack))
                .disabled(!(browser?.canGoBack ?? false))
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut(shortcut(.goForward))
                .disabled(!(browser?.canGoForward ?? false))
            Button("Enclosing Folder") { browser?.goUp() }
                .keyboardShortcut(shortcut(.enclosingFolder))
                .disabled(!(browser?.canGoUp ?? false) || isTyping)
            Divider()
            Button("Home") { go(to: "") }.keyboardShortcut(shortcut(.goHome))
            Button("Desktop") { go(to: "Desktop") }.keyboardShortcut(shortcut(.goDesktop))
            Button("Documents") { go(to: "Documents") }.keyboardShortcut(shortcut(.goDocuments))
            Button("Downloads") { go(to: "Downloads") }.keyboardShortcut(shortcut(.goDownloads))
            Divider()
            Button("Go to Folder…") { browser?.isEditingPath = true }
                .keyboardShortcut(shortcut(.goToFolder))
            Divider()
            ForEach(Array((window?.workspaces.workspaces ?? []).prefix(9).enumerated()), id: \.element.id) { index, workspace in
                Button(workspace.name) { Task { await window?.openWorkspace(number: index + 1) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
        }
    }

    private func shortcut(_ action: KeyAction) -> KeyboardShortcut? {
        keys.shortcut(for: action)?.keyboardShortcut
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
