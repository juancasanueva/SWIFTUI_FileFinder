import SwiftUI

/// Settings (⌘,): the terminal and editor folders open in, among the installed ones.
struct SettingsView: View {
    let tools: DeveloperTools

    var body: some View {
        Form {
            Section {
                AppPicker(title: "Terminal", role: .terminal, tools: tools)
                AppPicker(title: "Editor", role: .editor, tools: tools)
            } footer: {
                Text("⌥⇧⌘T opens the current folder in the terminal, ⌥⇧⌘E in the editor. You can also type `code .`, `cursor .`, `xed .`, `zed`, `warp` or `terminal` in the path bar (⌘L).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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
