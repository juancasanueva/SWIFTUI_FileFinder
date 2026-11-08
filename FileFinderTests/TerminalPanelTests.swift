import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Terminal panel")
struct TerminalPanelTests {
    let folder = URL(filePath: "/tmp/FileFinderTerminal", directoryHint: .isDirectory)

    @Test("The Terminal button opens a shell in the folder, and again closes it")
    func toggle() {
        let panel = TerminalPanelModel()
        #expect(panel.session == nil)

        panel.toggle(in: folder)
        #expect(panel.session?.folder == folder)

        panel.toggle(in: folder)
        #expect(panel.session == nil)
    }

    @Test("Each opening is a new shell")
    func reopenStartsNewShell() throws {
        let panel = TerminalPanelModel()
        panel.toggle(in: folder)
        let first = try #require(panel.session)
        panel.toggle(in: folder)
        panel.toggle(in: folder)
        #expect(panel.session?.id != first.id)
    }

    @Test("When the shell exits, the panel closes")
    func shellExitClosesPanel() throws {
        let panel = TerminalPanelModel()
        panel.toggle(in: folder)
        let session = try #require(panel.session)

        panel.shellExited(session.id)
        #expect(panel.session == nil)
    }

    @Test("An older shell exiting leaves the current one open")
    func staleExitIgnored() throws {
        let panel = TerminalPanelModel()
        panel.toggle(in: folder)
        let old = try #require(panel.session)
        panel.toggle(in: folder)
        panel.toggle(in: folder)

        panel.shellExited(old.id)
        #expect(panel.session != nil)
    }

    @Test("Close ends the shell, and does nothing when it is already closed")
    func close() {
        let panel = TerminalPanelModel()
        panel.toggle(in: folder)
        panel.close()
        #expect(panel.session == nil)

        panel.close()
        #expect(panel.session == nil)
    }

    @Test("A workspace with no single folder selected opens the panel in home")
    func workspaceFallsBackToHome() async throws {
        let dir = try TemporaryDirectory()
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let store = WorkspaceStore(fileURL: dir.url.appending(path: "store/workspaces.json"))
        let workspace = store.create(named: "Work")
        let window = BrowserWindowModel(
            restoring: nil, defaultStart: dir.url, defaults: defaults, workspaces: store)
        await window.active.openWorkspace(workspace.id)
        #expect(window.active.developerFolder == nil)

        window.toggleTerminal()
        #expect(window.terminal.session?.folder == FileManager.default.homeDirectoryForCurrentUser)
    }

    @Test("Ghostty's config files are read where Ghostty reads them, in its order")
    func configFiles() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let all: Set<String> = [
            "/Users/me/.config/ghostty/config",
            "/Users/me/.config/ghostty/config.ghostty",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "/xdg/ghostty/config",
        ]
        let exists = { (url: URL) in all.contains(url.path) }

