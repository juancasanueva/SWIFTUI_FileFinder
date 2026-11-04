import AppKit
import Foundation
import Testing
@testable import FileFinder

/// A scanner that returns fixed candidates, for testing the model.
struct FixedScanner: SuggestionScanner {
    let kind: SuggestionKind
    let candidates: @Sendable (CleanEnvironment) -> [CleanCandidate]

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] { candidates(environment) }
}

@MainActor
@Suite("Smart Clean")
struct SmartCleanTests {
    let dir: TemporaryDirectory
    let undoManager: UndoManager
    let actions: FileActions

    init() throws {
        dir = try TemporaryDirectory()
        try dir.folder(".Trash")
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
        actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        actions.undoManager = undoManager
    }

    private func environment() -> CleanEnvironment {
        CleanEnvironment.testing(home: dir.url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.url.appending(path: path).path)
    }

    private func model(_ scanners: [any SuggestionScanner]) -> SmartCleanModel {
        let home = dir.url
        return SmartCleanModel(
            actions: actions, scanners: scanners, environment: { CleanEnvironment.testing(home: home) },
            measureStorage: false)
    }

    // MARK: - Catalog

    @Test("Nine suggestions: four Safe to clear (ticked), five Your call (unticked), each with a why")
    func catalog() {
        #expect(SuggestionKind.allCases.count == 9)
        #expect(SuggestionKind.allCases.filter { $0.group == .safe } == [.developerCaches, .duplicates, .installers, .mailAttachments])
        #expect(SuggestionKind.allCases.filter { $0.group == .yourCall } == [.bigFiles, .unusedApps, .screenRecordings, .oldDownloads, .leftovers])
        #expect(SuggestionKind.allCases.allSatisfy { !$0.title.isEmpty && !$0.why.isEmpty })
        #expect(CleanGroup.safe.title == "Safe to clear" && CleanGroup.yourCall.title == "Your call")
    }

    // MARK: - Scanning and ticks

    @Test("Safe to clear starts ticked, Your call unticked, and a candidate can opt out (node_modules)")
    func defaultTicks() async throws {
        let cache = try dir.file("cache.bin", bytes: 10)
        let modules = try dir.folder("app/node_modules")
        let big = try dir.file("big.mov", bytes: 30)
        let model = model([
            FixedScanner(kind: .developerCaches) { _ in [
                CleanCandidate(url: cache, bytes: 10, detail: "cache"),
                CleanCandidate(url: modules, bytes: 5, detail: "untouched", isTickedByDefault: false),
            ] },
            FixedScanner(kind: .bigFiles) { _ in [CleanCandidate(url: big, bytes: 30, detail: "big")] },
        ])

        await model.lookAgain()

        #expect(model.suggestions.map(\.kind) == SuggestionKind.allCases)
        #expect(model.ticked == [cache.canonical])
        #expect(model.tickedBytes == 10)
        #expect(model.suggestion(.bigFiles)?.bytes == 30)
        #expect(model.suggestion(.duplicates)?.candidates.isEmpty == true)
    }

    @Test("An item listed by two suggestions counts once; ticking it ticks it everywhere")
    func overlap() async throws {
        let file = try dir.file("Downloads/old.dmg", bytes: 7)
        let model = model([
            FixedScanner(kind: .installers) { _ in [CleanCandidate(url: file, bytes: 7, detail: "a")] },
            FixedScanner(kind: .oldDownloads) { _ in [CleanCandidate(url: file, bytes: 7, detail: "b")] },
        ])
        await model.lookAgain()

        #expect(model.tickedBytes == 7)
        model.toggle(file)
        #expect(model.ticked.isEmpty)
        model.setAll(.oldDownloads, ticked: true)
        #expect(model.ticked == [file.canonical])
    }

    // MARK: - Cleaning

    @Test("Clean moves only the ticked items to the Trash, as one step Undo brings back")
    func cleanAndUndo() async throws {
        let a = try dir.file("a.bin", bytes: 1)
        let b = try dir.file("b.bin", bytes: 1)
        let keep = try dir.file("keep.bin", bytes: 1)
        let model = model([
            FixedScanner(kind: .developerCaches) { _ in [
                CleanCandidate(url: a, bytes: 1, detail: ""), CleanCandidate(url: b, bytes: 1, detail: ""),
            ] },
            FixedScanner(kind: .bigFiles) { _ in [CleanCandidate(url: keep, bytes: 1, detail: "")] },
        ])
        await model.lookAgain()

        await model.clean()

        #expect(!exists("a.bin") && !exists("b.bin") && exists("keep.bin"))
        #expect(undoManager.undoActionName == "Smart Clean")
        #expect(model.ticked.isEmpty)
        #expect(model.suggestion(.developerCaches)?.candidates.isEmpty == true)   // looked again

        undoManager.undo()
        await actions.waitForPendingWork()
        #expect(exists("a.bin") && exists("b.bin"))
        #expect(!undoManager.canUndo)
    }

    @Test("A ticked item inside a ticked folder isn't trashed twice")
    func nestedTicks() async throws {
        let folder = try dir.folder("DerivedData")
        let inner = try dir.file("DerivedData/App/build.o", bytes: 1)
        let model = model([
            FixedScanner(kind: .developerCaches) { _ in [CleanCandidate(url: folder, bytes: 1, detail: "")] },
            FixedScanner(kind: .duplicates) { _ in [CleanCandidate(url: inner, bytes: 1, detail: "")] },
        ])
        await model.lookAgain()
        #expect(model.tickedBytes == 1)   // the inner item is already inside the folder

        await model.clean()

        #expect(!exists("DerivedData"))
        #expect(model.alertMessage == nil)
    }

