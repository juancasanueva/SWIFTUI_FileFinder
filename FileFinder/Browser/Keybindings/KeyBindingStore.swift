import Foundation
import Observation

nonisolated enum KeyBindingError: LocalizedError, Equatable {
    case alreadyUsed(by: KeyAction)

    var errorDescription: String? {
        switch self {
        case .alreadyUsed(let action): "Already used by “\(action.title)”."
        }
    }
}

/// The menu shortcuts, read from keybindings.json in the user's config folder and written
/// back when they are changed in Settings. Edits made to the file while the app runs are
/// picked up.
@Observable
final class KeyBindingStore {
    static let shared = KeyBindingStore(
        fileURL: fileURL(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment))

    /// `$XDG_CONFIG_HOME/filefinder/keybindings.json`, or `~/.config/filefinder/keybindings.json`.
    nonisolated static func fileURL(home: URL, environment: [String: String]) -> URL {
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? home.appending(path: ".config", directoryHint: .isDirectory)
        return config.appending(path: "filefinder/keybindings.json")
    }

    let fileURL: URL
    /// Every action's shortcut; an action missing here has none.
    private(set) var shortcuts: [KeyAction: Shortcut] = [:]
    @ObservationIgnored private var folderWatcher: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var fileWatcher: (any DispatchSourceFileSystemObject)?

    init(fileURL: URL, watchesFile: Bool = true) {
        self.fileURL = fileURL
        load()
        if watchesFile { watch() }
    }

    isolated deinit {
        folderWatcher?.cancel()
        fileWatcher?.cancel()
    }

    func shortcut(for action: KeyAction) -> Shortcut? {
        shortcuts[action]
    }

    /// Gives `action` `shortcut` (`nil` for none) and saves; refuses one another action uses.
    func set(_ shortcut: Shortcut?, for action: KeyAction) throws(KeyBindingError) {
        if let shortcut, let other = shortcuts.first(where: { $0.key != action && $0.value == shortcut })?.key {
            throw .alreadyUsed(by: other)
        }
        shortcuts[action] = shortcut
        save()
    }

    /// Gives `action` its default back, taking it from any other action that has it.
    func reset(_ action: KeyAction) {
        if let shortcut = action.defaultShortcut {
            for (other, used) in shortcuts where other != action && used == shortcut { shortcuts[other] = nil }
        }
        shortcuts[action] = action.defaultShortcut
        save()
    }

    func resetAll() {
        shortcuts = Self.defaults
        save()
    }

    private static var defaults: [KeyAction: Shortcut] {
        Dictionary(uniqueKeysWithValues: KeyAction.allCases.compactMap { action in action.defaultShortcut.map { (action, $0) } })
    }

    // MARK: File

    /// Reads the file: missing → created with the defaults; not a JSON object → set aside and
    /// written again; any action it doesn't set readably keeps its default.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            shortcuts = Self.defaults
            return save()
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Keep the damaged file for recovery instead of overwriting it.
            let stamp = Int(Date.now.timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent().appending(path: "\(fileURL.lastPathComponent).damaged-\(stamp)")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            shortcuts = Self.defaults
            return save()
        }
        var read = Self.defaults
        for action in KeyAction.allCases {
            guard let text = object[action.rawValue] as? String else { continue }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                read[action] = nil
            } else if let shortcut = Shortcut(text.trimmingCharacters(in: .whitespaces)) {
                read[action] = shortcut
            }
        }
        if read != shortcuts { shortcuts = read }
    }

    private func save() {
        let object = Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { ($0.rawValue, shortcuts[$0]?.text ?? "") })
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(object).write(to: fileURL, options: .atomic)
        } catch {
            // The shortcuts in use stay; the next change retries.
        }
    }

    /// Watches the file and its folder: some editors write the file in place, others replace
    /// it (only the folder sees that, and the new file needs watching again).
    private func watch() {
        folderWatcher = Self.source(fileURL.deletingLastPathComponent(), events: [.write]) { [weak self] _ in
            self?.load()
            self?.watchFile()
        }
        watchFile()
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = Self.source(fileURL, events: [.write, .extend, .delete, .rename]) { [weak self] events in
            self?.load()
            if !events.isDisjoint(with: [.delete, .rename]) { self?.watchFile() }
        }
    }

    private static func source(
        _ url: URL, events: DispatchSource.FileSystemEvent, handler: @escaping @MainActor (DispatchSource.FileSystemEvent) -> Void
    ) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: .main)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            let data = source.data
            MainActor.assumeIsolated { handler(data) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
