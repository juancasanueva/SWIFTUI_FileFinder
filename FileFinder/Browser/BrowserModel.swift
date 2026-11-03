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
    private enum Key {
        static let showHidden = "showHiddenFiles"
        static let viewMode = "viewMode"
        static let iconSize = "iconSize"
    }

    // MARK: Location and contents

    private(set) var currentFolder: URL
    private(set) var items: [FileItem] = []
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
    /// Folders that changed deep inside while being measured; measured again afterwards.
    @ObservationIgnored private var changedWhileMeasuring: Set<URL> = []
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    // MARK: Interaction state

    var selection: Set<URL> = []
    var renamingURL: URL?
    var isEditingPath = false
    var quickLookURL: URL?
    var alertMessage: String?
    @ObservationIgnored private var selectionAnchor: URL?

    var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\.name, comparator: .localizedStandard)] {
        didSet { applySort() }
    }

    // MARK: Preferences

    @ObservationIgnored private let defaults: UserDefaults
    var showHidden: Bool { didSet { defaults.set(showHidden, forKey: Key.showHidden) } }
    var viewMode: BrowserViewMode { didSet { defaults.set(viewMode.rawValue, forKey: Key.viewMode) } }
    var iconSize: IconSize { didSet { defaults.set(iconSize.rawValue, forKey: Key.iconSize) } }

    let actions: FileActions
    /// Measures one folder; injectable so tests can control timing.
    @ObservationIgnored private let measurer: @Sendable (URL) async -> FolderStats?

    init(
        start: URL,
        actions: FileActions = FileActions(),
        defaults: UserDefaults = .standard,
        measurer: @escaping @Sendable (URL) async -> FolderStats? = { await BrowserModel.measure($0) }
    ) {
        currentFolder = start.canonical
        self.actions = actions
        self.defaults = defaults
        self.measurer = measurer
        showHidden = defaults.bool(forKey: Key.showHidden)
        viewMode = BrowserViewMode(rawValue: defaults.string(forKey: Key.viewMode) ?? "") ?? .list
        iconSize = IconSize(rawValue: defaults.object(forKey: Key.iconSize) as? Int ?? 1) ?? .medium
        actions.onBackgroundError = { [weak self] message in self?.alertMessage = message }
    }

    /// Downloads when it exists, otherwise the home folder.
    static func defaultStartFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let downloads = home.appending(path: "Downloads")
        return FileManager.default.fileExists(atPath: downloads.path) ? downloads : home
    }

    // MARK: Derived values

    var title: String { FileManager.default.displayName(atPath: currentFolder.path) }
    /// Changing this restarts loading and watching (see `BrowserWindow`).
    var watchKey: String { "\(currentFolder.path)|\(showHidden)" }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentFolder.path != "/" }
    /// A rename or path field has keyboard focus; file shortcuts must not act on the selection.
    var isTyping: Bool { renamingURL != nil || isEditingPath }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.url) } }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    var statusText: String {
        StatusText.make(itemCount: items.count, selectedCount: selection.count, availableBytes: availableBytes)
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
        guard target != currentFolder else { return }
        backStack.append(currentFolder)
        forwardStack.removeAll()
        show(target)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentFolder)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentFolder)
        show(next)
    }

    func goUp() {
        guard canGoUp else { return }
        let child = currentFolder
        navigate(to: currentFolder.deletingLastPathComponent())
        selection = [child]
    }

    private func show(_ folder: URL) {
        currentFolder = folder
        selection = []
        renamingURL = nil
        quickLookURL = nil
        folderStats = [:]
        unmeasurableFolders = []
        measuring = []
        generations = [:]
        changedWhileMeasuring = []
        items = []
        rawItems = []
        loadFailure = nil
    }

    /// Opens files with their default app; navigates into the first folder of the selection.
    func open(_ urls: some Collection<URL>) {
        let targets = items.filter { urls.contains($0.url) }
        for file in targets where !file.isNavigable {
            NSWorkspace.shared.open(file.url)
        }
        if let folder = targets.first(where: \.isNavigable) {
            navigate(to: folder.url)
        }
    }

    func openSelection() { open(selection) }

    // MARK: Loading

    /// Loads the folder, measures sub-folders and keeps refreshing while the folder changes.
    func run() async {
        let folder = currentFolder
        // Start watching before the first listing so changes made meanwhile are not missed.
        let changes = DirectoryWatcher.changes(of: folder)
        let deepChanges = SubtreeWatcher.changes(of: folder)
        await reload()
        await withTaskGroup(of: Void.self) { group in
            // Measuring can take minutes in big trees; it must not block refreshes.
            group.addTask { await self.measureFolders() }
            group.addTask {
                for await paths in deepChanges {
                    await self.handleDeepChanges(paths, in: folder)
                    // Busy trees (like ~/Library) change constantly; re-measure at most every few seconds.
                    try? await Task.sleep(for: .seconds(2))
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
        } catch {
            guard folder == currentFolder, hidden == showHidden else { return }
            rawItems = []
            items = []
            loadFailure = LoadFailure(error)
        }
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

    /// Re-measures sub-folders that changed somewhere below their direct contents.
    private func handleDeepChanges(_ paths: [String], in folder: URL) async {
        let names = SubtreeWatcher.changedChildren(paths: paths, in: folder)
        guard folder == currentFolder, !names.isEmpty else { return }
        for item in rawItems where item.isDirectory && names.contains(item.name) {
            if measuring.contains(item.url) {
                // Let the running walk finish and show its value, then measure once more.
                changedWhileMeasuring.insert(item.url)
            } else {
                invalidate(item.url)
            }
        }
        await measureFolders()
    }

    /// Measures every sub-folder without a size. Folders invalidated while being measured are
    /// measured again (a few rounds at most), so none is left on "Calculating…".
    func measureFolders() async {
        var refreshing: Set<URL> = []
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
                $0.isDirectory && (folderStats[$0.url] == nil || refreshing.contains($0.url))
                    && !unmeasurableFolders.contains($0.url) && !measuring.contains($0.url)
            }
            .map(\.url)
        let generationAtStart = Dictionary(pending.map { ($0, generations[$0, default: 0]) }, uniquingKeysWith: { a, _ in a })
        measuring.formUnion(pending)
        defer { measuring.subtract(pending) }

        var remeasure: [URL] = []
        var queue = pending.makeIterator()
        await withTaskGroup(of: (URL, FolderStats?).self) { group in
            for _ in 0..<4 {
                guard let url = queue.next() else { break }
                group.addTask { [measurer] in (url, await measurer(url)) }
            }
            for await (url, stats) in group {
                if Task.isCancelled { group.cancelAll(); break }
                let stillListed = rawItems.contains { $0.url == url }
                if stillListed, generations[url, default: 0] == generationAtStart[url] {
                    if let stats { folderStats[url] = stats } else { unmeasurableFolders.insert(url) }
                    if changedWhileMeasuring.remove(url) != nil { remeasure.append(url) }
                } else if stillListed {
                    remeasure.append(url)  // invalidated mid-walk: the result is stale
                }
                if let next = queue.next() {
                    group.addTask { [measurer] in (next, await measurer(next)) }
                }
            }
        }
        return remeasure
    }

    private func applySort() {
        if let first = sortOrder.first, first.keyPath == \FileItem.name {
            items = rawItems.sorted(using: FinderOrder(order: first.order))
        } else {
            items = rawItems.sorted(using: sortOrder)
        }
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
        do {
            let renamed = try await actions.rename(item.url, to: newName)
            selection = [renamed.canonical]
        } catch {
            alertMessage = error.localizedDescription
        }
        await reload()
    }

    func cancelRename() { renamingURL = nil }

    // MARK: File operations

    func copySelection() { actions.copyToClipboard(selectedURLs) }
    func cutSelection() { actions.cutToClipboard(selectedURLs) }

    func paste(forceMove: Bool = false) async {
        let folder = currentFolder
        await perform {
            let pasted = try await actions.paste(into: folder, forceMove: forceMove)
            if !pasted.isEmpty, folder == currentFolder { selection = Set(pasted.map(\.canonical)) }
        }
    }

    func trashSelection() async {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        await perform { try await actions.trash(urls) }
    }

    /// Runs a file operation, surfaces errors, and refreshes right away instead of waiting
    /// for the watcher.
    private func perform(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            alertMessage = error.localizedDescription
        }
        await reload()
    }
}
