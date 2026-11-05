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

    @Test("A window's panel opens in the active pane's folder, or home without one")
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
