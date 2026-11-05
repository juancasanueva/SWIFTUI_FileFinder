import GhosttyTerminal
import SwiftUI

/// A Ghostty terminal running a shell in the session's folder. It ends with the view.
struct TerminalPanel: View {
    let session: TerminalPanelModel.Session
    let panel: TerminalPanelModel
    @StateObject private var terminal = TerminalViewState(controller: TerminalPanel.controller)

    /// One libghostty app for every panel. It reads the user's Ghostty config, so fonts, theme
    /// and keybindings match their Ghostty.
    private static let controller: TerminalController = {
        let files = ghosttyConfigFiles(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser,
            exists: { FileManager.default.fileExists(atPath: $0.path) })
        return files.isEmpty
            ? TerminalController()
            : TerminalController(configSource: .generated(ghosttyConfig(including: files)))
    }()

    /// The config files Ghostty itself loads on macOS, in its order (later ones win): the XDG
    /// folder (`$XDG_CONFIG_HOME`, else `~/.config`), then Application Support.
    nonisolated static func ghosttyConfigFiles(
        environment: [String: String], home: URL, exists: (URL) -> Bool
    ) -> [URL] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? home.appending(path: ".config")
        let folders = [
            xdg.appending(path: "ghostty"),
            home.appending(path: "Library/Application Support/com.mitchellh.ghostty"),
        ]
        return folders
            .flatMap { [$0.appending(path: "config"), $0.appending(path: "config.ghostty")] }
            .filter(exists)
    }

    /// A config that includes each file by absolute path, so their own relative includes and
    /// themes still resolve from where they live.
    nonisolated static func ghosttyConfig(including files: [URL]) -> String {
        files.map { "config-file = \"\($0.path)\"\n" }.joined()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalSurfaceView(context: terminal)
        }
        .onAppear {
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec, workingDirectory: session.folder.path)
            terminal.onClose = { [id = session.id] _ in panel.shellExited(id) }
            terminal.requestFocus()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
            Text(terminal.title.isEmpty ? session.folder.lastPathComponent : terminal.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Close Terminal", systemImage: "xmark") { panel.close() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Close the terminal; its shell ends")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
