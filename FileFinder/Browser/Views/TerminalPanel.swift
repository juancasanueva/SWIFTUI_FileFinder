import AppKit
import GhosttyTerminal
import SwiftUI

/// A Ghostty terminal running a shell in the session's folder. It ends with the view.
struct TerminalPanel: View {
    let session: TerminalPanelModel.Session
    let panel: TerminalPanelModel
    /// A focus key (⌥⌘↑, ⌥⌘←, ⌥⌘→) pressed in the shell; returns whether it was used.
    var onFocusKey: (KeyAction) -> Bool = { _ in false }
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
            : TerminalController(configSource: .generated(ghosttyConfig(
                from: files, read: { try? String(contentsOf: $0, encoding: .utf8) })))
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

    /// The files' contents one after another, as Ghostty reads them: a later setting wins.
    /// Inlined because the package loads only the file it is given, never `config-file` includes.
    nonisolated static func ghosttyConfig(from files: [URL], read: (URL) -> String?) -> String {
        files.compactMap(read).map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TerminalSurfaceView(context: terminal)
        }
        .background(FocusKeyMonitor(terminal: terminal, action: onFocusKey))
        .onChange(of: terminal.isFocused) { _, focused in panel.isFocused = focused }
        .onChange(of: panel.focusRequest) { terminal.requestFocus() }
        .onAppear {
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec, workingDirectory: session.folder.path)
            terminal.onClose = { [id = session.id] _ in panel.shellExited(id) }
            terminal.requestFocus()
        }
        .onChange(of: panel.cdRequest) { _, request in
            guard let request else { return }
            if let command = Self.cdCommand(to: request.folder, from: terminal.workingDirectory) {
                // Ctrl-E, Ctrl-U clear a half-typed line first, so it is not run with the cd.
                // Pasted, then Enter as a key: a `\r` inside a paste would not run the line.
                _ = terminal.sendKey(.e, modifiers: .ctrl)
                _ = terminal.sendKey(.u, modifiers: .ctrl)
                _ = terminal.paste(text: command)
                _ = terminal.sendKey(.enter)
            }
            terminal.requestFocus()
        }
    }

    /// What to type so the shell moves to `folder`: `nil` when it is already there (its folder as
    /// last reported by the shell). The path is single-quoted, so spaces and quotes are safe.
    nonisolated static func cdCommand(to folder: URL, from current: String?) -> String? {
        if let current, URL(filePath: current).canonical == folder.canonical { return nil }
        let quoted = folder.canonical.path.replacingOccurrences(of: "'", with: "'\\''")
        return "cd '\(quoted)'"
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

/// Catches the focus keys (⌥⌘↑, ⌥⌘←, ⌥⌘→) while the shell has focus. Ghostty binds ⌥⌘ with
/// the arrows itself (to move between its splits) and would take them before the menu sees
/// them; a local event monitor sees them first. A key with nowhere to go is left to Ghostty.
private struct FocusKeyMonitor: NSViewRepresentable {
    static let actions: [KeyAction] = [.focusFiles, .focusLeftPane, .focusRightPane]

    let terminal: TerminalViewState
    let action: (KeyAction) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let window = event.window, window === view?.window,
                  let shell = coordinator.terminal?.attachedPlatformView, window.firstResponder === shell,
                  let pressed = Shortcut(
                      keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                      flags: event.modifierFlags),
                  let action = Self.actions.first(where: { KeyBindingStore.shared.shortcut(for: $0) == pressed })
            else { return event }
            return coordinator.action(action) ? nil : event
        }
        update(coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.terminal = terminal
        coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var monitor: Any?
        weak var terminal: TerminalViewState?
        var action: (KeyAction) -> Bool = { _ in false }
    }
}
