import Foundation
import Observation

/// What a window remembers across relaunches: each pane's folder and the active pane.
nonisolated struct WindowState: Codable, Equatable, Sendable {
    var folders: [String]
    var activeIndex: Int
    /// Per pane, the workspace it shows (by id), if any. Missing in state saved by older builds.
    var workspaces: [String?]

    init(folders: [String], activeIndex: Int, workspaces: [String?]? = nil) {
        self.folders = folders
        self.activeIndex = activeIndex
        self.workspaces = workspaces ?? folders.map { _ in nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let folders = try container.decode([String].self, forKey: .folders)
        self.init(
            folders: folders,
            activeIndex: try container.decode(Int.self, forKey: .activeIndex),
            workspaces: try container.decodeIfPresent([String?].self, forKey: .workspaces))
    }

    init(encoded: String) throws {
        self = try JSONDecoder().decode(WindowState.self, from: Data(encoded.utf8))
    }

    var encoded: String {
        (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? ""
    }
}

/// One window: one pane, or two side by side (⌘D). Both panes share one `FileActions`, so
/// all their file operations run on one queue and undo as one history.
@Observable
final class BrowserWindowModel {
    let actions: FileActions
    private(set) var panes: [BrowserModel]
    private(set) var activeIndex = 0
    @ObservationIgnored private let defaults: UserDefaults
    let workspaces: WorkspaceStore

    init(
        restoring state: WindowState? = nil,
        defaultStart: URL = BrowserModel.defaultStartFolder(),
        actions: FileActions = FileActions(),
        defaults: UserDefaults = .standard,
        workspaces: WorkspaceStore = .shared
    ) {
        self.actions = actions
        self.defaults = defaults
        self.workspaces = workspaces
        let folders = (state?.folders ?? []).prefix(2).map { path -> URL in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? URL(filePath: path) : defaultStart
        }
        let starts = folders.isEmpty ? [defaultStart] : folders
        let savedWorkspaces = state?.workspaces ?? []
        panes = starts.enumerated().map { index, start in
            let id = index < savedWorkspaces.count ? savedWorkspaces[index].flatMap(UUID.init(uuidString:)) : nil
            return BrowserModel(
                start: start, actions: actions, defaults: defaults, workspaces: workspaces, showing: id)
        }
        activeIndex = min(max(state?.activeIndex ?? 0, 0), panes.count - 1)
        // Errors from undo/redo work show in whichever pane is active.
        actions.onBackgroundError = { [weak self] message in self?.active.alertMessage = message }
    }

    var isSplit: Bool { panes.count == 2 }
    var active: BrowserModel { panes[activeIndex] }
    var other: BrowserModel? { isSplit ? panes[1 - activeIndex] : nil }

    var state: WindowState {
        WindowState(
            folders: panes.map(\.currentFolder.path), activeIndex: activeIndex,
            workspaces: panes.map { $0.workspaceID?.uuidString })
    }

    // MARK: Layout

    /// Splits into two panes on the active folder, or closes the inactive pane.
    func toggleSplit() {
        if isSplit {
            // The closing pane may be waiting on a conflict answer; release it.
            other?.windowWillClose()
            panes = [active]
            activeIndex = 0
        } else {
            panes.append(BrowserModel(
                start: active.currentFolder, actions: actions, defaults: defaults, workspaces: workspaces))
        }
    }

    func switchPane() {
        guard isSplit else { return }
        activeIndex = 1 - activeIndex
        active.focusRequest += 1
    }

    /// Swaps the panes' sides; the active pane stays active.
    func swapPanes() {
        guard isSplit else { return }
        panes.swapAt(0, 1)
        activeIndex = 1 - activeIndex
    }

    func activate(_ pane: BrowserModel) {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return }
        activeIndex = index
    }

    // MARK: Transfers between panes

    /// F5: copies the active pane's selection into the other pane's folder.
    func copyToOtherPane() async {
        await transferToOtherPane(copying: true)
    }

    /// F6: moves the active pane's selection into the other pane's folder.
    func moveToOtherPane() async {
        await transferToOtherPane(copying: false)
    }

    private func transferToOtherPane(copying: Bool) async {
        guard let target = other else { return }
        let source = active
        let urls = source.selectedURLs
        guard !urls.isEmpty else { return }
        // Into a workspace, F5 and F6 both just add the items: nothing is copied or moved.
        if let workspaceID = target.workspaceID {
            await target.addToWorkspace(urls, workspaceID)
            return
        }
        let folder = target.currentFolder
        do {
            let results = copying
                ? try await actions.copy(urls, into: folder, resolveConflicts: source.conflictResolver)
                : try await actions.move(urls, into: folder, resolveConflicts: source.conflictResolver)
            if target.currentFolder == folder { target.selection = Set(results.map(\.canonical)) }
        } catch is CancellationError {
            // Cancelled from the progress bar.
        } catch {
            source.alertMessage = error.localizedDescription
        }
        // Both panes changed: one lost items (on a move), the other gained them.
        await source.reload()
        await target.reload()
    }

    // MARK: Workspaces

    /// The workspace name sheet: creating a new workspace, or renaming one.
    enum NamingRequest: Hashable, Identifiable {
        case create
        case rename(Workspace.ID)
        var id: Self { self }
    }

    private(set) var namingRequest: NamingRequest?

    /// ⌥⌘N.
    func requestNewWorkspace() { namingRequest = .create }
    func requestRename(_ id: Workspace.ID) { namingRequest = .rename(id) }
    func cancelNaming() { namingRequest = nil }

    func currentName(for request: NamingRequest) -> String {
        switch request {
        case .create: ""
        case .rename(let id): workspaces.workspace(id)?.name ?? ""
        }
    }

    /// Applies the name from the sheet: creates and opens a new workspace, or renames one.
    func finishNaming(_ name: String) async {
        guard let request = namingRequest else { return }
        namingRequest = nil
        switch request {
        case .create:
            let workspace = workspaces.create(named: name)
            await active.openWorkspace(workspace.id)
        case .rename(let id):
            workspaces.rename(id, to: name)
        }
    }

    /// ⌃1–⌃9: the workspace at that position in the sidebar.
    func openWorkspace(number: Int) async {
        let list = workspaces.workspaces
        guard number >= 1, number <= list.count else { return }
        await active.openWorkspace(list[number - 1].id)
    }

    /// Deletes the workspace (never its items); panes showing it go back to their folders.
    func deleteWorkspace(_ id: Workspace.ID) async {
        workspaces.delete(id)
        for pane in panes where pane.workspaceID == id {
            await pane.reload()
        }
    }

    /// The window is closing: release anything waiting on a conflict answer.
    func windowWillClose() {
        panes.forEach { $0.windowWillClose() }
    }
}