        #expect(TerminalPanel.ghosttyConfigFiles(environment: [:], home: home, exists: exists).map(\.path) == [
            "/Users/me/.config/ghostty/config",
            "/Users/me/.config/ghostty/config.ghostty",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
        #expect(TerminalPanel.ghosttyConfigFiles(
            environment: ["XDG_CONFIG_HOME": "/xdg"], home: home, exists: exists).first?.path
            == "/xdg/ghostty/config")
        #expect(TerminalPanel.ghosttyConfigFiles(environment: [:], home: home, exists: { _ in false }).isEmpty)
    }

    @Test("The config is the files' contents in order, so later files win; unreadable ones are skipped")
    func configContents() {
        let a = URL(filePath: "/a/config"), b = URL(filePath: "/b/config"), c = URL(filePath: "/c/config")
        let contents = [a: "font-size = 12", b: "font-size = 14\n"]
        #expect(TerminalPanel.ghosttyConfig(from: [a, c, b], read: { contents[$0] })
            == "font-size = 12\nfont-size = 14\n")
    }

    @Test("An empty XDG_CONFIG_HOME means ~/.config, and Application Support still follows")
    func emptyXDG() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let all: Set<String> = [
            "/Users/me/.config/ghostty/config",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config",
        ]
        let files = TerminalPanel.ghosttyConfigFiles(
            environment: ["XDG_CONFIG_HOME": ""], home: home, exists: { all.contains($0.path) })
        #expect(files.map(\.path) == [
            "/Users/me/.config/ghostty/config",
            "/Users/me/Library/Application Support/com.mitchellh.ghostty/config",
        ])
    }

    @Test("Open in Terminal starts a shell when none is open, and otherwise asks the open one to cd")
    func openIn() throws {
        let panel = TerminalPanelModel()
        panel.open(in: folder)
        let first = try #require(panel.session)
        #expect(panel.cdRequest == nil)

        let other = URL(filePath: "/tmp/Other", directoryHint: .isDirectory)
        panel.open(in: other)
        #expect(panel.session == first)
        let request = try #require(panel.cdRequest)
        #expect(request.folder == other)

        panel.open(in: other)
        #expect(panel.cdRequest != request)  // asked again: the shell may have moved since
    }

    @Test("The cd typed into the shell quotes the folder, and is skipped when the shell is already there")
    func cdCommand() {
        #expect(TerminalPanel.cdCommand(to: URL(filePath: "/Users/me/My Files"), from: "/Users/me")
            == "cd '/Users/me/My Files'")
        #expect(TerminalPanel.cdCommand(to: URL(filePath: "/Users/me/it's"), from: nil)
            == "cd '/Users/me/it'\\''s'")
        #expect(TerminalPanel.cdCommand(to: URL(filePath: "/Users/me/api/"), from: "/Users/me/api") == nil)
    }

    @Test("No cd is typed when the shell is already in the folder, however it is written", arguments: [
        "/tmp/FileFinderTerminal/", "/tmp/FileFinderTerminal/sub/..", "/tmp/./FileFinderTerminal",
    ])
    func noCDForSameFolder(path: String) {
        #expect(TerminalPanel.cdCommand(to: URL(filePath: path), from: "/tmp/FileFinderTerminal") == nil)
    }

    @Test("Every pane's Open in Terminal reaches the window's panel, the second pane's too")
    func panesOpenWindowPanel() throws {
        let dir = try TemporaryDirectory()
        let sub = try dir.folder("api")
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let window = BrowserWindowModel(restoring: nil, defaultStart: dir.url, defaults: defaults)

        window.active.openInTerminal(sub.canonical)
        #expect(window.terminal.session?.folder == sub.canonical)

        window.toggleSplit()
        window.panes[1].openInTerminal(dir.url.canonical)
        #expect(window.terminal.session?.folder == sub.canonical)
        #expect(window.terminal.cdRequest?.folder == dir.url.canonical)
    }

    @Test("Both panes of a window restored in split view open the window's panel")
    func restoredPanesOpenWindowPanel() throws {
        let dir = try TemporaryDirectory()
        let sub = try dir.folder("api")
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let state = WindowState(folders: [dir.url.path, sub.path], activeIndex: 0)
        let window = BrowserWindowModel(restoring: state, defaultStart: dir.url, defaults: defaults)
        #expect(window.isSplit)

        window.panes[1].openInTerminal()
        #expect(window.terminal.session?.folder == window.panes[1].developerFolder)
        window.panes[0].openInTerminal()
        #expect(window.terminal.cdRequest?.folder == window.panes[0].developerFolder)
    }

    @Test("A window's panel opens in the active pane's folder")
    func windowFolder() throws {
        let dir = try TemporaryDirectory()
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let window = BrowserWindowModel(restoring: nil, defaultStart: dir.url, defaults: defaults)
        window.toggleTerminal()
        #expect(window.terminal.session?.folder == window.active.developerFolder)

        window.toggleTerminal()
        #expect(window.terminal.session == nil)
    }
}

