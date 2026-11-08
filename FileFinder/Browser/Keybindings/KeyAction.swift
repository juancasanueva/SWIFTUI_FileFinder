import Foundation

/// The menu commands whose shortcuts can be changed. The raw value is the action's key in
/// keybindings.json.
nonisolated enum KeyAction: String, CaseIterable, Identifiable, Sendable {
    // File
    case newFolder, newWorkspace, open, save, rename, compress, tidyFolder, tidyDownloads, smartClean
    case openInTerminal, openInExternalTerminal, openInEditor, copyToOtherPane, moveToOtherPane, moveToTrash
    // Edit
    case cut, copy, paste, moveItemHere, selectAll
    // View
    case splitView, focusLeftPane, focusRightPane, focusTerminal, focusFiles, swapPanes, viewAsList, viewAsCards, viewAsColumns
    case biggerIcons, smallerIcons, togglePreview, toggleHiddenFiles
    // Go
    case goBack, goForward, enclosingFolder, goHome, goDesktop, goDocuments, goDownloads, goToFolder, commandPalette

    var id: String { rawValue }

    /// The menu each action is in, for grouping in Settings.
    nonisolated enum Menu: String, CaseIterable, Sendable {
        case file = "File", edit = "Edit", view = "View", go = "Go"
    }

    var menu: Menu {
        switch self {
        case .newFolder, .newWorkspace, .open, .save, .rename, .compress, .tidyFolder, .tidyDownloads, .smartClean,
             .openInTerminal, .openInExternalTerminal, .openInEditor, .copyToOtherPane, .moveToOtherPane, .moveToTrash: .file
        case .cut, .copy, .paste, .moveItemHere, .selectAll: .edit
        case .splitView, .focusLeftPane, .focusRightPane, .focusTerminal, .focusFiles, .swapPanes, .viewAsList, .viewAsCards, .viewAsColumns,
             .biggerIcons, .smallerIcons, .togglePreview, .toggleHiddenFiles: .view
        case .goBack, .goForward, .enclosingFolder, .goHome, .goDesktop, .goDocuments, .goDownloads, .goToFolder,
             .commandPalette: .go
        }
    }

    var title: String {
        switch self {
        case .newFolder: "New Folder"
        case .newWorkspace: "New Workspace"
        case .open: "Open"
        case .save: "Save"
        case .rename: "Rename"
        case .compress: "Compress"
        case .tidyFolder: "Tidy This Folder"
        case .tidyDownloads: "Tidy Downloads"
        case .smartClean: "Smart Clean"
        case .openInTerminal: "Open in Terminal"
        case .openInExternalTerminal: "Open in external terminal"
        case .openInEditor: "Open in Editor"
        case .copyToOtherPane: "Copy to Other Pane"
        case .moveToOtherPane: "Move to Other Pane"
        case .moveToTrash: "Move to Trash"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .moveItemHere: "Move Item Here"
        case .selectAll: "Select All"
        case .splitView: "Split View"
        case .focusLeftPane: "Focus Left Pane"
        case .focusRightPane: "Focus Right Pane"
        case .focusTerminal: "Focus Terminal"
        case .focusFiles: "Focus Files"
        case .swapPanes: "Swap Panes"
        case .viewAsList: "as List"
        case .viewAsCards: "as Cards"
        case .viewAsColumns: "as Columns"
        case .biggerIcons: "Bigger Icons"
        case .smallerIcons: "Smaller Icons"
        case .togglePreview: "Show Preview"
        case .toggleHiddenFiles: "Show Hidden Files"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .enclosingFolder: "Enclosing Folder"
        case .goHome: "Home"
        case .goDesktop: "Desktop"
        case .goDocuments: "Documents"
        case .goDownloads: "Downloads"
        case .goToFolder: "Go to Folder"
        case .commandPalette: "Command Palette"
        }
    }

    /// The shortcut the menus had before keybindings.json; `nil` for none.
    var defaultShortcut: Shortcut? {
        let text: String? = switch self {
        case .newFolder: "cmd+shift+n"
        case .newWorkspace: "cmd+alt+n"
        case .open: "cmd+o"
        case .save: "cmd+s"
        case .rename: "f2"
        case .tidyFolder: "cmd+alt+t"
        case .compress, .tidyDownloads, .smartClean: nil
        case .openInTerminal: "cmd+alt+shift+t"
        case .openInExternalTerminal: "cmd+ctrl+alt+t"
        case .openInEditor: "cmd+alt+shift+e"
        case .copyToOtherPane: "f5"
        case .moveToOtherPane: "f6"
        case .moveToTrash: "cmd+delete"
        case .cut: "cmd+x"
        case .copy: "cmd+c"
        case .paste: "cmd+v"
        case .moveItemHere: "cmd+alt+v"
        case .selectAll: "cmd+a"
        case .splitView: "cmd+d"
        case .focusLeftPane: "cmd+alt+left"
        case .focusRightPane: "cmd+alt+right"
        case .focusTerminal: "cmd+alt+down"
        case .focusFiles: "cmd+alt+up"
        case .swapPanes: "cmd+u"
        case .viewAsList: "cmd+1"
        case .viewAsCards: "cmd+2"
        case .viewAsColumns: "cmd+3"
        case .biggerIcons: "cmd+plus"
        case .smallerIcons: "cmd+-"
        case .togglePreview: "cmd+shift+p"
        case .toggleHiddenFiles: "cmd+shift+."
        case .goBack: "cmd+["
        case .goForward: "cmd+]"
        case .enclosingFolder: "cmd+up"
        case .goHome: "cmd+shift+h"
        case .goDesktop: "cmd+shift+d"
        case .goDocuments: "cmd+shift+o"
        case .goDownloads: "cmd+alt+l"
        case .goToFolder: "cmd+l"
        case .commandPalette: "cmd+k"
        }
        return text.flatMap(Shortcut.init)
    }
}
