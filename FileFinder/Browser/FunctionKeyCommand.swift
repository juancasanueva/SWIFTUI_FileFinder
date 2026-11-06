import Foundation

/// The commands in the function key bar at the bottom of the window.
enum FunctionKeyCommand: CaseIterable, Identifiable {
    case rename, copy, move, makeFolder, delete, makeMarkdownFile

    var id: Self { self }

    var title: String {
        switch self {
        case .rename: "Rename"
        case .copy: "Copy"
        case .move: "Move"
        case .makeFolder: "Mkdir"
        case .delete: "Delete"
        case .makeMarkdownFile: "New MD"
        }
    }

    /// The keymap action this command shares its key with; `nil` for the fixed keys F7, F8 and F9.
    var keyAction: KeyAction? {
        switch self {
        case .rename: .rename
        case .copy: .copyToOtherPane
        case .move: .moveToOtherPane
        case .makeFolder, .delete, .makeMarkdownFile: nil
        }
    }

    /// F7 and F8 sit beside ⇧⌘N and ⌘⌫, and F9 is New Markdown File, so they are fixed rather than kept in the keymap.
    var fixedShortcut: Shortcut? {
        switch self {
        case .makeFolder: Shortcut("f7")
        case .delete: Shortcut("f8")
        case .makeMarkdownFile: Shortcut("f9")
        case .rename, .copy, .move: nil
        }
    }

    /// The key shown in the bar: the keymap's for menu actions, the fixed key for the others;
    /// `nil` when the action has no key.
    func keyLabel(_ shortcut: (KeyAction) -> Shortcut?) -> String? {
        (keyAction.map(shortcut) ?? fixedShortcut)?.display
    }
}

extension BrowserWindowModel {
    /// The commands the bar lists: Copy and Move need a second pane, so they appear only then.
    var barCommands: [FunctionKeyCommand] {
        FunctionKeyCommand.allCases.filter { isSplit || ($0 != .copy && $0 != .move) }
    }

    /// Mirrors the menus: nothing runs while a name or path is being typed.
    func canPerform(_ command: FunctionKeyCommand) -> Bool {
        guard !active.isTyping else { return false }
        let hasSelection = !active.selection.isEmpty
        return switch command {
        case .rename: active.selection.count == 1
        case .copy, .move: isSplit && hasSelection
        case .makeFolder, .makeMarkdownFile: !active.isShowingWorkspace
        case .delete: hasSelection
        }
    }

    func perform(_ command: FunctionKeyCommand) async {
        guard canPerform(command) else { return }
        switch command {
        case .rename: active.beginRename()
        case .copy: await copyToOtherPane()
        case .move: await moveToOtherPane()
        case .makeFolder: await active.newFolder()
        case .makeMarkdownFile: await active.newMarkdownFile()
        // In a workspace this removes the entries, as ⌘⌫ does; nothing is trashed from there.
        case .delete: await active.trashSelection()
        }
    }
}
