import Foundation
import Testing
@testable import FileFinder

@Suite("Folder preview")
struct FolderPreviewLoaderTests {
    @Test("Shows contents two levels deep, folders first, hidden items excluded")
    func twoLevels() throws {
        let dir = try TemporaryDirectory()
        try dir.file("notes.txt")
        try dir.file(".secret")
        try dir.file("Photos/b.jpg")
        try dir.file("Photos/a.jpg")
        try dir.file("Photos/.hidden")
        try dir.file("Photos/Trips/deeper/x.jpg")   // third level: not shown

        let preview = try FolderPreviewLoader.load(dir.url)

        #expect(preview.entries.map(\.item.name) == ["Photos", "notes.txt"])
        let photos = try #require(preview.entries.first)
        #expect(photos.children.map(\.name) == ["Trips", "a.jpg", "b.jpg"])
        #expect(photos.moreChildren == 0)
        #expect(preview.entries[1].children.isEmpty)
        #expect(preview.moreEntries == 0)
    }

    @Test("Caps the number of entries per level and counts the rest")
    func limits() throws {
        let dir = try TemporaryDirectory()
        for index in 1...5 { try dir.file("f\(index).txt") }
        for index in 1...4 { try dir.file("Box/i\(index)") }

        let preview = try FolderPreviewLoader.load(dir.url, limit: 3, childLimit: 2)

        #expect(preview.entries.map(\.item.name) == ["Box", "f1.txt", "f2.txt"])
        #expect(preview.moreEntries == 3)
        #expect(preview.entries[0].children.map(\.name) == ["i1", "i2"])
        #expect(preview.entries[0].moreChildren == 2)
    }

    @Test("An unreadable sub-folder shows no children instead of failing the preview")
    func unreadableChild() throws {
        let dir = try TemporaryDirectory()
        let locked = try dir.folder("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let preview = try FolderPreviewLoader.load(dir.url)

        #expect(preview.entries.map(\.item.name) == ["Locked"])
        #expect(preview.entries[0].children.isEmpty)
    }

    @Test("A missing folder throws")
    func missingFolder() throws {
        let dir = try TemporaryDirectory()
        #expect(throws: (any Error).self) { try FolderPreviewLoader.load(dir.url.appending(path: "nope")) }
    }
}

@MainActor
@Suite("Preview subject")
struct PreviewSubjectTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    @Test("Nothing selected previews the current folder")
    func nothingSelected() async throws {
        try dir.file("a.txt")
        let model = BrowserModel(start: dir.url, defaults: defaults)
        await model.reload()

        guard case .currentFolder(let url, let itemCount) = model.previewSubject else {
            Issue.record("Expected the current folder, got \(model.previewSubject)")
            return
        }
        #expect(url == dir.url.canonical)
        #expect(itemCount == 1)
    }

    @Test("One selected item previews that item")
    func oneSelected() async throws {
        let file = try dir.file("a.txt", bytes: 4)
        let model = BrowserModel(start: dir.url, defaults: defaults)
        await model.reload()
        model.selection = [file.canonical]

        guard case .item(let item) = model.previewSubject else {
            Issue.record("Expected one item, got \(model.previewSubject)")
            return
        }
        #expect(item.name == "a.txt")
    }

    @Test("Several selected items show their count and total size, folders included once measured")
    func severalSelected() async throws {
        let a = try dir.file("a.bin", bytes: 10)
        let b = try dir.file("b.bin", bytes: 20)
        let folder = try dir.folder("Box")
        try dir.file("Box/c.bin", bytes: 5)
        let model = BrowserModel(start: dir.url, defaults: defaults)
        await model.reload()
        await model.measureFolders()
        model.selection = [a.canonical, b.canonical, folder.canonical]

        guard case .multiple(let count, let totalBytes) = model.previewSubject else {
            Issue.record("Expected several items, got \(model.previewSubject)")
            return
        }
        #expect(count == 3)
        #expect(totalBytes == 35)
    }

    @Test("The preview pane setting persists")
    func previewPersists() throws {
        let model = BrowserModel(start: dir.url, defaults: defaults)
        #expect(!model.showPreview)
        model.showPreview = true
        #expect(BrowserModel(start: dir.url, defaults: defaults).showPreview)
    }
}
