import AppKit
import QuickLook
import SwiftUI

/// One browser pane: path bar, file list or cards, status line. Loads and watches its folder.
struct PaneView: View {
    @Bindable var model: BrowserModel
    let isActive: Bool
    /// Shown only when there are two panes, to mark the one keyboard commands act on.
    let showsActiveMarker: Bool
    /// A blue border: this pane has keyboard focus and is not the only area in the window.
    var hasFocusBorder = false
    let onActivate: () -> Void

    var body: some View {
        layout
            .overlay {
                if hasFocusBorder { FocusBorderView() }
            }
            .simultaneousGesture(TapGesture().onEnded(onActivate))
            // Table clicks don't reach SwiftUI gestures; selecting or navigating also activates.
            .onChange(of: model.selection) { _, selection in if !selection.isEmpty { onActivate() } }
            .onChange(of: model.location) { onActivate() }
            .modifier(PaneBehavior(model: model))
    }

    private var layout: some View {
        VStack(spacing: 0) {
            PathBar(model: model)
                .background(showsActiveMarker && isActive ? Color.accentColor.opacity(0.12) : .clear)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onKeyPress(.space, action: handleSpace)
                .onKeyPress(.return, action: handleReturn)
                .onKeyPress(keys: BackspaceKey.keys, action: handleBackspace)
            if !model.missingEntries.isEmpty {
                MissingEntriesBar(model: model)
            }
            Divider()
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
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
            // A workspace gathers items from many folders, so it has no columns to show.
            case .columns where model.isShowingWorkspace: FileListView(model: model)
            case .columns: ColumnBrowserView(model: model)
            }
        }
    }

    private func handleSpace() -> KeyPress.Result {
        guard !model.isTyping, !model.selection.isEmpty else { return .ignored }
        model.toggleQuickLook()
        return .handled
    }

    /// Return enters a selected folder or opens a selected file. F2 renames either.
    private func handleReturn() -> KeyPress.Result {
        guard !model.isTyping, model.selection.count == 1 else { return .ignored }
        return model.openSelectedItem() ? .handled : .ignored
    }

    /// Backspace goes up to the enclosing folder.
    private func handleBackspace(_ press: KeyPress) -> KeyPress.Result {
        guard !model.isTyping, model.canGoUp,
              BackspaceKey.goesUp(characters: press.characters, modifiers: press.modifiers)
        else { return .ignored }
        model.goUp()
        return .handled
    }
}

/// The Mac Backspace key arrives as DEL (U+007F), not as `KeyEquivalent.delete` (U+0008), so
/// both are matched. Only Caps Lock may be on: ⌘⌫ is Move to Trash.
enum BackspaceKey {
    static let keys: Set<KeyEquivalent> = [.delete, KeyEquivalent("\u{7F}")]

    static func goesUp(characters: String, modifiers: EventModifiers) -> Bool {
        keys.contains(where: { String($0.character) == characters })
            && modifiers.isDisjoint(with: [.command, .option, .control, .shift])
    }
}

/// Workspace items that can't be found anymore (deleted, or moved to the Trash).
private struct MissingEntriesBar: View {
    let model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "questionmark.folder").foregroundStyle(.secondary)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Button("Remove from Workspace") {
                    model.removeFromWorkspace(Set(model.missingEntries.map(\.id)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var summary: String {
        let names = model.missingEntries.map(\.name).joined(separator: ", ")
        let count = model.missingEntries.count
        return "\(count) item\(count == 1 ? "" : "s") can't be found: \(names)"
    }
}

/// Loading, watching, Quick Look, the conflict prompt and error alerts of one pane.
private struct PaneBehavior: ViewModifier {
    @Bindable var model: BrowserModel

    func body(content: Content) -> some View {
        content
            .task(id: model.watchKey) { await model.run() }
            // A workspace has no folder to watch: reload when its entries change (here or elsewhere).
            .onChange(of: model.currentWorkspace?.entries) { Task { await model.reload() } }
            .quickLookPreview($model.quickLookURL, in: model.items.map(\.url))
            .sheet(item: Binding(get: { model.pendingConflict }, set: { _ in })) { conflict in
                ConflictSheet(conflict: conflict) { model.answerConflict($0) }
            }
            .sheet(item: Binding(get: { model.tidyPreview }, set: { if $0 == nil { model.cancelTidy() } })) { plan in
                TidySheet(
                    plan: plan,
                    onTidy: { Task { await model.confirmTidy() } },
                    onCancel: model.cancelTidy)
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
}

/// The blue border around the pane or terminal that has keyboard focus.
struct FocusBorderView: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .allowsHitTesting(false)
    }
}
