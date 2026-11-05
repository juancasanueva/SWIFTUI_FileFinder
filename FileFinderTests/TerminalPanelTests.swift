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

    @Test("The config includes each file by absolute path, quoted")
    func configIncludes() {
        let files = [URL(filePath: "/Users/me/Library/Application Support/com.mitchellh.ghostty/config")]
        #expect(TerminalPanel.ghosttyConfig(including: files)
            == "config-file = \"/Users/me/Library/Application Support/com.mitchellh.ghostty/config\"\n")
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
