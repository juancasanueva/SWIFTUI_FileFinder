import Foundation

/// Reading helpers shared by the Downloads-style scanners.
private nonisolated enum DirectChildren {
    /// Visible items directly in `folder`, sorted by name; empty when it can't be read.
    static func of(_ folder: URL, keys: [URLResourceKey] = []) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Visible regular files directly in `folder`, sorted by name.
    static func regularFiles(in folder: URL) -> [URL] {
        of(folder, keys: [.isRegularFileKey]).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    static func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
}

// MARK: - Installers

/// .dmg and .pkg files in Downloads and Desktop for apps that are installed.
nonisolated struct InstallersScanner: SuggestionScanner {
    let kind = SuggestionKind.installers

    private static let extensions: Set<String> = ["dmg", "pkg"]
    private static let platformWords: Set<String> = [
        "mac", "macos", "osx", "darwin", "universal", "arm64", "x64", "x86", "intel", "apple", "silicon",
        "installer", "setup", "release", "stable", "latest",
    ]

    init() {}

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        var appsByName: [String: InstalledApp] = [:]
        for app in environment.installedApps {
            let name = Self.normalized(app.name)
            if name.count >= 3, appsByName[name] == nil { appsByName[name] = app }
        }
        var found: [CleanCandidate] = []
        for folder in ["Downloads", "Desktop"].map({ environment.home.appending(path: $0) }) {
            for url in DirectChildren.of(folder) where Self.extensions.contains(url.pathExtension.lowercased()) {
                try Task.checkCancellation()
                let name = Self.normalized(url.deletingPathExtension().lastPathComponent)
                guard name.count >= 3, let app = appsByName[name] else { continue }
                found.append(CleanCandidate(
                    url: url, bytes: CleanWalker.size(of: url), detail: "“\(app.name)” is installed"))
            }
        }
        return found
    }

    /// Lowercased letters and digits of `name`, without version numbers or platform words.
    /// "Slack-4.41.105-macOS" becomes "slack".
    static func normalized(_ name: String) -> String {
        name.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { !isVersion($0) && !platformWords.contains($0) }
            .joined()
    }

    /// "4", "41", "v2".
    private static func isVersion(_ token: String) -> Bool {
        let digits = token.hasPrefix("v") ? token.dropFirst() : Substring(token)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}

// MARK: - Mail attachments

/// The copies Mail keeps of attachments you opened.
nonisolated struct MailAttachmentsScanner: SuggestionScanner {
    let kind = SuggestionKind.mailAttachments

    init() {}

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        let folder = environment.library.appending(path: "Containers/com.apple.mail/Data/Library/Mail Downloads")
        var found: [CleanCandidate] = []
        for entry in DirectChildren.of(folder) {
            try Task.checkCancellation()
            let name = DirectChildren.of(entry).first?.lastPathComponent ?? entry.lastPathComponent
            found.append(CleanCandidate(
                url: entry, bytes: CleanWalker.size(of: entry), detail: "Mail's copy of “\(name)”"))
        }
        return found
    }
}

// MARK: - Old downloads

/// Files in Downloads (and its Tidy kind folders) added over 90 days ago and not opened since.
nonisolated struct OldDownloadsScanner: SuggestionScanner {
    let kind = SuggestionKind.oldDownloads

    private static let age: TimeInterval = 90 * 86_400
    private static let inProgress: Set<String> = ["download", "crdownload", "part"]
    /// When a file was added to its folder; `nil` falls back to its creation date.
    private let addedDate: @Sendable (URL) -> Date?

    init() {
        self.init(addedDate: { try? $0.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate })
    }

    /// Tests inject the date added, which the file system doesn't let them set.
    init(addedDate: @escaping @Sendable (URL) -> Date?) {
        self.addedDate = addedDate
    }

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        let downloads = environment.home.appending(path: "Downloads")
        let folders = [downloads] + FileKind.allCases.map { downloads.appending(path: $0.folderName) }
        let cutoff = environment.now.addingTimeInterval(-Self.age)
        var found: [CleanCandidate] = []
        for folder in folders {
            for url in DirectChildren.regularFiles(in: folder)
            where !Self.inProgress.contains(url.pathExtension.lowercased()) {
                try Task.checkCancellation()
                let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
                guard let added = addedDate(url) ?? created, added < cutoff else { continue }
                if let opened = environment.lastOpened(url), opened >= cutoff { continue }
                found.append(CleanCandidate(
                    url: url, bytes: CleanWalker.size(of: url), detail: "Downloaded \(DirectChildren.date(added))"))
            }
        }
        return found
    }
}

// MARK: - Screen recordings

/// .mov and .mp4 screen recordings older than 30 days.
nonisolated struct ScreenRecordingsScanner: SuggestionScanner {
    let kind = SuggestionKind.screenRecordings

    private static let age: TimeInterval = 30 * 86_400
    private static let extensions: Set<String> = ["mov", "mp4"]
    private static let namePrefixes = ["Screen Recording", "Grabación de pantalla"]
    /// Where screenshots and recordings are saved when the user changed it, else `nil`.
    private let customLocation: @Sendable () -> URL?

    init() {
        self.init(customLocation: Self.screenshotLocation)
    }

    /// Tests inject the custom location instead of reading the user's settings.
    init(customLocation: @escaping @Sendable () -> URL?) {
        self.customLocation = customLocation
    }

    /// The location set in Screenshot ▸ Options ▸ Save to, if any.
    @Sendable static func screenshotLocation() -> URL? {
        guard let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
              !path.isEmpty else { return nil }
        return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        var folders = ["Desktop", "Documents", "Movies", "Downloads"].map { environment.home.appending(path: $0).canonical }
        if let custom = customLocation()?.canonical, !folders.contains(custom) { folders.append(custom) }
        let cutoff = environment.now.addingTimeInterval(-Self.age)
        var found: [CleanCandidate] = []
        for folder in folders {
            for url in DirectChildren.regularFiles(in: folder) where Self.extensions.contains(url.pathExtension.lowercased()) {
                try Task.checkCancellation()
                guard isRecording(url, environment) else { continue }
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                guard let recorded = values?.creationDate ?? values?.contentModificationDate, recorded < cutoff else { continue }
                found.append(CleanCandidate(
                    url: url, bytes: CleanWalker.size(of: url), detail: "Recorded \(DirectChildren.date(recorded))"))
            }
        }
        return found
    }

    private func isRecording(_ url: URL, _ environment: CleanEnvironment) -> Bool {
        let name = url.lastPathComponent
        return environment.isScreenCapture(url)
            || Self.namePrefixes.contains { name.range(of: $0, options: [.caseInsensitive, .anchored]) != nil }
    }
}
