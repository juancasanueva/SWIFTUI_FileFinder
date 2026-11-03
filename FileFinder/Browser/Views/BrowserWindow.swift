import AppKit
import QuickLook
import SwiftUI

extension FocusedValues {
    /// The browser of the key window, used by menu commands.
    @Entry var browser: BrowserModel?
}

struct BrowserWindow: View {
    @Environment(\.undoManager) private var undoManager
    @State private var model = BrowserModel(start: BrowserModel.defaultStartFolder())

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            VStack(spacing: 0) {
                PathBar(model: model)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onKeyPress(.space, action: handleSpace)
                    .onKeyPress(.return, action: handleReturn)
                TransferBar(actions: model.actions)
                Divider()
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
        }
        .inspector(isPresented: $model.showPreview) {
            PreviewPane(model: model)
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
        }
        .navigationTitle(model.title)
        .toolbar { toolbar }
        .focusedSceneValue(\.browser, model)
        .task(id: model.watchKey) { await model.run() }
        .onAppear { model.actions.undoManager = undoManager }
        .onDisappear { model.windowWillClose() }
        .onChange(of: undoManager) { _, manager in model.actions.undoManager = manager }
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
        .frame(minWidth: 720, minHeight: 420)
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left", action: model.goBack)
                .disabled(!model.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: model.goForward)
                .disabled(!model.canGoForward)
        }
        ToolbarItem {
            Button("Preview", systemImage: "sidebar.right") { model.showPreview.toggle() }
                .help("Show or hide the preview pane (⇧⌘P)")
        }
        ToolbarItem {
            Picker("View", selection: $model.viewMode) {
                Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                Label("Cards", systemImage: "square.grid.2x2").tag(BrowserViewMode.cards)
            }
            .pickerStyle(.segmented)
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