    @Test("Nothing ticked: Clean does nothing")
    func cleanNothing() async throws {
        let model = model([])
        await model.lookAgain()
        await model.clean()
        #expect(!undoManager.canUndo)
    }

    // MARK: - Empty Trash

    @Test("Empty Trash always asks, and deletes the Trash's contents only once confirmed")
    func emptyTrash() async throws {
        try dir.file(".Trash/old.txt", bytes: 3)
        try dir.file(".Trash/folder/inner.txt", bytes: 3)
        let model = model([])

        model.requestEmptyTrash()
        #expect(model.isConfirmingEmptyTrash)
        model.cancelEmptyTrash()
        #expect(!model.isConfirmingEmptyTrash)
        await model.confirmEmptyTrash()   // not asked anymore: nothing happens
        #expect(exists(".Trash/old.txt"))

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(!model.isConfirmingEmptyTrash)
        #expect(exists(".Trash"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.appending(path: ".Trash").path).isEmpty)
    }

    @Test("Emptying refuses any folder that isn't a Trash")
    func emptyOnlyTrash() async throws {
        let folder = try dir.folder("Documents")
        try dir.file("Documents/precious.txt")
        await #expect(throws: FileActionError.notTheTrash) { try await actions.emptyTrash(folder) }
        #expect(exists("Documents/precious.txt"))
    }

    // MARK: - Storage

    @Test("Storage: used, System as the rest, and the volume's real capacity")
    func storage() throws {
        var overview = StorageOverview(total: 1_000, available: 200)
        #expect(overview.used == 800)
        #expect(overview.system == nil)   // not everything measured yet
        overview.apps = 100
        overview.yourFiles = 300
        overview.other = 150
        overview.trash = 50
        #expect(overview.system == 200)

        let real = try #require(StorageOverview.capacity(of: dir.url))
        #expect(real.total > 0 && real.available > 0 && real.available <= real.total)
    }

    @Test("Your files skip ~/Library and the Trash, which count as Other and In the Trash")
    func storageCategories() async throws {
        try dir.file("Documents/a.bin", bytes: 100)
        try dir.file(".npm/x", bytes: 10)
        try dir.file("Library/Caches/c.bin", bytes: 40)
        try dir.file(".Trash/t.bin", bytes: 5)
        let env = environment()

        #expect(await StorageOverview.measureYourFiles(env) == 110)
        #expect(await StorageOverview.measureOther(env) == 40)
        #expect(await StorageOverview.measureTrash(env) == 5)
    }

    // MARK: - Walker shared by scanners

    @Test("The walker visits regular files of a minimum size, never hidden items or package contents")
    func walker() throws {
        try dir.file("Documents/big.bin", bytes: 50)
        try dir.file("Documents/small.bin", bytes: 5)
        try dir.file("Documents/.hidden/big.bin", bytes: 50)
        try dir.file("Documents/.dot.bin", bytes: 50)
        try dir.file("Documents/Tool.app/Contents/big.bin", bytes: 50)
        try dir.file("Documents/deep/er/big2.bin", bytes: 60)

        var seen: [String: Int64] = [:]
        try CleanWalker.regularFiles(in: [dir.url.appending(path: "Documents")], minimumSize: 10) { url, size in
            seen[url.lastPathComponent] = size
        }

        #expect(seen == ["big.bin": 50, "big2.bin": 60])
    }

    @Test("Folders named like a target are found without entering them or hidden folders")
    func walkerDirectories() throws {
        try dir.folder("Projects/web/node_modules/dep/node_modules")
        try dir.folder("Projects/.cache/node_modules")
        try dir.folder("Projects/a/b/c/d/e/f/node_modules")   // too deep

        let found = CleanWalker.directories(named: "node_modules", in: [dir.url.appending(path: "Projects")], maxDepth: 4)

        #expect(found.map { $0.deletingLastPathComponent().lastPathComponent } == ["web"])
    }

    @Test("Sizes: a file's own size, a folder's whole tree")
    func sizes() throws {
        let file = try dir.file("f.bin", bytes: 12)
        try dir.file("d/a", bytes: 3)
        try dir.file("d/e/b", bytes: 4)
        #expect(CleanWalker.size(of: file) == 12)
        #expect(CleanWalker.size(of: dir.url.appending(path: "d")) == 7)
    }
}

extension CleanEnvironment {
    /// A home folder in a test directory: no installed apps, nothing ever opened, a fixed "now".
    static func testing(
        home: URL, now: Date = Date(timeIntervalSince1970: 1_793_804_400), installedApps: [InstalledApp] = [],
        lastOpened: @escaping @Sendable (URL) -> Date? = { _ in nil },
        isScreenCapture: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) -> CleanEnvironment {
        CleanEnvironment(
            home: home, applicationFolders: [home.appending(path: "Applications")], now: now,
            installedApps: installedApps, ownBundleID: "com.juancasanueva.FileFinder",
            lastOpened: lastOpened, isScreenCapture: isScreenCapture)
    }
}
