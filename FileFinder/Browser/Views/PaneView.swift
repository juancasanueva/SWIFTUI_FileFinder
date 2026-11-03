import AppKit
import QuickLook
import SwiftUI

/// One browser pane: path bar, file list or cards, status line. Loads and watches its folder.
struct PaneView: View {
    @Bindable var model: BrowserModel
    let isActive: Bool
    /// Shown only when there are two panes, to mark the one keyboard commands act on.
    let showsActiveMarker: Bool
    let onActivate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model)
                .background(showsActiveMarker && isActive ? Color.accentColor.opacity(0.12) : .clear)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onKeyPress(.space, action: handleSpace)
                .onKeyPress(.return, action: handleReturn)
            Divider()
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .overlay(alignment: .top) {
            if showsActiveMarker && isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .simultaneousGesture(TapGesture().onEnded(onActivate))
        // Table clicks don't reach SwiftUI gestures; selecting or navigating also activates.
        .onChange(of: model.selection) { _, selection in if !selection.isEmpty { onActivate() } }
        .onChange(of: model.currentFolder) { onActivate() }
        .task(id: model.watchKey) { await model.run() }
        .quickLookPreview($model.quickLookURL, in: model.items.map(\.url))
        .sheet(item: Binding(get: { model.pendingConflict }, set: { _ in })) { conflict in
            ConflictSheet(conflict: conflict) { model.answerConflict($0) }
        }
        .alert(
            "The operation couldn't be completed.",
            isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } }),
            presenting: model.alertMessage
        ) { _ in
            Button("OK") { model.alertMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = model.loadFailure {
            if failure.needsFullDiskAccess {
                ContentUnavailableView {
                    Label("Can't open this folder", systemImage: "lock")
                } description: {
                    Text("\(failure.message)\n\nGrant Full Disk Access to browse every folder, like Finder.")
                } actions: {
                    Button("Open Privacy Settings") {
                        let link = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Can't open this folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure.message)
                } actions: {
                    Button("Go to Home Folder") {
                        model.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                    }
                }
            }
        } else {
            switch model.viewMode {
            case .list: FileListView(model: model)
            case .cards: FileGridView(model: model)
            }
        }
    }

    private func handleSpace() -> KeyPress.Result {
        guard !model.isTyping, !model.selection.isEmpty else { return .ignored }
        model.toggleQuickLook()
        return .handled
    }

    private func handleReturn() -> KeyPress.Result {
        guard !model.isTyping, model.selection.count == 1 else { return .ignored }
        model.beginRename()
        return .handled
    }
}
