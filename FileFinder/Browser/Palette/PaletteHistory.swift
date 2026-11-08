import Foundation

/// What was picked in the command palette, so frequent and recent picks rank higher.
/// Shared by every window through UserDefaults.
final class PaletteHistory {
    private nonisolated struct Entry: Codable {
        var key: String
        var count: Int
        var lastUsed: Date
    }

    static let defaultsKey = "commandPaletteHistory"
    /// Older picks beyond this are forgotten.
    private static let limit = 100

    private let defaults: UserDefaults
    private let now: () -> Date
    private var entries: [Entry]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        entries = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Item keys, most recently picked first.
    var recentKeys: [String] {
        entries.sorted { $0.lastUsed > $1.lastUsed }.map(\.key)
    }

    func record(_ key: String) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index].count += 1
            entries[index].lastUsed = now()
        } else {
            entries.append(Entry(key: key, count: 1, lastUsed: now()))
        }
        if entries.count > Self.limit {
            entries = Array(entries.sorted { $0.lastUsed > $1.lastUsed }.prefix(Self.limit))
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Added to the match score: 0 for an item never picked.
    func boost(for key: String) -> Int {
        guard let entry = entries.first(where: { $0.key == key }) else { return 0 }
        let age = now().timeIntervalSince(entry.lastUsed)
        let recency = age < 86_400 ? 30 : age < 7 * 86_400 ? 15 : 0
        return 10 + min(entry.count, 10) * 5 + recency
    }
}
