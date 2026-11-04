import AppKit
import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Open in Terminal and editor")
struct DeveloperToolsTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults
    private let opened = Recorder()

    final class Recorder {
        var requests: [DeveloperTools.OpenRequest] = []
    }

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    private func tools(_ installed: Set<String>) -> DeveloperTools {
        let recorder = opened
        return DeveloperTools(
            defaults: defaults,
            locate: { id in installed.contains(id) ? URL(filePath: "/Applications/\(id).app") : nil },
            open: { recorder.requests.append($0) })
    }

    // MARK: - Catalog

    @Test("The terminals and editors from the reference, in its order")
    func catalog() {
        #expect(DeveloperApp.terminals.map(\.name) == ["Terminal", "iTerm", "Warp", "Ghostty"])
        let editors = DeveloperApp.editors.map(\.name)
        #expect(Array(editors.prefix(7)) == ["VS Code", "Cursor", "Zed", "Xcode", "Sublime Text", "Nova", "BBEdit"])
        #expect(editors.contains("IntelliJ IDEA") && editors.contains("WebStorm") && editors.contains("PyCharm"))
        #expect(DeveloperApp.editors.dropFirst(7).allSatisfy { $0.bundleIDs.allSatisfy { $0.hasPrefix("com.jetbrains.") } })
    }

    @Test("Only installed apps are offered")
    func installedOnly() {
        let tools = tools(["com.googlecode.iterm2", "dev.zed.Zed", "com.apple.dt.Xcode"])
        #expect(tools.installed(.terminal).map(\.name) == ["iTerm"])
        #expect(tools.installed(.editor).map(\.name) == ["Zed", "Xcode"])
    }

    @Test("Until one is picked, the first installed app is used; a pick is remembered")
    func preference() {
        let tools = tools(["com.apple.Terminal", "com.mitchellh.ghostty", "dev.zed.Zed", "com.microsoft.VSCode"])
        #expect(tools.preferred(.terminal)?.name == "Terminal")
        #expect(tools.preferred(.editor)?.name == "VS Code")

        tools.setPreferred(DeveloperApp.editors.first { $0.name == "Zed" }!, for: .editor)

        #expect(tools.preferred(.editor)?.name == "Zed")
        #expect(self.tools(["com.microsoft.VSCode", "dev.zed.Zed"]).preferred(.editor)?.name == "Zed")
    }

    @Test("A picked app that was uninstalled falls back to the first installed one")
    func uninstalledPreference() {
        tools(["dev.zed.Zed"]).setPreferred(DeveloperApp.editors.first { $0.name == "Zed" }!, for: .editor)
        #expect(tools(["com.panic.Nova"]).preferred(.editor)?.name == "Nova")
        #expect(tools([]).preferred(.editor) == nil)
    }

    // MARK: - Opening

    @Test("A folder opens in the app; Warp gets a new tab at the folder")
    func opening() throws {
        let tools = tools(["com.microsoft.VSCode", "dev.warp.Warp-Stable"])
        let folder = try dir.folder("My Project")

        try tools.open(folder, in: DeveloperApp.editors[0])
        try tools.open(folder, in: DeveloperApp.terminals.first { $0.name == "Warp" }!)

        #expect(opened.requests.count == 2)
        #expect(opened.requests[0] == .folder(folder, app: URL(filePath: "/Applications/com.microsoft.VSCode.app")))
        guard case .url(let url) = opened.requests[1] else { Issue.record("expected a URL"); return }
        #expect(url.scheme == "warp")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value == folder.path)
    }

    @Test("An app that isn't installed is named in the error, and nothing opens")
    func notInstalled() throws {
        let tools = tools([])
        #expect(throws: DeveloperToolError.notInstalled("Cursor")) {
            try tools.open(dir.url, in: DeveloperApp.editors[1])
        }
        #expect(throws: DeveloperToolError.noneInstalled(.editor)) { try tools.openInPreferred(dir.url, role: .editor) }
        #expect(opened.requests.isEmpty)
    }

    // MARK: - Pane

    private func makePane(_ installed: Set<String>) throws -> BrowserModel {
        let store = WorkspaceStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "FileFinderTests-\(UUID())/workspaces.json"))
        return BrowserModel(start: dir.url, defaults: defaults, workspaces: store, developerTools: tools(installed))
    }

    @Test("The pane opens the folder it's in, or a right-clicked folder")
    func paneOpensFolder() async throws {
        let sub = try dir.folder("app")
        let pane = try makePane(["com.apple.Terminal", "com.microsoft.VSCode"])
        await pane.reload()

        pane.openInTerminal()
        pane.openInEditor(sub.canonical)

        #expect(opened.requests == [
            .folder(dir.url.canonical, app: URL(filePath: "/Applications/com.apple.Terminal.app")),
            .folder(sub.canonical, app: URL(filePath: "/Applications/com.microsoft.VSCode.app")),
        ])
        #expect(pane.alertMessage == nil)
    }

    @Test("In a workspace the single selected folder is used; otherwise there is nothing to open")
    func paneWorkspace() async throws {
        let sub = try dir.folder("app")
        let file = try dir.file("notes.txt")
        let pane = try makePane(["com.apple.Terminal"])
        let workspace = pane.workspaces.create(named: "W")
        pane.workspaces.add([sub, file], to: workspace.id)
        await pane.openWorkspace(workspace.id)

        #expect(pane.developerFolder == nil)
        pane.selection = [file.canonical]
        #expect(pane.developerFolder == nil)
        pane.selection = [sub.canonical]
        #expect(pane.developerFolder == sub.canonical)

        pane.openInTerminal()
        #expect(opened.requests == [.folder(sub.canonical, app: URL(filePath: "/Applications/com.apple.Terminal.app"))])
    }

    @Test("Without an installed editor the pane says so")
    func paneNoEditor() async throws {
        let pane = try makePane([])
        pane.openInEditor()
        #expect(pane.alertMessage == "No editor is installed. Install one of VS Code, Cursor, Zed, Xcode, Sublime Text, Nova, BBEdit or a JetBrains IDE.")
        #expect(opened.requests.isEmpty)
    }
}
