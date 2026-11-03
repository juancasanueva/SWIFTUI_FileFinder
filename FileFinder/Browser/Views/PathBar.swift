import AppKit
import SwiftUI

/// Breadcrumbs for the current folder; ⌘L (or clicking the empty area) switches to a typed path
/// with Tab completion.
struct PathBar: View {
    @Bindable var model: BrowserModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if model.isEditingPath {
                editor
            } else {
                breadcrumbs
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var breadcrumbs: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    let crumbs = PathInput.breadcrumbs(for: model.currentFolder)
                    ForEach(crumbs, id: \.self) { crumb in
                        Button { model.navigate(to: crumb) } label: {
                            Label(FileManager.default.displayName(atPath: crumb.path), systemImage: "folder")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(crumb == crumbs.last ? .primary : .secondary)
                        if crumb != crumbs.last {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .defaultScrollAnchor(.trailing)

            Color.clear
                .frame(minWidth: 40, maxHeight: .infinity)
                .contentShape(.rect)
                .onTapGesture { model.isEditingPath = true }
                .accessibilityLabel("Type a path")
                .accessibilityAddTraits(.isButton)
        }
    }

    private var editor: some View {
        TextField("Go to folder", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .focused($isFocused)
            .onAppear {
                text = model.currentFolder.path == "/" ? "/" : model.currentFolder.path + "/"
                isFocused = true
            }
            .onKeyPress(.tab) {
                text = PathInput.complete(text, relativeTo: model.currentFolder)
                return .handled
            }
            .onKeyPress(.escape) {
                model.isEditingPath = false
                return .handled
            }
            .onSubmit {
                guard let folder = PathInput.resolve(text, relativeTo: model.currentFolder) else {
                    NSSound.beep()
                    return
                }
                model.isEditingPath = false
                model.navigate(to: folder)
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { model.isEditingPath = false }
            }
    }
}
