import SwiftUI

/// In-place rename editor. Return or leaving the field commits; Escape cancels.
struct RenameField: View {
    let item: FileItem
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(item: FileItem, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.item = item
        self.onCommit = onCommit
        self.onCancel = onCancel
        _text = State(initialValue: item.name)
    }

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { onCommit(text) }
            .onKeyPress(.escape) {
                onCancel()
                return .handled
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { onCommit(text) }
            }
            .accessibilityLabel("Rename \(item.name)")
    }
}
