import AppKit
import Observation

enum BrowserViewMode: String, CaseIterable {
    case list, cards
}

enum IconSize: Int, CaseIterable {
    case small, medium, large

    var cardSide: CGFloat { [56, 88, 136][rawValue] }
    var rowIcon: CGFloat { [16, 22, 32][rawValue] }
    var bigger: IconSize? { IconSize(rawValue: rawValue + 1) }
    var smaller: IconSize? { IconSize(rawValue: rawValue - 1) }
}

/// An arrow-key step through the card grid.
enum SelectionMove {
    case left, right, up, down
}

/// Where a pane is: a folder, or a workspace gathering items from anywhere.
enum BrowserLocation: Hashable {
    case folder(URL)
    case workspace(Workspace.ID)
}

/// What the preview pane shows for the current selection.
enum PreviewSubject: Equatable {
    case currentFolder(URL, itemCount: Int)
    case workspace(name: String, itemCount: Int)
    case item(FileItem)
    case multiple(count: Int, totalBytes: Int64)
}

/// Why the current folder couldn't be listed.
struct LoadFailure: Equatable {
    let message: String
    /// Only permission errors are fixed by granting Full Disk Access.
    let needsFullDiskAccess: Bool

    init(_ error: any Error) {
        message = error.localizedDescription
        needsFullDiskAccess = Self.isPermissionError(error)
    }

    private static func isPermissionError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return true
        }
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError) ?? nsError
        return underlying.domain == NSPOSIXErrorDomain
            && (underlying.code == Int(EPERM) || underlying.code == Int(EACCES))
    }
}

/// State and behavior of one browser window.
@Observable
final class BrowserModel {
    /// Shared by every pane and by Settings ▸ General: one setting, like Finder's.
    static let showHiddenKey = "showHiddenFiles"

    private enum Key {
        static let showHidden = BrowserModel.showHiddenKey
        static let viewMode = "viewMode"
        static let iconSize = "iconSize"
        static let showPreview = "showPreview"
        static let groupBy = "groupBy"
    }

    // MARK: Location and contents

    private(set) var currentFolder: URL
    /// Shown items in display order: group by group when grouped.
    private(set) var items: [FileItem] = []
    /// The shown groups; empty when not grouping.
    private(set) var groups: [ItemGroup] = []
    private(set) var folderStats: [URL: FolderStats] = [:]
    /// Folders whose size couldn't be measured (for example, unreadable ones).
    private(set) var unmeasurableFolders: Set<URL> = []
    private(set) var availableBytes: Int64?
    private(set) var loadFailure: LoadFailure?
    private var rawItems: [FileItem] = []
    /// Folders with a measurement in flight, so overlapping refreshes don't walk them twice.
    @ObservationIgnored private var measuring: Set<URL> = []
    /// Bumped whenever a folder's size is invalidated, to recognize stale measurements.
    @ObservationIgnored private var generations: [URL: Int] = [:]
    /// Names of sub-folders that changed below their direct contents, waiting to be re-measured.
    @ObservationIgnored private var deeplyChanged: Set<String> = []
    /// When each folder may be walked again after a deep change.
    @ObservationIgnored private var pacer: DeepRefreshPacer
    /// The time source for pacing; injectable so tests don't depend on the wall clock.
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    private var backStack: [BrowserLocation] = []
    private var forwardStack: [BrowserLocation] = []
    /// The workspace shown instead of `currentFolder`, if any. `currentFolder` keeps the last
    /// folder, which is where folder-only commands (⌘L, Go menu) start from.
    private(set) var workspaceID: Workspace.ID?
    /// Workspace entries whose items are gone.
    private(set) var missingEntries: [WorkspaceEntry] = []
    @ObservationIgnored private var entryIDs: [URL: WorkspaceEntry.ID] = [:]
    /// Branch and uncommitted changes when the folder is in a git work tree.
    private(set) var gitStatus: GitStatus?
    /// Bumped per git read, so a slow, older read never overwrites a newer one.
    @ObservationIgnored private var gitGeneration = 0
    /// Something changed below the folder (a file edited, a commit made): read git again.
    @ObservationIgnored private var gitNeedsRefresh = false

    // MARK: Interaction state

    var selection: Set<URL> = [] {
        // The Markdown file being edited closes, saving its edits, when it stops being the selection.
        didSet { if let document, Set(selection.map(\.canonical)) != [document.url] { closeDocument() } }
    }
    var renamingURL: URL?
    var isEditingPath = false
    var quickLookURL: URL?
    var alertMessage: String?
    /// A name clash waiting for the user's answer (shown as a sheet).
    private(set) var pendingConflict: NameConflict?
    @ObservationIgnored private var conflictContinuation: CheckedContinuation<ConflictDecision, Never>?
    /// Set when the window closes: nobody can answer a prompt anymore.
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var selectionAnchor: URL?
    /// Bumped to ask this pane's file list to take keyboard focus (e.g. after Tab).
    var focusRequest = 0
    /// The item the last click or arrow key landed on; the grid scrolls it into view.
    private(set) var selectionCursor: URL?

