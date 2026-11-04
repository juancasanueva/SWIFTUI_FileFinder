import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Group by kind or date added")
struct GroupingTests {
    let dir: TemporaryDirectory
    let defaults: UserDefaults

    init() throws {
        dir = try TemporaryDirectory()
        defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let locale = Locale(identifier: "en_US")
    /// 2026-11-04 15:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_793_804_400)

    private func item(_ name: String, folder: Bool = false, daysAgo: Double? = 0) -> FileItem {
        FileItem(
            url: URL(filePath: "/tmp/\(name)"), name: name, isDirectory: folder, isPackage: false,
            isHidden: false, size: folder ? nil : 1, modificationDate: nil, creationDate: nil, kind: "",
            dateAdded: daysAgo.map { Self.now.addingTimeInterval(-$0 * 86_400) })
    }

    private func titles(_ groups: [ItemGroup]) -> [String] { groups.map(\.title) }

    // MARK: - Grouping rules

    @Test("Group by Kind puts folders first, then each kind in Tidy's order, keeping the sort inside")
    func byKind() {
        let items = [item("z.pdf"), item("Work", folder: true), item("a.jpg"), item("b.pdf"), item("x.zip")]

        let groups = ItemGrouping.groups(items, by: .kind)

        #expect(titles(groups) == ["Folders", "Images", "PDFs", "Other"])
        #expect(groups[2].items.map(\.name) == ["z.pdf", "b.pdf"])
        #expect(groups[0].style == .folders)
        #expect(groups[1].style == .kind(.images))
    }

    @Test("Group by Date Added uses Finder's buckets, newest first")
    func byDateAdded() {
        let items = [
            item("old", daysAgo: 800), item("today", daysAgo: 0.1), item("yesterday", daysAgo: 1),
            item("week", daysAgo: 5), item("month", daysAgo: 20), item("september", daysAgo: 50),
            item("unknown", daysAgo: nil), item("today2", daysAgo: 0.2),
        ]

        let groups = ItemGrouping.groups(items, by: .dateAdded, now: Self.now, calendar: Self.calendar, locale: Self.locale)

        #expect(titles(groups) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "September", "2024", "No Date"])
        #expect(groups[0].items.map(\.name) == ["today", "today2"])
        #expect(groups.allSatisfy { $0.style == .date })
    }

    @Test("Date Added falls back to the creation date")
    func dateFallback() {
        let created = FileItem(
            url: URL(filePath: "/tmp/c"), name: "c", isDirectory: false, isPackage: false, isHidden: false,
            size: 1, modificationDate: nil, creationDate: Self.now, kind: "")
        let groups = ItemGrouping.groups([created], by: .dateAdded, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(titles(groups) == ["Today"])
    }

    @Test("Listings carry the date each item was added")
    func listerReadsDateAdded() throws {
        try dir.file("a.txt")
        let items = try DirectoryLister.contents(of: dir.url, showHidden: false)
        #expect(items.first?.dateAdded != nil)
    }

    // MARK: - Pane

    @Test("Grouping changes only what the pane shows: nothing moves on disk, and it's remembered")
    func paneGroups() async throws {
        try dir.folder("Work")
        try dir.file("b.pdf")
        try dir.file("a.jpg")
        try dir.file("c.pdf")
        let pane = BrowserModel(start: dir.url, defaults: defaults)
        await pane.reload()
        #expect(pane.groups.isEmpty)

        pane.groupBy = .kind

        #expect(titles(pane.groups) == ["Folders", "Images", "PDFs"])
        #expect(pane.items.map(\.name) == ["Work", "a.jpg", "b.pdf", "c.pdf"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.url.path).sorted() == ["Work", "a.jpg", "b.pdf", "c.pdf"])

        pane.sortOrder = [KeyPathComparator(\.name, comparator: .localizedStandard, order: .reverse)]
        #expect(pane.groups[2].items.map(\.name) == ["c.pdf", "b.pdf"])   // sorting applies inside groups

        let next = BrowserModel(start: dir.url, defaults: defaults)
        #expect(next.groupBy == .kind)

        pane.groupBy = .none
        #expect(pane.groups.isEmpty)
    }

    /// Grouped cards in 3 columns, each group on its own rows:
    ///   Images: a b c
    ///           d
    ///   PDFs:   p q
    @Test("Arrow keys follow the grouped card layout")
    func groupedArrows() async throws {
        for name in ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "p.pdf", "q.pdf"] { try dir.file(name) }
        let pane = BrowserModel(start: dir.url, defaults: defaults)
        await pane.reload()
        pane.groupBy = .kind
        func select(_ name: String) { pane.click(pane.items.first { $0.name == name }!, modifiers: []) }
        func selected() -> [String] { pane.selectedItems.map(\.name) }

        select("a.jpg")
        pane.moveSelection(.down, columns: 3, extending: false)
        #expect(selected() == ["d.jpg"])
        pane.moveSelection(.down, columns: 3, extending: false)
        #expect(selected() == ["p.pdf"])         // into the next group's first row

        select("b.jpg")
        pane.moveSelection(.down, columns: 3, extending: false)
        #expect(selected() == ["b.jpg"])         // inside a group, no card below means no move

        select("q.pdf")
        pane.moveSelection(.up, columns: 3, extending: false)
        #expect(selected() == ["d.jpg"])         // the previous group's last row, clamped to its last card
        pane.moveSelection(.up, columns: 3, extending: false)
        #expect(selected() == ["a.jpg"])

        select("d.jpg")
        pane.moveSelection(.right, columns: 3, extending: false)
        #expect(selected() == ["p.pdf"])         // left/right follow the shown order
    }
}
