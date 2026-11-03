import Foundation
import Observation

/// One item gathered into a workspace. Stored as a bookmark, so it follows the item when it
/// is moved or renamed; `path` is the last place it was seen (shown when it's missing).
nonisolated struct WorkspaceEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var bookmark: Data
    var path: String
    let added: Date

    var name: String { (path as NSString).lastPathComponent }
}

/// A named page of folders and files from anywhere. Nothing is copied or moved.
nonisolated struct Workspace: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var entries: [WorkspaceEntry]
}

/// All workspaces, shared by every window and saved as JSON.
@Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore(fileURL: WorkspaceStore.defaultFileURL)

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "FileFinder/workspaces.json")
    }

    private(set) var workspaces: [Workspace] = []
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func workspace(_ id: Workspace.ID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    // MARK: Workspaces

    @discardableResult
    func create(named name: String? = nil) -> Workspace {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let workspace = Workspace(id: UUID(), name: trimmed.isEmpty ? untitledName() : trimmed, entries: [])
        workspaces.append(workspace)
        save()
        return workspace
    }

    /// Empty names are ignored, so a workspace always has one.
    func rename(_ id: Workspace.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
    }

    /// Deletes the workspace only; its items stay where they are.
    func delete(_ id: Workspace.ID) {
        workspaces.removeAll { $0.id == id }
        save()
    }

    // MARK: Entries

    /// Adds items that aren't in the workspace yet. Returns how many were added.
    @discardableResult
    func add(_ urls: [URL], to id: Workspace.ID) -> Int {
        guard let workspace = workspace(id) else { return 0 }
        var known = Set(workspace.entries.compactMap { resolve($0)?.path })
        var added: [WorkspaceEntry] = []
        for url in urls {
            let path = Self.normalizedPath(url)
            guard !known.contains(path),
                  let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            else { continue }
            known.insert(path)
            added.append(WorkspaceEntry(id: UUID(), bookmark: bookmark, path: path, added: .now))
        }
        guard !added.isEmpty else { return 0 }
        update(id) { $0.entries.append(contentsOf: added) }
        return added.count
    }

    /// Removes entries from the workspace; the items themselves are not touched.
    func remove(_ entryIDs: Set<WorkspaceEntry.ID>, from id: Workspace.ID) {
        update(id) { $0.entries.removeAll { entryIDs.contains($0.id) } }
    }

    /// Where an entry's item is now, or `nil` when it's gone (deleted, or in the Trash).
    /// Updates the stored bookmark and path when the item moved.
    func resolve(_ entry: WorkspaceEntry) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: entry.bookmark, options: [.withoutUI, .withoutMounting],
            relativeTo: nil, bookmarkDataIsStale: &isStale)
        else { return nil }
        let path = Self.normalizedPath(url)
        guard FileManager.default.fileExists(atPath: path), !path.contains("/.Trash/") else { return nil }
        let resolved = URL(filePath: path)
        if isStale || path != entry.path {
            let bookmark = isStale
                ? (try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
                : nil
            refresh(entry.id, path: path, bookmark: bookmark)
        }
        return resolved
    }

    // MARK: Helpers

    private func refresh(_ entryID: WorkspaceEntry.ID, path: String, bookmark: Data?) {
        guard let index = workspaces.firstIndex(where: { $0.entries.contains { $0.id == entryID } }),
              let entryIndex = workspaces[index].entries.firstIndex(where: { $0.id == entryID }) else { return }
        workspaces[index].entries[entryIndex].path = path
        if let bookmark { workspaces[index].entries[entryIndex].bookmark = bookmark }
        save()
    }

    private func update(_ id: Workspace.ID, _ change: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        change(&workspaces[index])
        save()
    }

    private func untitledName() -> String {
        let names = Set(workspaces.map(\.name))
        if !names.contains("Untitled Workspace") { return "Untitled Workspace" }
        var index = 2
        while names.contains("Untitled Workspace \(index)") { index += 1 }
        return "Untitled Workspace \(index)"
    }

    private nonisolated static func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            workspaces = try JSONDecoder().decode([Workspace].self, from: data)
        } catch {
            // Keep the damaged file for recovery instead of overwriting it on the next save.
            let stamp = Int(Date.now.timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appending(path: "\(fileURL.lastPathComponent).damaged-\(stamp)")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            workspaces = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(workspaces).write(to: fileURL, options: .atomic)
        } catch {
            // Nothing sensible to do mid-edit; the in-memory state stays and the next save retries.
        }
    }
}
