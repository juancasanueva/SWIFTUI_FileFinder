import Foundation

/// How a pane groups its items. Grouping only changes what is shown; nothing moves on disk.
nonisolated enum GroupBy: String, CaseIterable, Sendable {
    case none, kind, dateAdded

    var title: String {
        switch self {
        case .none: "None"
        case .kind: "Kind"
        case .dateAdded: "Date Added"
        }
    }
}

/// One group of a grouped pane, with its items in the pane's sort order.
nonisolated struct ItemGroup: Identifiable, Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case folders
        case kind(FileKind)
        case date
    }

    let id: String
    let title: String
    let style: Style
    let items: [FileItem]
}

nonisolated enum ItemGrouping {
    /// Splits already-sorted `items` into groups in display order, keeping the order inside each.
    static func groups(
        _ items: [FileItem], by groupBy: GroupBy, now: Date = .now,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> [ItemGroup] {
        switch groupBy {
        case .none:
            return []
        case .kind:
            return byKind(items)
        case .dateAdded:
            return byDateAdded(items, now: now, calendar: calendar, locale: locale)
        }
    }

    /// Folders first, then Tidy's kinds in order.
    private static func byKind(_ items: [FileItem]) -> [ItemGroup] {
        let folders = items.filter(\.isNavigable)
        let files = Dictionary(grouping: items.filter { !$0.isNavigable }) { FileKind.of($0.url) }
        var groups: [ItemGroup] = []
        if !folders.isEmpty { groups.append(ItemGroup(id: "folders", title: "Folders", style: .folders, items: folders)) }
        for kind in FileKind.allCases {
            guard let members = files[kind] else { continue }
            groups.append(ItemGroup(id: "kind.\(kind.rawValue)", title: kind.folderName, style: .kind(kind), items: members))
        }
        return groups
    }

    private enum DateBucket: Hashable, Comparable {
        // Declared newest first, so the synthesized order is the display order.
        case today, yesterday, previous7Days, previous30Days
        case month(Int)   // earlier this year, newest month first (negated month number)
        case year(Int)    // earlier years, newest first (negated year)
        case unknown
    }

    /// Today, Yesterday, Previous 7 Days, Previous 30 Days, then months of this year, then
    /// years; items with no date last. Falls back to the creation date.
    private static func byDateAdded(_ items: [FileItem], now: Date, calendar: Calendar, locale: Locale) -> [ItemGroup] {
        let startOfToday = calendar.startOfDay(for: now)
        func daysBack(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: startOfToday) ?? startOfToday }
        let thisYear = calendar.component(.year, from: now)

        func bucket(_ item: FileItem) -> DateBucket {
            guard let date = item.dateAdded ?? item.creationDate else { return .unknown }
            if date >= startOfToday { return .today }
            if date >= daysBack(1) { return .yesterday }
            if date >= daysBack(7) { return .previous7Days }
            if date >= daysBack(30) { return .previous30Days }
            let year = calendar.component(.year, from: date)
            if year == thisYear { return .month(-calendar.component(.month, from: date)) }
            return .year(-year)
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        let monthNames = formatter.standaloneMonthSymbols ?? []

        func title(_ bucket: DateBucket) -> (id: String, title: String) {
            switch bucket {
            case .today: ("date.today", "Today")
            case .yesterday: ("date.yesterday", "Yesterday")
            case .previous7Days: ("date.7", "Previous 7 Days")
            case .previous30Days: ("date.30", "Previous 30 Days")
            case .month(let negated):
                ("date.month.\(-negated)", monthNames.indices.contains(-negated - 1) ? monthNames[-negated - 1] : "\(-negated)")
            case .year(let negated): ("date.year.\(-negated)", String(-negated))
            case .unknown: ("date.none", "No Date")
            }
        }

        let grouped = Dictionary(grouping: items, by: bucket)
        return grouped.keys.sorted().map { key in
            let (id, name) = title(key)
            // Dictionary(grouping:) keeps each group's items in their original (sorted) order.
            return ItemGroup(id: id, title: name, style: .date, items: grouped[key] ?? [])
        }
    }
}