    var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.name, comparator: .localizedStandard)] {
        didSet { applySort() }
    }

    // MARK: Preferences

    @ObservationIgnored private let defaults: UserDefaults
    /// Follows `showHiddenKey` when Settings or another pane changes it.
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?
    var showHidden: Bool { didSet { defaults.set(showHidden, forKey: Key.showHidden) } }
    var viewMode: BrowserViewMode { didSet { defaults.set(viewMode.rawValue, forKey: Key.viewMode) } }
    var iconSize: IconSize { didSet { defaults.set(iconSize.rawValue, forKey: Key.iconSize) } }
    var showPreview: Bool {
        didSet {
            defaults.set(showPreview, forKey: Key.showPreview)
            if !showPreview { closeDocument() }
        }
    }
    /// View-only: grouping never moves anything on disk.
    var groupBy: GroupBy {
        didSet {
            defaults.set(groupBy.rawValue, forKey: Key.groupBy)
            applySort()
        }
    }

    let actions: FileActions
    let workspaces: WorkspaceStore
    let developerTools: DeveloperTools
    /// Measures one folder; injectable so tests can control timing.
    @ObservationIgnored private let measurer: @Sendable (URL) async -> FolderStats?
    /// Opens a file in its default app; injectable so tests don't launch apps.
    @ObservationIgnored private let fileOpener: @MainActor (URL) -> Void

    init(
        start: URL,
        actions: FileActions = FileActions(),
        defaults: UserDefaults = .standard,
        workspaces: WorkspaceStore = .shared,
        showing workspace: Workspace.ID? = nil,
        developerTools: DeveloperTools = .shared,
        deepRefreshInterval: Duration = .seconds(10),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
        fileOpener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        recoveryFolder: URL = TextDocument.defaultRecoveryFolder,
        measurer: @escaping @Sendable (URL) async -> FolderStats? = { await BrowserModel.measure($0) }
    ) {
        currentFolder = start.canonical
        self.actions = actions
        self.defaults = defaults
        self.workspaces = workspaces
        self.developerTools = developerTools
        self.recoveryFolder = recoveryFolder
        // A restored workspace that no longer exists just leaves the pane on its folder.
        workspaceID = workspace.flatMap { workspaces.workspace($0) != nil ? $0 : nil }
        self.measurer = measurer
        self.fileOpener = fileOpener
        self.pacer = DeepRefreshPacer(baseInterval: deepRefreshInterval)
        self.now = now
        showHidden = defaults.bool(forKey: Key.showHidden)
        viewMode = BrowserViewMode(rawValue: defaults.string(forKey: Key.viewMode) ?? "") ?? .list
        iconSize = IconSize(rawValue: defaults.object(forKey: Key.iconSize) as? Int ?? 1) ?? .medium
        showPreview = defaults.bool(forKey: Key.showPreview)
        groupBy = GroupBy(rawValue: defaults.string(forKey: Key.groupBy) ?? "") ?? .none
        actions.onBackgroundError = { [weak self] message in self?.alertMessage = message }
        // Quitting may not close windows first: save the Markdown file being edited now.
        // No queue, so it runs before the app exits.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.closeDocument() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.followHiddenFilesSetting() }
        }
    }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    private func followHiddenFilesSetting() {
        let stored = defaults.bool(forKey: Key.showHidden)
        if showHidden != stored { showHidden = stored }
    }

    /// Where a new window starts: the home folder.
    static func defaultStartFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
    }

    // MARK: Derived values

    var isShowingWorkspace: Bool { workspaceID != nil }
    var location: BrowserLocation { workspaceID.map { .workspace($0) } ?? .folder(currentFolder) }
    var currentWorkspace: Workspace? { workspaceID.flatMap { workspaces.workspace($0) } }

    var title: String {
        if let currentWorkspace { return currentWorkspace.name }
        return FileManager.default.displayName(atPath: currentFolder.path)
    }
    /// Changing this restarts loading and watching (see `BrowserWindow`).
    var watchKey: String { "\(location)|\(showHidden)" }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { !isShowingWorkspace && currentFolder.path != "/" }
    /// A rename or path field has keyboard focus; file shortcuts must not act on the selection.
    var isTyping: Bool { renamingURL != nil || isEditingPath }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.url) } }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    var statusText: String {
        StatusText.make(itemCount: items.count, selectedCount: selection.count, availableBytes: availableBytes)
    }

    var previewSubject: PreviewSubject {
        let selected = selectedItems
        switch selected.count {
        case 0:
            if let currentWorkspace { return .workspace(name: currentWorkspace.name, itemCount: items.count) }
            return .currentFolder(currentFolder, itemCount: items.count)
        case 1:
            return .item(selected[0])
        default:
            let total = selected.reduce(Int64(0)) { sum, item in
                sum + (item.isDirectory ? folderStats[item.url]?.totalBytes ?? 0 : item.size ?? 0)
            }
            return .multiple(count: selected.count, totalBytes: total)
        }
    }

    func sizeText(for item: FileItem) -> String {
        if item.isDirectory {
            return folderStats[item.url].map { StatusText.formatBytes($0.totalBytes) } ?? "--"
        }
        return StatusText.formatBytes(item.size ?? 0)
    }

    func cardSubtitle(for item: FileItem) -> String {
        guard item.isNavigable else { return sizeText(for: item) }
        if unmeasurableFolders.contains(item.url) { return "--" }
        guard let stats = folderStats[item.url] else { return "Calculating…" }
        let count = stats.itemCount == 1 ? "1 item" : "\(stats.itemCount) items"
        return "\(StatusText.formatBytes(stats.totalBytes)) · \(count)"
    }

    // MARK: Navigation

    func navigate(to folder: URL) {
        let target = folder.canonical
        guard target != currentFolder || isShowingWorkspace else { return }
        backStack.append(location)
        forwardStack.removeAll()
        show(.folder(target))
    }

    /// Shows a workspace in this pane (⌃1–⌃9, or its sidebar row).
    func openWorkspace(_ id: Workspace.ID) async {
        guard workspaces.workspace(id) != nil, workspaceID != id else { return }
        backStack.append(location)
        forwardStack.removeAll()
        show(.workspace(id))
        await reload()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        show(next)
    }

    func goUp() {
        guard canGoUp else { return }
        let child = currentFolder
        navigate(to: currentFolder.deletingLastPathComponent())
        selection = [child]
    }

    private func show(_ location: BrowserLocation) {
        switch location {
        case .folder(let folder):
            currentFolder = folder
            workspaceID = nil
        case .workspace(let id):
            workspaceID = id
        }
        missingEntries = []
        entryIDs = [:]
        tidyPreview = nil
        gitStatus = nil
        gitGeneration += 1
        gitNeedsRefresh = false
        selection = []
        renamingURL = nil
        quickLookURL = nil
        selectionCursor = nil
        selectionAnchor = nil
        folderStats = [:]
        unmeasurableFolders = []
        measuring = []
        generations = [:]
        deeplyChanged = []
        pacer.reset()
        items = []
        rawItems = []
        loadFailure = nil
    }

    /// Opens files with their default app; navigates into the first folder of the selection.
    func open(_ urls: some Collection<URL>) {
        let targets = items.filter { urls.contains($0.url) }
        for file in targets where !file.isNavigable {
            fileOpener(file.url)
        }
        if let folder = targets.first(where: \.isNavigable) {
            navigate(to: folder.url)
        }
    }

    func openSelection() { open(selection) }

    /// Navigates into the selection when it is exactly one folder. Returns whether it did.
    @discardableResult
    func enterSelectedFolder() -> Bool {
        guard selection.count == 1,
              let folder = items.first(where: { $0.url == selection.first && $0.isNavigable })
        else { return false }
        navigate(to: folder.url)
        return true
    }

    /// Return on one selected item: enters a folder, or opens a file in its default app.
    /// Returns whether it did anything.
    @discardableResult
    func openSelectedItem() -> Bool {
        guard selection.count == 1 else { return false }
        if enterSelectedFolder() { return true }
        guard let file = items.first(where: { $0.url == selection.first }) else { return false }
        fileOpener(file.url)
        return true
    }

    /// Opens the folder an item really lives in, with the item selected.
    func showInEnclosingFolder(_ item: FileItem) {
        reveal(item.url)
    }

    /// Opens the folder `url` is in, with it selected.
    func reveal(_ url: URL) {
        navigate(to: url.deletingLastPathComponent())
        selection = [url.canonical]
    }

    /// Opens a file in its default app.
    func openFile(_ url: URL) {
        fileOpener(url)
    }

    // MARK: Markdown editing

    /// The Markdown file the preview pane edits; `nil` when it shows something else.
    private(set) var document: TextDocument?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?
    /// Where unsaved edits go when they can't be written next to their file.
    @ObservationIgnored private let recoveryFolder: URL

    /// Opens a Markdown file for editing in the preview pane, saving the one open before.
    /// A file that can't be read for editing (too big, not UTF-8) just isn't opened.
    func openDocument(_ url: URL) {
        guard document?.url != url.canonical, closeDocument() else { return }
        document = try? TextDocument(url: url, recoveryFolder: recoveryFolder)
    }

    /// Closes the open Markdown file, saving its edits. Edits are never dropped: when the file
    /// changed on disk (or was moved away) they go to a copy next to it, and when nothing can be
    /// written the file stays open with its edits. Returns whether it closed.
    @discardableResult
    func closeDocument() -> Bool {
        guard let document else { return true }
        if document.isDirty, !document.save() {
            let name = "\u{201C}\(document.url.lastPathComponent)\u{201D}"
            if let copy = document.saveRecoveryCopy() {
                let place = copy.deletingLastPathComponent() == document.url.deletingLastPathComponent()
                    ? "next to it" : "in \(copy.deletingLastPathComponent().path)"
                alertMessage = "\(name) couldn't be saved (it changed on disk, was moved, or can't be written), "
                    + "so your edits were saved \(place) as \u{201C}\(copy.lastPathComponent)\u{201D}."
            } else {
                alertMessage = "Your changes to \(name) couldn't be saved: \(document.errorMessage ?? "the file changed on disk")."
                    + " They're kept until you select it again."
                return false
            }
        }
        self.document = nil
        return true
    }

    /// Saves the open Markdown file first when an operation is about to rename, move, copy or
    /// trash it, so the edits travel with it.
    func saveDocument(before urls: some Collection<URL>) {
        guard let document, document.isDirty, urls.contains(where: { $0.canonical == document.url }) else { return }
        document.save()
    }

    /// ⌘S: saves the open Markdown file. A conflict shows in the preview pane.
    func saveDocument() {
        document?.save()
    }

    // MARK: Loading

    /// Loads the folder, measures sub-folders and keeps refreshing while the folder changes.
    func run() async {
        // A workspace has no folder to watch; the pane reloads it when its entries change.
        if isShowingWorkspace {
            await reload()
            await measureFolders()
            return
        }
        let folder = currentFolder
        // Start watching before the first listing so changes made meanwhile are not missed.
        let changes = DirectoryWatcher.changes(of: folder)
        // Watching the whole disk from "/" would only re-walk system folders; skip it there.
        let deepChanges = folder.path == "/" ? nil : SubtreeWatcher.changes(of: folder)
        await reload()
        await withTaskGroup(of: Void.self) { group in
            // Measuring can take minutes in big trees; it must not block refreshes.
            group.addTask { await self.measureFolders() }
            if let deepChanges {
                // Collecting is cheap and keeps up with FSEvents; refreshing is batched separately.
                group.addTask {
                    for await paths in deepChanges { await self.noteDeepChanges(paths, in: folder) }
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        await self.refreshDeeplyChangedFolders(in: folder)
                        if self.gitNeedsRefresh, folder == self.currentFolder { await self.refreshGitStatus() }
                    }
                }
            }
            for await _ in changes {
                await reload()
                group.addTask { await self.measureFolders() }
            }
            // Watching ended. If the folder is gone, its measurements are moot: stop them now
            // instead of waiting for long walks. Otherwise (watching just isn't possible here)
            // keep measuring until `run()` is cancelled.
            if !FileManager.default.fileExists(atPath: folder.path) { group.cancelAll() }
        }
        // The stream ends when the folder is deleted or renamed: step out of it.
        if !Task.isCancelled, folder == currentFolder, !FileManager.default.fileExists(atPath: folder.path) {
            goUp()
        }
    }

    func reload() async {
        if let workspaceID {
            reloadWorkspace(workspaceID)
            return
        }
        let folder = currentFolder
        let hidden = showHidden
        do {
            let listing = try await Self.list(folder, showHidden: hidden)
            guard folder == currentFolder, hidden == showHidden else { return }
            invalidateChangedFolders(previous: rawItems, current: listing)
            rawItems = listing
            loadFailure = nil
            applySort()
            selection.formIntersection(listing.map(\.url))
            availableBytes = await Self.freeSpace(at: folder)
            await refreshGitStatus()
        } catch {
            guard folder == currentFolder, hidden == showHidden else { return }
            rawItems = []
            items = []
            loadFailure = LoadFailure(error)
        }
    }

    /// Lists a workspace: items found where their bookmarks point, the rest as missing.
    private func reloadWorkspace(_ id: Workspace.ID) {
        guard let workspace = workspaces.workspace(id) else {
            // The workspace was deleted while open: go back to this pane's folder.
            show(.folder(currentFolder))
            Task { await reload() }
            return
        }
        var listing: [FileItem] = []
        var missing: [WorkspaceEntry] = []
        var ids: [URL: WorkspaceEntry.ID] = [:]
        for entry in workspace.entries {
            if let url = workspaces.resolve(entry), let item = DirectoryLister.item(at: url) {
                listing.append(item)
                ids[item.url] = entry.id
            } else {
                missing.append(entry)
            }
        }
        invalidateChangedFolders(previous: rawItems, current: listing)
        rawItems = listing
        entryIDs = ids
        missingEntries = missing
        loadFailure = nil
        availableBytes = nil
        applySort()
        selection.formIntersection(listing.map(\.url))
    }

    /// Adds items to a workspace. Nothing is copied or moved.
    func addToWorkspace(_ urls: [URL], _ id: Workspace.ID) async {
        workspaces.add(urls, to: id)
        if workspaceID == id { await reload() }
    }

    /// Takes the selected items out of the shown workspace; the items themselves stay put.
    func removeSelectionFromWorkspace() async {
        guard isShowingWorkspace else { return }
        removeFromWorkspace(Set(selectedURLs.compactMap { entryIDs[$0] }))
        await reload()
    }

    func removeFromWorkspace(_ entries: Set<WorkspaceEntry.ID>) {
        guard let workspaceID, !entries.isEmpty else { return }
        workspaces.remove(entries, from: workspaceID)
    }

    /// Drops cached sizes of sub-folders that disappeared or whose contents changed (a folder's
    /// modification date changes when entries are added, removed or renamed directly inside it).
    private func invalidateChangedFolders(previous: [FileItem], current: [FileItem]) {
        let currentDates = Dictionary(current.map { ($0.url, $0.modificationDate) }, uniquingKeysWith: { a, _ in a })
        for old in previous where old.isDirectory && currentDates[old.url] != .some(old.modificationDate) {
            invalidate(old.url)
        }
    }

    /// Forgets a folder's size. A measurement already running for it will be discarded.
    private func invalidate(_ url: URL) {
        folderStats[url] = nil
        unmeasurableFolders.remove(url)
        generations[url, default: 0] += 1
    }

    /// Records sub-folders that changed somewhere below their direct contents.
    func noteDeepChanges(_ paths: [String], in folder: URL) {
        guard folder == currentFolder else { return }
        deeplyChanged.formUnion(SubtreeWatcher.changedChildren(paths: paths, in: folder))
        if gitStatus != nil { gitNeedsRefresh = true }
    }

    /// Reads the branch and change count again. Read-only (see `GitStatusReader`).
    func refreshGitStatus() async {
        gitGeneration += 1
        let generation = gitGeneration
        gitNeedsRefresh = false
        guard !isShowingWorkspace else {
            gitStatus = nil
            return
        }
        let folder = currentFolder
        let status = await Self.readGitStatus(folder)
        guard generation == gitGeneration, folder == currentFolder, !isShowingWorkspace else { return }
        gitStatus = status
    }

    @concurrent private nonisolated static func readGitStatus(_ folder: URL) async -> GitStatus? {
        GitStatusReader.status(of: folder, git: GitStatusReader.gitExecutable())
    }

    /// Re-measures deeply changed sub-folders, all pending changes at once, each folder only when
    /// `pacer` says its pause is over, keeping its previous size on screen meanwhile. Busy trees
    /// such as ~/Library change constantly; this keeps them from being re-walked non-stop.
    func refreshDeeplyChangedFolders(in folder: URL) async {
        guard folder == currentFolder, !deeplyChanged.isEmpty else { return }
        deeplyChanged.formIntersection(rawItems.map(\.name))
        let now = now()
        var due: Set<URL> = []
        for item in rawItems where item.isDirectory && deeplyChanged.contains(item.name) {
            // Still being walked, or walked recently: stay pending for a later round.
            if measuring.contains(item.url) || !pacer.isDue(item.url, at: now) { continue }
            deeplyChanged.remove(item.name)
            due.insert(item.url)
        }
        if !due.isEmpty { await measureFolders(refreshing: due) }
    }

    /// Measures every sub-folder without a size. Folders invalidated while being measured are
    /// measured again (a few rounds at most), so none is left on "Calculating…".
    func measureFolders(refreshing initial: Set<URL> = []) async {
        var refreshing = initial
        for _ in 0..<3 {
            let remeasure = await measurePass(refreshing: refreshing)
            guard !remeasure.isEmpty, !Task.isCancelled else { return }
            refreshing = Set(remeasure)
        }
    }

    /// One round of measuring: folders without a size, plus `refreshing` ones, which keep
    /// showing their previous size meanwhile. Returns folders that need another round.
    private func measurePass(refreshing: Set<URL>) async -> [URL] {
        let pending = rawItems
            .filter {
                guard $0.isDirectory, !measuring.contains($0.url) else { return false }
                // A refresh retries folders that failed before: the failure may have been transient.
                if refreshing.contains($0.url) { return true }
                return folderStats[$0.url] == nil && !unmeasurableFolders.contains($0.url)
            }
            .map(\.url)
        let generationAtStart = Dictionary(pending.map { ($0, generations[$0, default: 0]) }, uniquingKeysWith: { a, _ in a })
        measuring.formUnion(pending)
        defer { measuring.subtract(pending) }

        var remeasure: [URL] = []
        var startedAt: [URL: ContinuousClock.Instant] = [:]
        var queue = pending.makeIterator()
        await withTaskGroup(of: (URL, FolderStats?).self) { group in
            for _ in 0..<4 {
                guard let url = queue.next() else { break }
                startedAt[url] = now()
                group.addTask { [measurer] in (url, await measurer(url)) }
            }
            for await (url, stats) in group {
                if Task.isCancelled { group.cancelAll(); break }
                let stillListed = rawItems.contains { $0.url == url }
                // The pause before a deep refresh counts from the end of the last walk and grows
                // with its duration, so long walks aren't followed straight away by another one.
                let ended = now()
                pacer.recordWalk(of: url, started: startedAt[url] ?? ended, ended: ended)
                if stillListed, generations[url, default: 0] == generationAtStart[url] {
                    if let stats {
                        folderStats[url] = stats
                        unmeasurableFolders.remove(url)
                    } else {
                        folderStats[url] = nil
                        unmeasurableFolders.insert(url)
                    }
                } else if stillListed {
                    remeasure.append(url)  // invalidated mid-walk: the result is stale
                }
                if let next = queue.next() {
                    startedAt[next] = now()
                    group.addTask { [measurer] in (next, await measurer(next)) }
                }
            }
        }
        return remeasure
    }

    /// Sorts the listing, then groups it; `items` follows the shown order so ⇧-ranges and
    /// arrow keys match the screen.
    private func applySort() {
        let sorted: [FileItem]
        if let first = sortOrder.first, first.keyPath == \FileItem.name {
            sorted = rawItems.sorted(using: FinderOrder(order: first.order))
        } else {
            sorted = rawItems.sorted(using: sortOrder)
        }
        groups = ItemGrouping.groups(sorted, by: groupBy)
        items = groups.isEmpty ? sorted : groups.flatMap(\.items)
    }

    @concurrent private nonisolated static func list(_ folder: URL, showHidden: Bool) async throws -> [FileItem] {
        try DirectoryLister.contents(of: folder, showHidden: showHidden)
    }

    @concurrent nonisolated static func measure(_ folder: URL) async -> FolderStats? {
        try? FolderSizeCalculator.measure(folder)
    }

    @concurrent private nonisolated static func freeSpace(at folder: URL) async -> Int64? {
        StatusText.availableBytes(at: folder)
    }

    // MARK: Selection

    /// Card-view click handling: ⌘ toggles, ⇧ extends from the last clicked item.
    func click(_ item: FileItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
        } else if modifiers.contains(.shift),
                  let anchor = selectionAnchor,
                  let from = items.firstIndex(where: { $0.url == anchor }),
                  let to = items.firstIndex(where: { $0.url == item.url }) {
            selection = Set(items[min(from, to)...max(from, to)].map(\.url))
            return
        } else {
            selection = [item.url]
        }
        selectionAnchor = item.url
        selectionCursor = item.url
    }

    /// Card-view arrow keys: ←/→ step one item (wrapping across rows), ↑/↓ one row of `columns`.
    /// Stops at the edges. `extending` (⇧) selects the range from where the selection started.
    /// When grouped, each group starts a new row; ↑/↓ into another group lands on the nearest
    /// card of its row, while inside a group a row with no card below doesn't move.
    func moveSelection(_ move: SelectionMove, columns: Int, extending: Bool) {
        guard !items.isEmpty else { return }
        let urls = items.map(\.url)
        let current = selectionCursor.flatMap { selection.contains($0) ? urls.firstIndex(of: $0) : nil }
            ?? urls.firstIndex(where: selection.contains)

        let target: Int
        if let index = current {
            switch move {
            case .left: target = max(0, index - 1)
            case .right: target = min(urls.count - 1, index + 1)
            case .up, .down: target = verticalTarget(from: index, up: move == .up, columns: max(1, columns))
            }
        } else {
            target = (move == .right || move == .down) ? 0 : urls.count - 1
        }

        let targetURL = urls[target]
        if extending, let anchor = selectionAnchor, let anchorIndex = urls.firstIndex(of: anchor) {
            selection = Set(urls[min(anchorIndex, target)...max(anchorIndex, target)])
        } else {
            selection = [targetURL]
            selectionAnchor = targetURL
        }
        selectionCursor = targetURL
    }

    /// The index one row above or below `index` in the card grid, or `index` when there is none.
    private func verticalTarget(from index: Int, up: Bool, columns: Int) -> Int {
        // Rows as the grid lays them out: (group number, first index, card count).
        var rows: [(group: Int, start: Int, count: Int)] = []
        let sizes = groups.isEmpty ? [items.count] : groups.map(\.items.count)
        var start = 0
        for (group, size) in sizes.enumerated() {
            for offset in stride(from: 0, to: size, by: columns) {
                rows.append((group, start + offset, min(columns, size - offset)))
            }
            start += size
        }
        guard let row = rows.firstIndex(where: { index >= $0.start && index < $0.start + $0.count }) else { return index }
        let next = up ? row - 1 : row + 1
        guard rows.indices.contains(next) else { return index }
        let column = index - rows[row].start
        if column < rows[next].count { return rows[next].start + column }
        // Short row: crossing into another group clamps to its last card; inside one, stay.
        return rows[next].group != rows[row].group ? rows[next].start + rows[next].count - 1 : index
    }

    func selectAll() { selection = Set(items.map(\.url)) }

    // MARK: Quick Look and rename

    func toggleQuickLook() {
        quickLookURL = quickLookURL == nil ? selectedURLs.first : nil
    }

    func beginRename() {
        guard selection.count == 1 else { return }
        renamingURL = selection.first
    }

    func commitRename(_ item: FileItem, to newName: String) async {
        guard renamingURL == item.url else { return }
        renamingURL = nil
        saveDocument(before: [item.url])
        do {
            let renamed = try await actions.rename(item.url, to: newName)
            selection = [renamed.canonical]
        } catch {
            alertMessage = error.localizedDescription
        }
        await reload()
    }

    /// Escape in the rename field: keeps the name and hands the keyboard back to the file list.
    func cancelRename() {
        renamingURL = nil
        focusRequest += 1
    }

    /// Escape in the path bar: closes it and hands the keyboard back to the file list.
    func cancelPathEditing() {
        isEditingPath = false
        focusRequest += 1
    }

    // MARK: File operations

    func copySelection() { actions.copyToClipboard(selectedURLs) }
    func cutSelection() { actions.cutToClipboard(selectedURLs) }

    func paste(forceMove: Bool = false) async {
        guard !isShowingWorkspace else { return }   // a workspace isn't a folder to paste into
        let folder = currentFolder
        await perform {
            let pasted = try await actions.paste(
                into: folder, forceMove: forceMove, resolveConflicts: conflictResolver)
            if !pasted.isEmpty, folder == currentFolder { selection = Set(pasted.map(\.canonical)) }
        }
    }

    /// Creates an untitled folder here, selects it and starts renaming it.
    func newFolder() async {
        await createAndRename { try await $0.createFolder(in: $1) }
    }

    /// Compress: zips the selection into this folder and selects the archive.
    func compressSelection() async {
        guard !isShowingWorkspace else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        saveDocument(before: urls)
        let folder = currentFolder
        do {
            let archive = try await actions.compress(urls, in: folder)
            await reload()
            if folder == currentFolder { selection = [archive.canonical] }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Creates an empty new.md here, selects it and starts renaming it.
    func newMarkdownFile() async {
        await createAndRename { try await $0.createMarkdownFile(in: $1) }
    }

    /// Creates an empty new.txt here, selects it and starts renaming it.
    func newTextFile() async {
        await createAndRename { try await $0.createTextFile(in: $1) }
    }

    private func createAndRename(_ create: (FileActions, URL) async throws -> URL) async {
        guard !isShowingWorkspace else { return }
        let folder = currentFolder
        do {
            let created = try await create(actions, folder).canonical
            await reload()
            guard folder == currentFolder else { return }
            selection = [created]
            renamingURL = created
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Terminal and editor

    /// The folder ⌥⇧⌘T / ⌥⇧⌘E open: the one shown, or in a workspace the single selected folder.
    var developerFolder: URL? {
        guard isShowingWorkspace else { return currentFolder }
        let selected = selectedItems
        return selected.count == 1 && selected[0].isNavigable ? selected[0].url : nil
    }

    /// Set by the window: opens its Ghostty terminal panel in a folder.
    @ObservationIgnored var onOpenTerminal: ((URL) -> Void)?

    func openInTerminal(_ folder: URL? = nil) {
        guard let folder = folder ?? developerFolder else { return }
        onOpenTerminal?(folder)
    }
    /// Opens the folder in the terminal app picked in Settings, outside FileFinder.
    func openInExternalTerminal(_ folder: URL? = nil) { openDeveloperApp(.terminal, folder) }
    func openInEditor(_ folder: URL? = nil) { openDeveloperApp(.editor, folder) }

    /// What Return does in the path bar: go to a typed folder, or run a command such as
    /// `code .` (a folder with a command's name wins). Returns false when the text is neither.
    func submitPath(_ text: String) -> Bool {
        if let folder = PathInput.resolve(text, relativeTo: currentFolder) {
            isEditingPath = false
            navigate(to: folder)
            return true
        }
        guard let base = developerFolder,
              let command = PathBarCommand.parse(text, relativeTo: base) else { return false }
        // A pane outside a window has no terminal panel: `terminal` is then not a command.
        if command.target == .terminalPanel, onOpenTerminal == nil { return false }
        isEditingPath = false
        do {
            switch command.target {
            case .terminalPanel:
                onOpenTerminal?(command.folder)
            case .app(let id):
                guard let app = (DeveloperApp.editors + DeveloperApp.terminals).first(where: { $0.id == id }) else { return false }
                try developerTools.open(command.folder, in: app)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
        return true
    }

    private func openDeveloperApp(_ role: DeveloperApp.Role, _ folder: URL?) {
        guard let folder = folder ?? developerFolder else { return }
        do {
            try developerTools.openInPreferred(folder, role: role)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Tidy

    /// A tidy plan waiting for the user's go-ahead (shown as a sheet). Nothing moves before then.
    private(set) var tidyPreview: TidyPlan?
    /// A workspace isn't a folder: there is nothing loose to tidy.
    var canTidy: Bool { !isShowingWorkspace }

    /// Works out what tidying the current folder would do and shows it (⌥⌘T).
    func prepareTidy() async {
        guard canTidy else { return }
        let folder = currentFolder
        do {
            let plan = try await Self.makeTidyPlan(for: folder)
            guard folder == currentFolder, canTidy else { return }
            tidyPreview = plan
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Opens Downloads and shows its tidy plan.
    func tidyDownloads(home: URL = FileManager.default.homeDirectoryForCurrentUser) async {
        navigate(to: home.appending(path: "Downloads"))
        await prepareTidy()
    }

    /// Carries out the previewed plan, then selects the kind folders.
    func confirmTidy() async {
        guard let plan = tidyPreview else { return }
        tidyPreview = nil
        await perform {
            try await actions.tidy(plan)
            if plan.folder == currentFolder, !isShowingWorkspace { selection = Set(plan.groups.map(\.folder)) }
        }
    }

    func cancelTidy() { tidyPreview = nil }

    @concurrent private nonisolated static func makeTidyPlan(for folder: URL) async throws -> TidyPlan {
        try TidyPlan.make(for: folder)
    }

    // MARK: Drag and drop

    /// The drag this app started last: the item grabbed and everything it carries.
    private static var dragSession: (id: String, lead: URL, items: [URL])?
    /// Private pasteboard type that marks a drag as ours, carrying its session id.
    static let dragMarkerType = "com.juancasanueva.FileFinder.drag-session"
    /// The pasteboard drags travel on (swappable in tests).
    static var dragPasteboard = NSPasteboard(name: .drag)
    static var currentDragID: String? { dragSession?.id }

    /// Starts dragging `item`: the whole selection when the item is part of it. The pasteboard
    /// carries the grabbed item's file URL, so Finder and other apps accept the drag too, plus a
    /// private marker so a drop can tell this drag from a later one of the same file.
    func beginDrag(_ item: FileItem) -> NSItemProvider {
        let items = selection.contains(item.url) ? selectedURLs : [item.url]
        let id = UUID().uuidString
        Self.dragSession = (id, item.url, items)
        let provider = NSItemProvider(object: item.url as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: Self.dragMarkerType, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil)
            return nil
        }
        return provider
    }

    /// The drag session behind a drop, if the drop really is that drag (its marker is on the
    /// drag pasteboard). A drag that ended elsewhere never matches a later drop.
    private static func session(for dropped: [URL]) -> [URL]? {
        guard let session = dragSession,
              dropped.contains(session.lead.canonical),
              dragPasteboard.string(forType: .init(dragMarkerType)) == session.id else { return nil }
        return session.items
    }

    /// The items a drop really carries: the whole dragged selection when it's our drag.
    static func draggedItems(for urls: [URL]) -> [URL] {
        let items = session(for: urls.map(\.canonical)) ?? urls
        endDrag()
        return items
    }

    /// What the views call on a drop: onto a folder goes into it, onto anything else into the
    /// current folder; ⌥ held copies.
    func handleDrop(_ urls: [URL], onto item: FileItem?) {
        let folderTarget = item.flatMap { $0.isNavigable ? $0.url : nil }
        // Dropped onto the workspace itself (not onto one of its folders): just add the items.
        if folderTarget == nil, let workspaceID {
            let items = Self.draggedItems(for: urls)
            Task { await addToWorkspace(items, workspaceID) }
            return
        }
        let target = folderTarget ?? currentFolder
        let copying = NSEvent.modifierFlags.contains(.option)
        Task { await drop(urls, into: target, copying: copying) }
    }

    static func endDrag() { dragSession = nil }

    /// Drops items into `folder`: moves them, or copies them when `copying` (⌥ held).
    /// Returns false when there was nothing to do.
    @discardableResult
    func drop(_ urls: [URL], into folder: URL, copying: Bool) async -> Bool {
        let dropped = urls.map(\.canonical)
        var items = Self.session(for: dropped) ?? dropped
        Self.endDrag()
        let target = folder.canonical
        items = items.filter { $0 != target }   // a folder dropped onto itself
        guard !items.isEmpty else { return false }
        await perform {
            let results = copying
                ? try await actions.copy(items, into: target, resolveConflicts: conflictResolver)
                : try await actions.move(items, into: target, resolveConflicts: conflictResolver)
            if target == currentFolder, !results.isEmpty { selection = Set(results.map(\.canonical)) }
        }
        return true
    }

    // MARK: Name conflicts

    /// Asks the user through `pendingConflict`; operations wait until `answerConflict`.
    var conflictResolver: ConflictResolver {
        { [weak self] conflict in
            guard let self else { return .skipAll }
            return await self.ask(about: conflict)
        }
    }

    private func ask(about conflict: NameConflict) async -> ConflictDecision {
        // After the window closed, operations still queued must not wait for an answer.
        if isClosed { return .skipAll }
        // Only one question at a time; operations are serialized, so this is just a safeguard.
        if let previous = conflictContinuation {
            previous.resume(returning: .skipAll)
        }
        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
            pendingConflict = conflict
        }
    }

    /// The window is going away: release any operation waiting on a conflict answer, so the
    /// shared queue isn't blocked forever.
    func windowWillClose() {
        closeDocument()
        isClosed = true
        if pendingConflict != nil {
            answerConflict(.skipAll)
        }
    }

    func answerConflict(_ decision: ConflictDecision) {
        pendingConflict = nil
        let continuation = conflictContinuation
        conflictContinuation = nil
        continuation?.resume(returning: decision)
    }

    /// ⌘⌫. In a workspace this only removes the entries: nothing is ever trashed there.
    func trashSelection() async {
        if isShowingWorkspace { return await removeSelectionFromWorkspace() }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        saveDocument(before: urls)
        await perform { try await actions.trash(urls) }
    }

    /// Runs a file operation, surfaces errors, and refreshes right away instead of waiting
    /// for the watcher.
    private func perform(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch is CancellationError {
            // The user pressed Cancel; nothing to report.
        } catch {
            alertMessage = error.localizedDescription
        }
        await reload()
    }
}