@MainActor
@Suite("Terminal focus (⌥⌘↓ / ⌥⌘↑)")
struct TerminalFocusTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    private func makeWindow() -> BrowserWindowModel {
        BrowserWindowModel(restoring: nil, defaultStart: dir.url, defaults: defaults)
    }

    @Test("⌥⌘↓ moves focus into the terminal only while it is open and not focused")
    func focusTerminal() {
        let window = makeWindow()
        let runner = { KeyActionRunner(browser: window.active, window: window) }
        #expect(!runner().canPerform(.focusTerminal))

        window.toggleTerminal()
        #expect(runner().canPerform(.focusTerminal))
        let before = window.terminal.focusRequest
        runner().perform(.focusTerminal)
        #expect(window.terminal.focusRequest == before + 1)

        window.terminal.isFocused = true
        #expect(!runner().canPerform(.focusTerminal))
    }

    @Test("⌥⌘↑ from the terminal goes back to the pane focus came from")
    func backToPane() {
        let window = makeWindow()
        window.toggleSplit()
        window.toggleTerminal()
        window.focusPane(at: 1)
        let runner = { KeyActionRunner(browser: window.active, window: window) }
        #expect(!runner().canPerform(.focusFiles))  // already in the files

        window.focusTerminal()
        window.terminal.isFocused = true
        #expect(runner().canPerform(.focusFiles))
        let right = window.panes[1]
        let before = right.focusRequest
        runner().perform(.focusFiles)
        #expect(window.activeIndex == 1)
        #expect(right.focusRequest == before + 1)
    }

    @Test("Closing the terminal while it has focus forgets the focus")
    func closeClearsFocus() {
        let window = makeWindow()
        window.toggleTerminal()
        window.terminal.isFocused = true
        window.toggleTerminal()
        #expect(!window.terminal.isFocused)

        window.toggleTerminal()
        window.terminal.isFocused = true
        window.terminal.close()
        #expect(!window.terminal.isFocused)
    }

    @Test("From the terminal, ⌥⌘← goes to the left pane and ⌥⌘→ to the right one")
    func sidewaysFromTerminal() {
        let window = makeWindow()
        window.toggleSplit()
        window.toggleTerminal()
        let runner = { KeyActionRunner(browser: window.active, window: window) }

        // The left pane was active: ⌥⌘← lands on it rather than skipping on to the sidebar.
        window.focusPane(at: 0)
        window.terminal.isFocused = true
        let left = window.panes[0]
        let leftBefore = left.focusRequest
        #expect(runner().canPerform(.focusLeftPane))
        runner().perform(.focusLeftPane)
        #expect(window.activeIndex == 0)
        #expect(left.focusRequest == leftBefore + 1)

        window.terminal.isFocused = true
        #expect(runner().canPerform(.focusRightPane))
        runner().perform(.focusRightPane)
        #expect(window.activeIndex == 1)
    }

    @Test("From the terminal with one pane, ⌥⌘← goes to it and ⌥⌘→ has nowhere to go")
    func sidewaysFromTerminalOnePane() {
        let window = makeWindow()
        window.toggleTerminal()
        window.terminal.isFocused = true
        let runner = { KeyActionRunner(browser: window.active, window: window) }
        #expect(!runner().canPerform(.focusRightPane))
        let before = window.active.focusRequest
        runner().perform(.focusLeftPane)
        #expect(window.active.focusRequest == before + 1)
    }

    @Test("The focus border needs a second area: a second pane, the terminal, or both")
    func focusBorderNeedsTwoAreas() {
        let window = makeWindow()
        #expect(window.focusBorder == nil)

        window.toggleTerminal()
        #expect(window.focusBorder == .pane(0))
        window.toggleTerminal()

        window.toggleSplit()
        #expect(window.focusBorder == .pane(0))
    }

    @Test("The focus border follows focus: the active pane, the terminal, or nothing from the sidebar")
    func focusBorderFollowsFocus() {
        let window = makeWindow()
        window.toggleSplit()
        window.toggleTerminal()
        window.focusPane(at: 1)
        #expect(window.focusBorder == .pane(1))

        window.terminal.isFocused = true
        #expect(window.focusBorder == .terminal)

        window.terminal.isFocused = false
        window.isSidebarFocused = true
        #expect(window.focusBorder == nil)
    }

    @Test("The default keys are ⌥⌘↓ and ⌥⌘↑")
    func defaultKeys() {
        #expect(KeyAction.focusTerminal.defaultShortcut?.text == "cmd+alt+down")
        #expect(KeyAction.focusFiles.defaultShortcut?.text == "cmd+alt+up")
    }
}
