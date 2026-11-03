import Foundation
import Testing
@testable import FileFinder

@Suite("Directory listing")
struct DirectoryListingTests {
    @Test("Lists files and folders with their metadata")
    func listsFilesAndFolders() throws {
        let dir = try TemporaryDirectory()
        try dir.file("notes.txt", bytes: 12)
        try dir.folder("Photos")

        let items = try DirectoryLister.contents(of: dir.url, showHidden: false)

        let notes = try #require(items.first { $0.name == "notes.txt" })
        #expect(notes.isDirectory == false)
        #expect(notes.size == 12)
        #expect(notes.modificationDate != nil)
        #expect(!notes.kind.isEmpty)

        let photos = try #require(items.first { $0.name == "Photos" })
        #expect(photos.isDirectory)
        #expect(photos.size == nil)
        #expect(items.count == 2)
    }

    @Test("Hidden files are excluded unless requested", arguments: [false, true])
    func hiddenFiles(showHidden: Bool) throws {
        let dir = try TemporaryDirectory()
        try dir.file("visible.txt")
        try dir.file(".secret")

        let names = try DirectoryLister.contents(of: dir.url, showHidden: showHidden).map(\.name)

        #expect(names.contains("visible.txt"))
        #expect(names.contains(".secret") == showHidden)
    }

    @Test("Hidden items are flagged")
    func hiddenItemsAreFlagged() throws {
        let dir = try TemporaryDirectory()
        try dir.file(".secret")

        let item = try #require(try DirectoryLister.contents(of: dir.url, showHidden: true).first)

        #expect(item.isHidden)
    }

    @Test("Listing a missing folder throws")
    func missingFolderThrows() throws {
        let dir = try TemporaryDirectory()
        #expect(throws: (any Error).self) {
            try DirectoryLister.contents(of: dir.url.appendingPathComponent("nope"), showHidden: false)
        }
    }

    @Test("Default ordering puts folders first, then names in Finder order")
    func defaultOrdering() throws {
        let dir = try TemporaryDirectory()
        try dir.file("b10.txt")
        try dir.file("b2.txt")
        try dir.folder("zeta")
        try dir.file("Alpha.txt")

        let names = try DirectoryLister.contents(of: dir.url, showHidden: false)
            .sorted(using: FileItem.finderOrder)
            .map(\.name)

        #expect(names == ["zeta", "Alpha.txt", "b2.txt", "b10.txt"])
    }
}

@Suite("Folder size")
struct FolderSizeTests {
    @Test("Measures total bytes recursively and counts direct children")
    func measuresRecursively() throws {
        let dir = try TemporaryDirectory()
        try dir.file("a.bin", bytes: 100)
        try dir.file("sub/b.bin", bytes: 50)
        try dir.file("sub/deeper/c.bin", bytes: 25)

        let stats = try FolderSizeCalculator.measure(dir.url)

        #expect(stats.totalBytes == 175)
        #expect(stats.itemCount == 2)
    }

    @Test("Hidden files count toward size but not toward the visible item count")
    func hiddenFilesInStats() throws {
        let dir = try TemporaryDirectory()
        try dir.file(".DS_Store", bytes: 10)
        try dir.file("visible.bin", bytes: 5)

        let stats = try FolderSizeCalculator.measure(dir.url)

        #expect(stats.totalBytes == 15)
        #expect(stats.itemCount == 1)
    }

    @Test("Empty folder is zero bytes and zero items")
    func emptyFolder() throws {
        let dir = try TemporaryDirectory()
        let stats = try FolderSizeCalculator.measure(dir.url)
        #expect(stats == FolderStats(totalBytes: 0, itemCount: 0))
    }
}
