import SwiftUI

/// Settings (⌘,): General (the terminal and editor folders open in) and Keyboard (the menu
/// shortcuts, kept in keybindings.json).
struct SettingsView: View {
    let tools: DeveloperTools

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(tools: tools, keys: .shared)
            }
            Tab("Keyboard", systemImage: "keyboard") {
                KeyboardSettings(keys: .shared)
            }
        }
    }
}

private struct GeneralSettings: View {
    let tools: DeveloperTools
    let keys: KeyBindingStore

    var body: some View {
        Form {
            Section {
                AppPicker(title: "Terminal", role: .terminal, tools: tools)
                AppPicker(title: "Editor", role: .editor, tools: tools)
            } footer: {
                Text(LocalizedStringKey(footer))   // renders the `code` spans
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: String {
        let terminal = keys.shortcut(for: .openInTerminal)?.display
        let editor = keys.shortcut(for: .openInEditor)?.display
        let keysText = switch (terminal, editor) {
        case let (terminal?, editor?): "\(terminal) opens the current folder in the terminal, \(editor) in the editor. "
        case let (terminal?, nil): "\(terminal) opens the current folder in the terminal. "
        case let (nil, editor?): "\(editor) opens the current folder in the editor. "
        case (nil, nil): ""
        }
        let goTo = keys.shortcut(for: .goToFolder).map { " (\($0.display))" } ?? ""
        return keysText + "You can also type `code .`, `cursor .`, `xed .`, `zed`, `warp` or `terminal` in the path bar\(goTo)."
    }
}

private struct AppPicker: View {
    let title: String
    let role: DeveloperApp.Role
    let tools: DeveloperTools
    @State private var installed: [DeveloperApp] = []
    @State private var selection: DeveloperApp.ID?

    var body: some View {
        Group {
            if installed.isEmpty {
                LabeledContent(title) {
                    Text(DeveloperToolError.noneInstalled(role).localizedDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Picker(title, selection: $selection) {
                    ForEach(installed) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        }
        .onAppear {
            installed = tools.installed(role)
            selection = tools.preferred(role)?.id
        }
        .onChange(of: selection) { _, id in
            if let app = installed.first(where: { $0.id == id }) { tools.setPreferred(app, for: role) }
        }
    }
}
