import Foundation

/// Regular files of 1 GB or more in the user folders. Only the user knows if they still need them.
nonisolated struct BigFilesScanner: SuggestionScanner {
    let kind = SuggestionKind.bigFiles
    let minimumSize: Int64

    init(minimumSize: Int64 = 1_000_000_000) {
        self.minimumSize = minimumSize
    }

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        let roots = environment.userFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        var found: [CleanCandidate] = []
        try CleanWalker.regularFiles(in: roots, minimumSize: minimumSize) { url, size in
            let opened = environment.lastOpened(url)
                .map { "opened \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "never opened"
            found.append(CleanCandidate(url: url, bytes: size, detail: "\(StatusText.formatBytes(size)) · \(opened)"))
        }
        return found.sorted { $0.bytes > $1.bytes }
    }
}

/// Apps in the application folders not opened for 6 months. Apple's apps, this app and apps
/// whose last-opened date is unknown are never listed.
nonisolated struct UnusedAppsScanner: SuggestionScanner {
    let kind = SuggestionKind.unusedApps
    static let unusedInterval: TimeInterval = 182 * 86_400

    init() {}

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        var found: [CleanCandidate] = []
        for app in CleanEnvironment.findApps(in: environment.applicationFolders) {
            try Task.checkCancellation()
            guard let id = app.bundleID, !id.lowercased().hasPrefix("com.apple."),
                  id.lowercased() != environment.ownBundleID?.lowercased(),
                  let opened = environment.lastOpened(app.url),
                  environment.now.timeIntervalSince(opened) > Self.unusedInterval else { continue }
            found.append(CleanCandidate(
                url: app.url, bytes: CleanWalker.size(of: app.url),
                detail: "Last opened \(opened.formatted(date: .abbreviated, time: .omitted))"))
        }
        return found.sorted { $0.bytes > $1.bytes }
    }
}

/// Settings and caches in ~/Library named after a bundle id that no installed app has, unchanged
/// for 30 days. Deliberately conservative: anything not clearly a deleted app's is kept, and
/// Containers and Group Containers are never looked at.
nonisolated struct LeftoversScanner: SuggestionScanner {
    let kind = SuggestionKind.leftovers
    static let unchangedInterval: TimeInterval = 30 * 86_400

    /// The ~/Library folders looked at, and the extension an entry must have there (stripped to get its id).
    static let folders: [(name: String, requiredExtension: String?)] = [
        ("Application Support", nil), ("Caches", nil), ("Preferences", "plist"),
        ("Saved Application State", "savedState"), ("HTTPStorages", nil), ("WebKit", nil),
    ]

    init() {}

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        let installed = Set(
            (environment.installedApps.compactMap(\.bundleID) + [environment.ownBundleID].compactMap { $0 })
                .map { $0.lowercased() })
        var found: [CleanCandidate] = []
        for folder in Self.folders {
            let parent = environment.library.appending(path: folder.name)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                guard let id = Self.bundleID(of: child, requiredExtension: folder.requiredExtension),
                      !Self.belongsToInstalledApp(id, installed: installed),
                      let changed = Self.newestModification(of: child),
                      environment.now.timeIntervalSince(changed) > Self.unchangedInterval else { continue }
                found.append(CleanCandidate(
                    url: child, bytes: CleanWalker.size(of: child),
                    detail: "\(folder.name) of “\(id)”, an app that isn't installed"))
            }
        }
        return found.sorted { $0.bytes > $1.bytes }
    }

    /// The bundle id an entry is named after, or `nil` when it isn't named like one.
    static func bundleID(of url: URL, requiredExtension: String?) -> String? {
        var name = url.lastPathComponent
        if let requiredExtension {
            guard url.pathExtension == requiredExtension else { return nil }
            name = url.deletingPathExtension().lastPathComponent
        }
        return looksLikeBundleID(name) ? name : nil
    }

    /// At least three dot-separated parts, each of ASCII letters, digits, "-" or "_", starting with a letter.
    static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.first, first.isASCII, first.isLetter else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Apple's, an installed app's (same id, a helper below it, or the same vendor.product).
    static func belongsToInstalledApp(_ id: String, installed: Set<String>) -> Bool {
        let id = id.lowercased()
        if id.hasPrefix("com.apple.") || installed.contains(id) { return true }
        let vendorProduct = id.split(separator: ".").prefix(3).joined(separator: ".")
        return installed.contains { app in
            if id.hasPrefix(app + ".") { return true }
            let parts = app.split(separator: ".")
            return parts.count >= 3 && parts.prefix(3).joined(separator: ".") == vendorProduct
        }
    }

    /// The entry's own modification date, or for a folder the newest of it and its direct children.
    /// `nil` when unreadable, so the entry is kept.
    static func newestModification(of url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys), let own = values.contentModificationDate else {
            return nil
        }
        if values.isSymbolicLink == true { return nil }   // a link isn't the app's data: keep it
        guard values.isDirectory == true else { return own }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return nil }
        var newest = own
        for child in children {
            guard let date = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            newest = max(newest, date)
        }
        return newest
    }
}
