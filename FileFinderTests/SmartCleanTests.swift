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

    @Test("A duplicate set never loses every copy: the kept copy ticked elsewhere stays")
    func keptCopyTickedElsewhere() async throws {
        let kept = try dir.file("Downloads/App.dmg", bytes: 4)
        let copy = try dir.file("Desktop/App.dmg", bytes: 4)
        let model = model([
            FixedScanner(kind: .duplicates) { _ in [CleanCandidate(url: copy, bytes: 4, detail: "", keptCopy: kept)] },
            FixedScanner(kind: .installers) { _ in [CleanCandidate(url: kept, bytes: 4, detail: "")] },
        ])
        await model.lookAgain()
        #expect(model.ticked == [kept.canonical, copy.canonical])
        #expect(model.itemsToClean.map(\.url) == [copy.canonical])
        #expect(model.tickedBytes == 4)

        await model.clean()

        #expect(exists("Downloads/App.dmg") && !exists("Desktop/App.dmg"))
    }

    @Test("A kept copy inside a ticked folder: one other copy of the set stays")
    func keptCopyInsideTickedFolder() async throws {
        let folder = try dir.folder("Downloads/Old")
        let kept = try dir.file("Downloads/Old/movie.mov", bytes: 4)
        let first = try dir.file("Desktop/movie.mov", bytes: 4)
        let second = try dir.file("Documents/movie.mov", bytes: 4)
        let model = model([
            FixedScanner(kind: .duplicates) { _ in [
                CleanCandidate(url: first, bytes: 4, detail: "", keptCopy: kept),
                CleanCandidate(url: second, bytes: 4, detail: "", keptCopy: kept),
            ] },
            FixedScanner(kind: .developerCaches) { _ in [CleanCandidate(url: folder, bytes: 4, detail: "")] },
        ])
        await model.lookAgain()

        await model.clean()

        #expect(!exists("Downloads/Old"))
        #expect(exists("Desktop/movie.mov") != exists("Documents/movie.mov"))   // exactly one copy left
    }

    @Test("Duplicates alone still trash every copy but the kept one")
    func duplicatesAlone() async throws {
        let kept = try dir.file("Documents/a.bin", bytes: 4)
        let copy = try dir.file("Desktop/a.bin", bytes: 4)
        let model = model([
            FixedScanner(kind: .duplicates) { _ in [CleanCandidate(url: copy, bytes: 4, detail: "", keptCopy: kept)] },
        ])
        await model.lookAgain()

        await model.clean()

        #expect(exists("Documents/a.bin") && !exists("Desktop/a.bin"))
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

    @Test("A Trash that is a link to another folder is never emptied")
    func symlinkedTrash() async throws {
        try FileManager.default.removeItem(at: dir.url.appending(path: ".Trash"))
        try dir.file("Documents/precious.txt", bytes: 5)
        try FileManager.default.createSymbolicLink(
            at: dir.url.appending(path: ".Trash"), withDestinationURL: dir.url.appending(path: "Documents"))
        let model = model([])
        try await registerTrashUndoStep()

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(exists("Documents/precious.txt"))
        #expect(model.alertMessage == FileActionError.notTheTrash.localizedDescription)
        #expect(undoManager.canUndo)   // nothing was deleted
        await #expect(throws: FileActionError.notTheTrash) { try await actions.emptyTrash(dir.url.appending(path: ".Trash")) }
    }

    @Test("The Trash is checked when it's emptied: one swapped for a link while queued is never emptied")
    func trashSwappedWhileQueued() async throws {
        try dir.file("Documents/precious.txt", bytes: 5)
        try dir.file(".Trash/old.txt")
        let source = try dir.file("a.txt")
        try dir.file("Inbox/a.txt")
        let trash = dir.url.appending(path: ".Trash")
        let reached = Gate(), release = Gate()
        let actions = actions
        // A copy waiting on a conflict answer holds the queue.
        let copy = Task {
            try await actions.copy([source], into: dir.url.appending(path: "Inbox")) { _ in
                await reached.open()
                await release.wait()
                return .skipAll
            }
        }
        await reached.wait()
        let empty = Task { try await actions.emptyTrash(trash) }
        while actions.queuedOperations == 0 { await Task.yield() }

        try FileManager.default.removeItem(at: trash)
        try FileManager.default.createSymbolicLink(at: trash, withDestinationURL: dir.url.appending(path: "Documents"))
        await release.open()
        _ = try? await copy.value

        await #expect(throws: FileActionError.notTheTrash) { try await empty.value }
        #expect(exists("Documents/precious.txt"))
    }

    @Test("A Trash swapped for a link halfway through emptying stops before touching the link's folder")
    func trashSwappedDuringDeletion() async throws {
        let count = 3000
        for index in 0..<count {
            try dir.file(".Trash/n\(index)", bytes: 1)
            try dir.file("Documents/n\(index)", bytes: 1)
        }
        let root = dir.url
        let trash = root.appending(path: ".Trash")
        let swapper = Thread {
            // Gives up after 10 s or when the listing fails, so the test never hangs.
            let deadline = Date.now.addingTimeInterval(10)
            while ((try? FileManager.default.contentsOfDirectory(atPath: trash.path).count) ?? 0) > count - 50,
                  Date.now < deadline {}
            try? FileManager.default.moveItem(at: trash, to: root.appending(path: ".Trash-real"))
            try? FileManager.default.createSymbolicLink(at: trash, withDestinationURL: root.appending(path: "Documents"))
        }
        swapper.start()

        await #expect(throws: FileActionError.notTheTrash) { try await actions.emptyTrash(trash) }
        while swapper.isExecuting { try await Task.sleep(for: .milliseconds(5)) }

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Documents").path).count == count)
    }

    @Test("The dialog closing before its button runs still empties the Trash")
    func dialogDismissedFirst() async throws {
        try dir.file(".Trash/old.txt")
        let model = model([])

        model.requestEmptyTrash()
        model.isConfirmingEmptyTrash = false   // SwiftUI resets the binding before the action
        await model.confirmEmptyTrash()

        #expect(!exists(".Trash/old.txt"))
    }

    @Test("Emptying the Trash drops the undo steps that pointed into it")
    func emptyDropsUndo() async throws {
        let file = try dir.file("cache.bin", bytes: 1)
        let model = model([FixedScanner(kind: .developerCaches) { _ in [CleanCandidate(url: file, bytes: 1, detail: "")] }])
        await model.lookAgain()
        await model.clean()
        #expect(undoManager.canUndo)

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(!undoManager.canUndo)
    }

    /// A real "Move to Trash" undo step (the tiny file goes to the real Trash).
    private func registerTrashUndoStep() async throws {
        try await actions.trash([try dir.file("step-\(UUID()).bin", bytes: 1)])
        #expect(undoManager.canUndo)
    }

    @Test("A Trash move undone then redone is still dropped by emptying; an undone one keeps its Redo")
    func emptyAfterUndoRedo() async throws {
        let first = try dir.file("first.bin", bytes: 1)
        let second = try dir.file("second.bin", bytes: 1)
        try await actions.trash([first])
        undoManager.undo()
        await actions.waitForPendingWork()
        undoManager.redo()                      // first.bin is in the Trash again
        await actions.waitForPendingWork()
        try await actions.trash([second])
        undoManager.undo()                      // second.bin is back, its Redo waits
        await actions.waitForPendingWork()
        try dir.file(".Trash/old.txt")
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(!undoManager.canUndo)
        #expect(undoManager.canRedo && exists("second.bin"))
    }

    @Test("Emptying the Trash drops only the undo steps into the Trash; a rename keeps its Undo")
    func emptyKeepsUnrelatedUndo() async throws {
        let file = try dir.file("cache.bin", bytes: 1)
        let draft = try dir.file("draft.txt")
        try dir.file(".Trash/old.txt")
        let model = model([FixedScanner(kind: .developerCaches) { _ in [CleanCandidate(url: file, bytes: 1, detail: "")] }])
        await model.lookAgain()
        await model.clean()
        try await actions.rename(draft, to: "final.txt")

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(undoManager.undoActionName == "Rename")
        undoManager.undo()
        await actions.waitForPendingWork()
        #expect(exists("draft.txt") && !exists("final.txt"))
        #expect(!undoManager.canUndo)   // the Smart Clean step is gone
    }

    /// A file in the test Trash that can't be deleted until `unlock` runs.
    private func lockedTrashFile(_ name: String) throws -> URL {
        let url = try dir.file(".Trash/\(name)", bytes: 1)
        #expect(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
        return url
    }

    private func unlock(_ url: URL) { chflags(url.path, 0) }

    @Test("A partly failed Empty Trash still drops the undo steps, since some items are gone for good")
    func partlyFailedEmptyDropsUndo() async throws {
        let locked = try lockedTrashFile("locked.txt")
        defer { unlock(locked) }
        try dir.file(".Trash/gone.txt", bytes: 1)
        try await registerTrashUndoStep()
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(!exists(".Trash/gone.txt") && exists(".Trash/locked.txt"))
        #expect(model.alertMessage != nil)
        #expect(!undoManager.canUndo)
    }

    @Test("A partly emptied folder in the Trash counts as deleted: the undo steps are dropped")
    func partlyEmptiedFolderDropsUndo() async throws {
        // Removing a folder stops at its first undeletable file; with these names (APFS lists
        // them in a fixed order) some of the others go first.
        let locked = try lockedTrashFile("Box/m.txt")
        defer { unlock(locked) }
        let others = ["a", "b", "y", "z"].map { ".Trash/Box/\($0).txt" }
        try others.forEach { try dir.file($0, bytes: 1) }
        try await registerTrashUndoStep()
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        try #require(exists(".Trash/Box/m.txt") && others.contains { !exists($0) })
        #expect(model.alertMessage != nil)
        #expect(!undoManager.canUndo)
    }

    @Test("An Empty Trash that deleted nothing keeps the undo steps")
    func failedEmptyKeepsUndo() async throws {
        let locked = try lockedTrashFile("locked.txt")
        defer { unlock(locked) }
        try await registerTrashUndoStep()
        let model = model([])

        model.requestEmptyTrash()
        await model.confirmEmptyTrash()

        #expect(exists(".Trash/locked.txt"))
        #expect(model.alertMessage != nil)
        #expect(undoManager.canUndo)
    }

    @Test("An item the user unticked stays unticked when a slower suggestion lists it too")
    func untickSticks() async throws {
        let dmg = try dir.file("Downloads/App.dmg", bytes: 4)
        let gate = Gate()
        let model = model([
            FixedScanner(kind: .installers) { _ in [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
            SlowScanner(kind: .duplicates, gate: gate) { [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
        ])
        let scan = Task { await model.lookAgain() }
        while !model.isTicked(dmg) { await Task.yield() }

        model.toggle(dmg)
        await gate.open()
        await scan.value

        #expect(!model.isTicked(dmg))
    }

    @Test("An item listed by Safe to clear starts ticked even when a Your call suggestion lists it first")
    func safeTickWinsWhicheverFinishesFirst() async throws {
        let dmg = try dir.file("Downloads/App.dmg", bytes: 4)
        let gate = Gate()
        let model = model([
            SlowScanner(kind: .installers, gate: gate) { [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
            FixedScanner(kind: .oldDownloads) { _ in [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
        ])
        let scan = Task { await model.lookAgain() }
        while model.suggestion(.oldDownloads)?.candidates.isEmpty != false { await Task.yield() }
        #expect(!model.isTicked(dmg))

        await gate.open()
        await scan.value

        #expect(model.isTicked(dmg))
    }

    @Test("Ticking a whole suggestion counts as the user's choice: a slower one doesn't change it")
    func setAllSticks() async throws {
        let dmg = try dir.file("Downloads/App.dmg", bytes: 4)
        let gate = Gate()
        let model = model([
            FixedScanner(kind: .oldDownloads) { _ in [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
            SlowScanner(kind: .installers, gate: gate) { [CleanCandidate(url: dmg, bytes: 4, detail: "")] },
        ])
        let scan = Task { await model.lookAgain() }
        while model.suggestion(.oldDownloads)?.candidates.isEmpty != false { await Task.yield() }
        model.setAll(.oldDownloads, ticked: true)
        model.setAll(.oldDownloads, ticked: false)

        await gate.open()
        await scan.value

        #expect(!model.isTicked(dmg))
    }

    @Test("Looking again cancels the older scan, so it stops working in the background")
    func lookAgainCancelsOlderScan() async throws {
        let probe = ScanProbe()
        let model = model([UntilCancelledScanner(kind: .duplicates, probe: probe)])
        let first = Task { await model.lookAgain() }
        while await probe.started < 1 { await Task.yield() }

        let second = Task { await model.lookAgain() }
        #expect(await probe.waitForCancellation())
        await first.value
        await probe.release()
        await second.value
        #expect(!model.isScanning)
    }

    @Test("Closing the window (cancelling Look Again) cancels its scan")
    func cancellingLookAgainCancelsScan() async throws {
        let probe = ScanProbe()
        let model = model([UntilCancelledScanner(kind: .duplicates, probe: probe)])
        let scan = Task { await model.lookAgain() }
        while await probe.started < 1 { await Task.yield() }

        scan.cancel()

        #expect(await probe.waitForCancellation())
        await scan.value
    }

    @Test("An item gone since the scan doesn't stop the others from being cleaned")
    func vanishedItem() async throws {
        let a = try dir.file("a.bin", bytes: 1)
        let b = try dir.file("b.bin", bytes: 1)
        let c = try dir.file("c.bin", bytes: 1)
        let model = model([FixedScanner(kind: .developerCaches) { _ in
            [a, b, c].map { CleanCandidate(url: $0, bytes: 1, detail: "") }
        }])
        await model.lookAgain()
        try FileManager.default.removeItem(at: b)

        await model.clean()

        #expect(!exists("a.bin") && !exists("c.bin"))
        #expect(model.alertMessage == nil)
    }

    @Test("Your files leave out ~/Applications, which Apps already counts")
    func noDoubleCountedApps() async throws {
        try dir.file("Applications/Big.app/Contents/bin", bytes: 1000)
        try dir.file("Documents/doc", bytes: 10)
        let env = environment()
        #expect(await StorageOverview.measureApps(env) == 1000)
        #expect(await StorageOverview.measureYourFiles(env) == 10)
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

/// Counts the scans of an `UntilCancelledScanner` and whether one was cancelled.
actor ScanProbe {
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var isReleased = false

    func start() -> Int { started += 1; return started }
    func markCancelled() { cancelled += 1 }
    func release() { isReleased = true }

    /// Whether a scan was cancelled within 5 s.
    func waitForCancellation() async -> Bool {
        let deadline = Date.now.addingTimeInterval(5)
        while cancelled == 0, Date.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return cancelled > 0
    }
}

/// Its first scan works until it is cancelled (or released after 5 s at most); later scans
/// finish once released.
struct UntilCancelledScanner: SuggestionScanner {
    let kind: SuggestionKind
    let probe: ScanProbe

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        let run = await probe.start()
        let deadline = Date.now.addingTimeInterval(5)
        while Date.now < deadline {
            if Task.isCancelled {
                await probe.markCancelled()
                throw CancellationError()
            }
            if run > 1, await probe.isReleased { return [] }
            await Task.yield()
        }
        return []
    }
}

/// Lets a test decide when a slow scanner finishes.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

struct SlowScanner: SuggestionScanner {
    let kind: SuggestionKind
    let gate: Gate
    let candidates: @Sendable () -> [CleanCandidate]

    func scan(_ environment: CleanEnvironment) async throws -> [CleanCandidate] {
        await gate.wait()
        return candidates()
    }
}
