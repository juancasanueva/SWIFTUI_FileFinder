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
            } else if let workspace = model.currentWorkspace {
                Label(workspace.name, systemImage: "square.stack.3d.up")
                    .lineLimit(1)
                Spacer()
                Text("Workspace · nothing is copied or moved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            if let git = model.gitStatus {
                GitBadge(status: git)
            }
        }
    }

    private var editor: some View {
        TextField("Go to folder, or type code . to open it in VS Code", text: $text)
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
                // A folder path, or a command such as `code .` (see `PathBarCommand`).
                if !model.submitPath(text) { NSSound.beep() }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { model.isEditingPath = false }
            }
    }
}

/// "⎇ main · 3 changes" for a folder inside a git work tree.
private struct GitBadge: View {
    let status: GitStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
            Text(status.branch)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            if let changes = status.changes {
                Text("·").foregroundStyle(.tertiary)
                Text(changes == 0 ? "clean" : changes == 1 ? "1 change" : "\(changes) changes")
                    .foregroundStyle(changes == 0 ? Color.secondary : Color.orange)
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: .capsule)
        .fixedSize()
        .help(help)
    }

    private var help: String {
        let kind = status.isDetached ? "Detached at \(status.branch)" : "Branch \(status.branch)"
        return "\(kind) in \(status.root.path). Read-only: nothing is fetched, pulled or changed."
    }
}
