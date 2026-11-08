import Foundation

/// When each menu action can run, and what it does, for the key window. The menus and the
/// command palette both use it, so they never disagree.
struct KeyActionRunner {
    let browser: BrowserModel?
    let window: BrowserWindowModel?
    /// Smart Clean opens its own window, which only a view can do.
    var openSmartClean: () -> Void = {}
    /// The palette builds its list while it is open, for running once it has closed.
    var ignoresPalette = false

    private var hasSelection: Bool { !(browser?.selection.isEmpty ?? true) }
    /// A text field has the keyboard: rename, the typed path or the palette's search box.
    /// File shortcuts must not act on the selection then.
    private var isTyping: Bool {
        (browser?.isTyping ?? false) || (!ignoresPalette && (window?.isShowingPalette ?? false))
    }

    func canPerform(_ action: KeyAction) -> Bool {
        switch action {
        case .newFolder: browser != nil && !isTyping && browser?.isShowingWorkspace != true
        case .newWorkspace: window != nil && !isTyping
        case .open: hasSelection && !isTyping
        // Works while typing: the Markdown editor is a text field too.
        case .save: browser?.document?.isDirty == true
        case .rename: browser?.selection.count == 1 && !isTyping
        case .tidyFolder: (browser?.canTidy ?? false) && !isTyping
        case .tidyDownloads: browser != nil && !isTyping
        case .smartClean: true
        case .openInTerminal, .openInExternalTerminal, .openInEditor: browser?.developerFolder != nil && !isTyping
        case .copyToOtherPane, .moveToOtherPane: (window?.isSplit ?? false) && hasSelection && !isTyping
        case .moveToTrash: hasSelection && !isTyping
        // The menus never disable these: inside a text field they act on its text (see `BrowserCommands`).
        case .cut, .copy: hasSelection
        case .paste, .selectAll: browser != nil
        case .moveItemHere: !isTyping
        case .splitView: window != nil && !isTyping
        // Disabled while typing, so text fields keep their own ⌥⌘ arrow keys.
        case .focusLeftPane: (window?.canFocusLeft ?? false) && !isTyping
        case .focusRightPane: (window?.canFocusRight ?? false) && !isTyping
        case .swapPanes: (window?.isSplit ?? false) && !isTyping
        case .viewAsList, .viewAsCards, .togglePreview, .toggleHiddenFiles: browser != nil
        case .biggerIcons: browser?.iconSize.bigger != nil
        case .smallerIcons: browser?.iconSize.smaller != nil
        case .goBack: browser?.canGoBack ?? false
        case .goForward: browser?.canGoForward ?? false
        case .enclosingFolder: (browser?.canGoUp ?? false) && !isTyping
        case .goHome, .goDesktop, .goDocuments, .goDownloads, .goToFolder: browser != nil
        case .commandPalette: window != nil
        }
    }

    func perform(_ action: KeyAction) {
        switch action {
        case .newFolder: Task { await browser?.newFolder() }
        case .newWorkspace: window?.requestNewWorkspace()
        case .open: browser?.openSelection()
        case .save: browser?.saveDocument()
        case .rename: browser?.beginRename()
        case .tidyFolder: Task { await browser?.prepareTidy() }
        case .tidyDownloads: Task { await browser?.tidyDownloads() }
        case .smartClean: openSmartClean()
        case .openInTerminal: browser?.openInTerminal()
        case .openInExternalTerminal: browser?.openInExternalTerminal()
        case .openInEditor: browser?.openInEditor()
        case .copyToOtherPane: Task { await window?.copyToOtherPane() }
        case .moveToOtherPane: Task { await window?.moveToOtherPane() }
        case .moveToTrash: Task { await browser?.trashSelection() }
        case .cut: browser?.cutSelection()
        case .copy: browser?.copySelection()
        case .paste: Task { await browser?.paste() }
        case .moveItemHere: Task { await browser?.paste(forceMove: true) }
        case .selectAll: browser?.selectAll()
        case .splitView: window?.toggleSplit()
        case .focusLeftPane: window?.focusLeft()
        case .focusRightPane: window?.focusRight()
        case .swapPanes: window?.swapPanes()
        case .viewAsList: browser?.viewMode = .list
        case .viewAsCards: browser?.viewMode = .cards
        case .biggerIcons: if let next = browser?.iconSize.bigger { browser?.iconSize = next }
        case .smallerIcons: if let next = browser?.iconSize.smaller { browser?.iconSize = next }
        case .togglePreview: browser?.showPreview.toggle()
        case .toggleHiddenFiles: browser?.showHidden.toggle()
        case .goBack: browser?.goBack()
        case .goForward: browser?.goForward()
        case .enclosingFolder: browser?.goUp()
        case .goHome: go(to: "")
        case .goDesktop: go(to: "Desktop")
        case .goDocuments: go(to: "Documents")
        case .goDownloads: go(to: "Downloads")
        case .goToFolder: browser?.isEditingPath = true
        case .commandPalette: window?.togglePalette(openSmartClean: openSmartClean)
        }
    }

    /// The title an action has right now; some menu items change with the state.
    func title(_ action: KeyAction) -> String {
        switch action {
        case .moveToTrash: browser?.isShowingWorkspace == true ? "Remove from Workspace" : action.title
        case .splitView: window?.isSplit == true ? "Close Split View" : action.title
        case .togglePreview: browser?.showPreview == true ? "Hide Preview" : action.title
        case .toggleHiddenFiles: browser?.showHidden == true ? "Hide Hidden Files" : action.title
        case .openInEditor: (browser?.developerTools ?? .shared).openTitle(.editor)
        default: action.title
        }
    }

    /// The commands the palette offers: every action that can run now, except the palette
    /// itself, worded to stand alone ("View as List" rather than the menu's "as List").
    func paletteCommands(shortcuts: KeyBindingStore = .shared) -> [PaletteCommand] {
        KeyAction.allCases
            .filter { $0 != .commandPalette && canPerform($0) }
            .map { action in
                PaletteCommand(
                    id: action.rawValue, title: paletteTitle(action),
                    shortcut: shortcuts.shortcut(for: action)?.display) { perform(action) }
            }
    }

    private func paletteTitle(_ action: KeyAction) -> String {
        switch action {
        case .viewAsList: "View as List"
        case .viewAsCards: "View as Cards"
        case .goBack: "Go Back"
        case .goForward: "Go Forward"
        case .enclosingFolder: "Go to Enclosing Folder"
        case .goHome, .goDesktop, .goDocuments, .goDownloads: "Go to \(action.title)"
        default: title(action)
        }
    }

    private func go(to homeRelativePath: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        browser?.navigate(to: homeRelativePath.isEmpty ? home : home.appending(path: homeRelativePath))
    }
}
