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
        let config = URL.homeDirectory.appending(path: ".config/ghostty/config").path
        return FileManager.default.fileExists(atPath: config)
            ? TerminalController(configSource: .file(config))
            : TerminalController()
    }()

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
            Button("Close Terminal", systemImage: "xmark") { panel.toggle(in: session.folder) }
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
