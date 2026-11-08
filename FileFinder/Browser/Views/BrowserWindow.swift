import AppKit
import SwiftUI

extension FocusedValues {
    /// The active pane of the key window, used by menu commands.
    @Entry var browser: BrowserModel?
    /// The key window, for pane commands (split, swap, copy/move to the other pane).
    @Entry var browserWindow: BrowserWindowModel?
}

/// A browser window. Its panes and folders are restored after relaunch.
struct BrowserWindow: View {
    @SceneStorage("windowState") private var savedState = ""
    @State private var window: BrowserWindowModel?

    var body: some View {
        if let window {
            BrowserWindowContent(window: window)
                .onChange(of: window.state) { _, state in savedState = state.encoded }
        } else {
            // @SceneStorage is only readable once the view is in a scene, so build the model here.
            Color.clear.onAppear {
                window = BrowserWindowModel(restoring: try? WindowState(encoded: savedState))
            }
        }
    }
}

private struct BrowserWindowContent: View {
    @Environment(\.undoManager) private var undoManager
    let window: BrowserWindowModel

    var body: some View {
        @Bindable var active = window.active
        // The window model needs to know whether the sidebar is showing, for ⌥⌘←.
        NavigationSplitView(columnVisibility: Binding(
            get: { window.isSidebarVisible ? .all : .detailOnly },
            set: { window.isSidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView(model: active, window: window)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    PaneSplit(panes: window.panes) { pane in
                        PaneView(
                            model: pane, isActive: pane === active, showsActiveMarker: window.isSplit,
                            onActivate: { window.activate(pane) })
                    }
                    .frame(minHeight: 160)
                    if let session = window.terminal.session {
                        TerminalPanel(session: session, panel: window.terminal)
                            .id(session.id)
                            // VSplitView sizes a new pane by its minimum; drag the divider for more.
                            .frame(minHeight: 200)
                    }
                }
                TransferBar(actions: window.actions)
                FunctionKeyBar(window: window, keys: .shared)
            }
        }
        .inspector(isPresented: $active.showPreview) {
            PreviewPane(model: active)
                .inspectorColumnWidth(min: 220, ideal: 280, max: 420)
        }
        .navigationTitle(active.title)
        .toolbar { toolbar(active) }
        .focusedSceneValue(\.browser, active)
        .focusedSceneValue(\.browserWindow, window)
        .onAppear { window.actions.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in window.actions.undoManager = manager }
        .onDisappear { window.windowWillClose() }
        .sheet(item: Binding(get: { window.namingRequest }, set: { if $0 == nil { window.cancelNaming() } })) { request in
            WorkspaceNameSheet(
                title: request == .create ? "New Workspace" : "Rename Workspace",
                actionTitle: request == .create ? "Create" : "Rename",
                initialName: window.currentName(for: request),
                onSave: { name in Task { await window.finishNaming(name) } },
                onCancel: window.cancelNaming)
        }
        .overlay(alignment: .top) { paletteOverlay }
        .frame(minWidth: 720, minHeight: 420)
    }

    @ViewBuilder
    private var paletteOverlay: some View {
        if let palette = window.palette {
            ZStack(alignment: .top) {
                // A click outside the palette closes it.
                Color.black.opacity(0.001)
                    .onTapGesture { window.closePalette() }
                CommandPaletteView(
                    palette: palette,
                    onActivate: { window.activatePalette(revealing: $0) },
                    onClose: window.closePalette)
                    .padding(.top, 56)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ active: BrowserModel) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left", action: active.goBack)
                .disabled(!active.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: active.goForward)
                .disabled(!active.canGoForward)
        }
        ToolbarItem {
            Button(window.isSplit ? "Single Pane" : "Split", systemImage: "rectangle.split.2x1") {
                window.toggleSplit()
            }
            .help("Split into two panes (⌘D)")
        }
        ToolbarItemGroup {
            Button("Terminal", systemImage: "terminal") { window.toggleTerminal() }
                .help("Show or hide a terminal in this folder")
            Button("Editor", systemImage: "chevron.left.forwardslash.chevron.right") { active.openInEditor() }
                .disabled(active.developerFolder == nil)
                .help("\(active.developerTools.openTitle(.editor)) (⌥⇧⌘E)")
        }
        ToolbarItem {
            Button("Tidy", systemImage: "sparkles") { Task { await active.prepareTidy() } }
                .disabled(!active.canTidy)
                .help("Tidy loose files into folders by kind, with a preview first (⌥⌘T)")
        }
        ToolbarItem {
            Button("Preview", systemImage: "sidebar.right") { active.showPreview.toggle() }
                .help("Show or hide the preview pane (⇧⌘P)")
        }
        ToolbarItem {
            Menu("Group By", systemImage: "rectangle.3.group") {
                Picker("Group By", selection: Bindable(active).groupBy) {
                    ForEach(GroupBy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }
            .help("Group by kind or date added; nothing moves on disk")
        }
        ToolbarItem {
            Picker("View", selection: Bindable(active).viewMode) {
                Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                Label("Cards", systemImage: "square.grid.2x2").tag(BrowserViewMode.cards)
            }
            .pickerStyle(.segmented)
        }
    }
}

extension BrowserModel {
    /// Stable identity for `ForEach`.
    var objectID: ObjectIdentifier { ObjectIdentifier(self) }
}
