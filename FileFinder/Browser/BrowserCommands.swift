import AppKit
import SwiftUI

/// Menu bar commands and keyboard shortcuts for the key browser window.
struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser
    @FocusedValue(\.browserWindow) private var window
    @Environment(\.openWindow) private var openWindow
    /// keybindings.json; the menus follow its changes.
    private let keys = KeyBindingStore.shared

    private var runner: KeyActionRunner {
        KeyActionRunner(browser: browser, window: window, openSmartClean: { openWindow(id: SmartCleanWindow.id) })
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            item(.newFolder)
            item(.newWorkspace, title: "New Workspace…")
            item(.open)
            item(.save)
            item(.rename)
            item(.compress)
            Divider()
            // Listed before the View menu, so it wins ⌥⌘T over Show/Hide Toolbar.
            item(.tidyFolder, title: "Tidy This Folder…")
            item(.tidyDownloads, title: "Tidy Downloads…")
            item(.smartClean, title: "Smart Clean…")
            Divider()
            item(.openInTerminal)
            item(.openInExternalTerminal)
            item(.openInEditor)
            Divider()
            item(.copyToOtherPane)
            item(.moveToOtherPane)
            Divider()
            // In a workspace ⌘⌫ only removes entries; nothing is ever trashed from there.
            item(.moveToTrash)
            item(.emptyTrash, title: "Empty Trash…")
        }

        // Replacing the pasteboard group would break copy/paste inside text fields, so these
        // forward to the field editor whenever one is active, and are never disabled.
        CommandGroup(replacing: .pasteboard) {
            textItem(.cut, #selector(NSText.cut(_:)))
            textItem(.copy, #selector(NSText.copy(_:)))
            textItem(.paste, #selector(NSText.paste(_:)))
            item(.moveItemHere)
            textItem(.selectAll, #selector(NSText.selectAll(_:)))
        }

        CommandGroup(before: .toolbar) {
            item(.splitView)
            // From the left pane, Focus Left Pane goes on to the sidebar; Focus Right Pane comes back.
            item(.focusLeftPane)
            item(.focusRightPane)
            item(.focusTerminal)
            item(.focusFiles)
            item(.swapPanes)
            Divider()
            item(.viewAsList, alwaysEnabled: true)
            item(.viewAsCards, alwaysEnabled: true)
            item(.viewAsColumns, alwaysEnabled: true)
            Picker("Group By", selection: Binding(
                get: { browser?.groupBy ?? .none },
                set: { browser?.groupBy = $0 }
            )) {
                ForEach(GroupBy.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(browser == nil)
            Divider()
            item(.biggerIcons)
            item(.smallerIcons)
            Divider()
            item(.togglePreview, alwaysEnabled: true)
            item(.toggleHiddenFiles, alwaysEnabled: true)
            Divider()
        }

        CommandMenu("Go") {
            item(.goBack)
            item(.goForward)
            item(.enclosingFolder)
            Divider()
            item(.goHome, alwaysEnabled: true)
            item(.goDesktop, alwaysEnabled: true)
            item(.goDocuments, alwaysEnabled: true)
            item(.goDownloads, alwaysEnabled: true)
            Divider()
            item(.goToFolder, title: "Go to Folder…", alwaysEnabled: true)
            item(.commandPalette, title: "Command Palette…")
            Divider()
            ForEach(Array((window?.workspaces.workspaces ?? []).prefix(9).enumerated()), id: \.element.id) { index, workspace in
                Button(workspace.name) { Task { await window?.openWorkspace(number: index + 1) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
        }
    }

    /// A menu item for `action`, disabled when it can't run (unless the menu always kept it on).
    private func item(_ action: KeyAction, title: String? = nil, alwaysEnabled: Bool = false) -> some View {
        let runner = runner
        return Button(title ?? runner.title(action)) { runner.perform(action) }
            .keyboardShortcut(shortcut(action))
            .disabled(!alwaysEnabled && !runner.canPerform(action))
    }

    /// Sends the standard text action when a text field is being edited, otherwise runs `action`.
    private func textItem(_ action: KeyAction, _ selector: Selector) -> some View {
        let runner = runner
        return Button(runner.title(action)) {
            if NSApp.keyWindow?.firstResponder is NSText {
                NSApp.sendAction(selector, to: nil, from: nil)
            } else {
                runner.perform(action)
            }
        }
        .keyboardShortcut(shortcut(action))
    }

    private func shortcut(_ action: KeyAction) -> KeyboardShortcut? {
        keys.shortcut(for: action)?.keyboardShortcut
    }
}
