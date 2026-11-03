import Foundation
import Observation

/// What a window remembers across relaunches: each pane's folder and the active pane.
nonisolated struct WindowState: Codable, Equatable, Sendable {
    var folders: [String]
    var activeIndex: Int

    init(folders: [String], activeIndex: Int) {
        self.folders = folders
        self.activeIndex = activeIndex
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
        panes = starts.map { BrowserModel(start: $0, actions: actions, defaults: defaults, workspaces: workspaces) }
        activeIndex = min(max(state?.activeIndex ?? 0, 0), panes.count - 1)
        // Errors from undo/redo work show in whichever pane is active.
        actions.onBackgroundError = { [weak self] message in self?.active.alertMessage = message }
    }

    var isSplit: Bool { panes.count == 2 }
    var active: BrowserModel { panes[activeIndex] }
    var other: BrowserModel? { isSplit ? panes[1 - activeIndex] : nil }

    var state: WindowState {
        WindowState(folders: panes.map(\.currentFolder.path), activeIndex: activeIndex)
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

    /// The window is closing: release anything waiting on a conflict answer.
    func windowWillClose() {
        panes.forEach { $0.windowWillClose() }
    }
}
