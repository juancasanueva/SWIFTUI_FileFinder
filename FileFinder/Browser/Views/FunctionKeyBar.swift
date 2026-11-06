import SwiftUI

/// The bar at the bottom of the window: each function key with what it does. Every entry is
/// also a button. F7 to F10 take their keys here; F2, F5 and F6 belong to the menus.
struct FunctionKeyBar: View {
    let window: BrowserWindowModel
    let keys: KeyBindingStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(window.barCommands) { command in
                    if let label = command.keyLabel(keys.shortcut(for:)) {
                        entry(command, label: label)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func entry(_ command: FunctionKeyCommand, label: String) -> some View {
        Button {
            Task { await window.perform(command) }
        } label: {
            HStack(spacing: 6) {
                Text(label).fontWeight(.semibold).foregroundStyle(Color.accentColor)
                Text(command.title).foregroundStyle(.secondary)
            }
            .font(.callout.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(ownShortcut(command)?.keyboardShortcut)
        .disabled(!window.canPerform(command))
        .help(label + " " + command.title)
    }

    /// F7 to F10, unless keybindings.json gives that key to a menu action, which then wins.
    private func ownShortcut(_ command: FunctionKeyCommand) -> Shortcut? {
        guard let shortcut = command.fixedShortcut,
              !KeyAction.allCases.contains(where: { keys.shortcut(for: $0) == shortcut })
        else { return nil }
        return shortcut
    }
}
