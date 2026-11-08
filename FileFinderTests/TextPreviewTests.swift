import AppKit
import Foundation
import Testing
@testable import FileFinder

@Suite("Text preview kinds")
struct TextPreviewKindTests {
    @Test("Markdown, code and config files get a text preview; images and unknown files don't")
    func kinds() {
        #expect(TextPreviewKind(url: URL(filePath: "/p/README.md")) == .markdown)
        #expect(TextPreviewKind(url: URL(filePath: "/p/notes.markdown")) == .markdown)
        #expect(TextPreviewKind(url: URL(filePath: "/p/App.swift")) == .code(.swift))
        #expect(TextPreviewKind(url: URL(filePath: "/p/package.json")) == .code(.json))
        #expect(TextPreviewKind(url: URL(filePath: "/p/ci.yml")) == .code(.yaml))
        #expect(TextPreviewKind(url: URL(filePath: "/p/Dockerfile")) == .code(.shell))
        #expect(TextPreviewKind(url: URL(filePath: "/p/.gitignore")) == .code(.shell))
        #expect(TextPreviewKind(url: URL(filePath: "/p/notes.txt")) == .code(.plain))
        #expect(TextPreviewKind(url: URL(filePath: "/p/photo.png")) == nil)
        #expect(TextPreviewKind(url: URL(filePath: "/p/archive")) == nil)
    }
}

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
    /// The highlighted pieces of `text`, as (kind, text) pairs in order.
    private func tokens(_ text: String, _ language: SyntaxLanguage) -> [(SyntaxToken.Kind, String)] {
        let string = text as NSString
        return SyntaxHighlighter.tokens(in: text, language: language).map { ($0.kind, string.substring(with: $0.range)) }
    }

    @Test("Keywords, strings, numbers and comments in Swift")
    func swift() {
        let found = tokens(#"let x = "a // b" + 42 // note"#, .swift)
        #expect(found.map(\.0) == [.keyword, .string, .number, .comment])
        #expect(found.map(\.1) == ["let", #""a // b""#, "42", "// note"])
    }

    @Test("Block comments and escaped quotes")
    func blockComments() {
        let found = tokens(#"/* one\ntwo */ var s = "say \"hi\"""#, .cLike)
        #expect(found.map(\.1) == [#"/* one\ntwo */"#, "var", #""say \"hi\"""#])
    }

    @Test("JSON keys differ from string values")
    func jsonKeys() {
        let found = tokens(#"{"name": "app", "private": true}"#, .json)
        #expect(found.map(\.0) == [.key, .string, .key, .keyword])
    }

    @Test("YAML keys at the start of a line, and # comments only after a space")
    func yaml() {
        let found = tokens("name: build # ci\n- run: make\nurl: a#b", .yaml)
        #expect(found.map(\.1) == ["name", "# ci", "run", "url"])
        #expect(found.map(\.0) == [.key, .comment, .key, .key])
    }

    @Test("Python triple-quoted strings span lines")
    func pythonTripleQuotes() {
        let found = tokens("def f():\n    \"\"\"doc\nmore\"\"\"\n    return 1", .python)
        #expect(found.map(\.1) == ["def", "\"\"\"doc\nmore\"\"\"", "return", "1"])
    }

    @Test("Plain text has nothing to highlight")
    func plain() {
        #expect(tokens("let x = 1 // not code", .plain).isEmpty)
    }
}

@Suite("Markdown blocks")
struct MarkdownBlocksTests {
    @Test("Headings, paragraphs, rules and quotes")
    func basics() {
        let blocks = MarkdownBlocks.parse("""
            # Title ##
            First line
            second line

            ---
            > quoted
            > more
            Setext
            ======
            """)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("First line second line"),
            .rule,
            .quote("quoted more"),
            .heading(level: 1, text: "Setext"),
        ])
    }

    @Test("Lists keep their markers, depth and task boxes")
    func lists() {
        let blocks = MarkdownBlocks.parse("""
            - one
              - nested
            1. first
            - [ ] todo
            - [x] done
            """)
        #expect(blocks == [
            .listItem(marker: "•", text: "one", depth: 0),
            .listItem(marker: "•", text: "nested", depth: 1),
            .listItem(marker: "1.", text: "first", depth: 0),
            .listItem(marker: "☐", text: "todo", depth: 0),
            .listItem(marker: "☑", text: "done", depth: 0),
        ])
    }

    @Test("Fenced code keeps its text and language")
    func code() {
        let blocks = MarkdownBlocks.parse("""
            ```swift
            let a = 1

            print(a)
            ```
            after
            """)
        #expect(blocks == [.code(language: "swift", text: "let a = 1\n\nprint(a)"), .paragraph("after")])
    }

    @Test("Tables become rows of cells, without the separator line")
    func table() {
        let blocks = MarkdownBlocks.parse("""
            | Key | Action |
            | --- | :---: |
            | ⌘K | Palette |
            """)
        #expect(blocks == [.table([["Key", "Action"], ["⌘K", "Palette"]])])
    }
}

