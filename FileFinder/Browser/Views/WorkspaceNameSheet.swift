import SwiftUI

/// Names a new workspace, or renames one.
struct WorkspaceNameSheet: View {
    let title: String
    let actionTitle: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @FocusState private var isFocused: Bool

    init(title: String, actionTitle: String, initialName: String,
         onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.actionTitle = actionTitle
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Workspace name", text: $name, prompt: Text("Untitled Workspace"))
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onSubmit { onSave(name) }
            Text("A workspace gathers folders and files from anywhere. Nothing is copied or moved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) { onSave(name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