@MainActor
@Suite("Markdown editing")
struct TextDocumentTests {
    let dir: TemporaryDirectory

    init() throws {
        dir = try TemporaryDirectory()
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Edits mark the file unsaved; Save writes them and clears the mark")
    func saves() throws {
        let url = try dir.file("notes.md")
        try write("# Old", to: url)
        let document = try TextDocument(url: url)
        #expect(document.text == "# Old")
        #expect(!document.isDirty)

        document.text = "# New"
        #expect(document.isDirty)
        #expect(document.save())
        #expect(!document.isDirty)
        #expect(try read(url) == "# New")
    }

    @Test("A file changed on disk is never overwritten silently: Save stops, Overwrite or Reload decides")
    func conflict() throws {
        let url = try dir.file("notes.md")
        try write("mine", to: url)
        let document = try TextDocument(url: url)
        document.text = "my edit"
        try write("theirs", to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)

        #expect(!document.save())
        #expect(document.hasConflict)
        #expect(try read(url) == "theirs")

        document.overwrite()
        #expect(try read(url) == "my edit")
        #expect(!document.hasConflict)

        document.text = "again"
        try write("newer", to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        #expect(!document.save())
        document.reload()
        #expect(document.text == "newer")
        #expect(!document.isDirty)
        #expect(!document.hasConflict)
    }

    @Test("Selecting another file saves unsaved edits; ⌘S is offered only while there are some")
    func paneSavesOnLeave() throws {
        let first = try dir.file("a.md")
        let second = try dir.file("b.md")
        try write("A", to: first)
        try write("B", to: second)
        let actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let model = BrowserModel(start: dir.url, actions: actions, defaults: defaults)

        model.openDocument(first)
        let runner = KeyActionRunner(browser: model, window: nil)
        #expect(!runner.canPerform(.save))
        model.document?.text = "A edited"
        #expect(KeyActionRunner(browser: model, window: nil).canPerform(.save))

        model.openDocument(second)
        #expect(try read(first) == "A edited")
        #expect(model.document?.url == second.canonical)

        model.document?.text = "B edited"
        model.closeDocument()
        #expect(try read(second) == "B edited")
        #expect(model.document == nil)
    }

    private func makePane() throws -> BrowserModel {
        let actions = FileActions(
            clipboard: FileClipboard(pasteboard: NSPasteboard(name: .init("FileFinderTests-\(UUID())"))))
        actions.undoManager = UndoManager()
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        return BrowserModel(
            start: dir.url, actions: actions, defaults: defaults,
            recoveryFolder: dir.url.appending(path: "Recovered", directoryHint: .isDirectory))
    }

    @Test("Leaving a file that changed on disk keeps your edits in a copy next to it, and says so")
    func leaveWithConflictKeepsCopy() throws {
        let url = try dir.file("notes.md")
        let other = try dir.file("other.md")
        try write("mine", to: url)
        let model = try makePane()
        model.selection = [url.canonical]
        model.openDocument(url)
        model.document?.text = "my edit"
        try write("theirs, longer", to: url)

        model.selection = [other.canonical]
        #expect(try read(url) == "theirs, longer")
        #expect(try read(dir.url.appending(path: "notes (unsaved edits).md")) == "my edit")
        #expect(model.alertMessage?.contains("notes (unsaved edits).md") == true)
        #expect(model.document == nil)
    }

    @Test("Edits that can't be written next to their file go to the recovery folder")
    func unwritableKeepsDocument() throws {
        let folder = try dir.folder("locked")
        let url = folder.appending(path: "notes.md")
        try write("mine", to: url)
        let model = try makePane()
        model.openDocument(url)
        model.document?.text = "my edit"
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        #expect(model.closeDocument())
        #expect(model.document == nil)
        #expect(try read(url) == "mine")
        #expect(try read(dir.url.appending(path: "Recovered/notes (unsaved edits).md")) == "my edit")
        #expect(model.alertMessage?.contains("Recovered") == true)
    }

    @Test("Renaming a file with unsaved edits saves them first")
    func renameSavesFirst() async throws {
        let url = try dir.file("notes.md")
        try write("old", to: url)
        let model = try makePane()
        await model.reload()
        let item = try #require(model.items.first { $0.url == url.canonical })
        model.selection = [item.url]
        model.openDocument(url)
        model.document?.text = "edited"

        model.beginRename()
        await model.commitRename(item, to: "renamed.md")
        #expect(try read(dir.url.appending(path: "renamed.md")) == "edited")
        #expect(model.alertMessage == nil)
    }

    @Test("Quitting saves unsaved edits")
    func quitSaves() throws {
        let url = try dir.file("notes.md")
        try write("old", to: url)
        let model = try makePane()
        model.openDocument(url)
        model.document?.text = "edited"

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        #expect(try read(url) == "edited")
    }
}
