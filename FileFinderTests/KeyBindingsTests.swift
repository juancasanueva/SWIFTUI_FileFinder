import Foundation
import SwiftUI
import Testing
@testable import FileFinder

@Suite("Shortcut text")
struct ShortcutTextTests {
    @Test("Reads modifiers and a key, ignoring letter case and modifier order; writes them back in a fixed order")
    func parseAndFormat() throws {
        let shortcut = try #require(Shortcut("Shift+CMD+N"))
        #expect(shortcut.modifiers == [.command, .shift])
        #expect(shortcut.key == "n")
        #expect(shortcut.text == "cmd+shift+n")
        #expect(Shortcut("opt+option+alt+control+ctrl+command+t")?.text == "cmd+ctrl+alt+t")
        #expect(Shortcut("cmd+alt+shift+t")?.text == "cmd+alt+shift+t")
    }

    @Test("Named keys, function keys, punctuation and the plus key")
    func namedKeys() {
        #expect(Shortcut("tab")?.text == "tab")
        #expect(Shortcut("F5")?.text == "f5")
        #expect(Shortcut("cmd+delete")?.text == "cmd+delete")
        #expect(Shortcut("cmd+up")?.text == "cmd+up")
        #expect(Shortcut("cmd+[")?.text == "cmd+[")
        #expect(Shortcut("cmd+shift+.")?.text == "cmd+shift+.")
        #expect(Shortcut("cmd++")?.text == "cmd+plus")
        #expect(Shortcut("cmd+plus")?.text == "cmd+plus")
        #expect(Shortcut("cmd+-")?.text == "cmd+-")
    }

    @Test("Text that isn't a shortcut is rejected", arguments: [
        "", "cmd+", "cmd", "hyper+n", "cmd+nn", "cmd+f13", "cmd+ ", "cmd+shift",
    ])
    func rejected(text: String) {
        #expect(Shortcut(text) == nil)
    }

    @Test("Shown with macOS symbols, modifiers in menu order")
    func display() {
        #expect(Shortcut("cmd+shift+n")?.display == "⇧⌘N")
        #expect(Shortcut("cmd+ctrl+alt+shift+t")?.display == "⌃⌥⇧⌘T")
        #expect(Shortcut("cmd+delete")?.display == "⌘⌫")
        #expect(Shortcut("f5")?.display == "F5")
        #expect(Shortcut("tab")?.display == "⇥")
        #expect(Shortcut("cmd+up")?.display == "⌘↑")
        #expect(Shortcut("cmd+plus")?.display == "⌘+")
    }

    @Test("Becomes the SwiftUI shortcut the menus use")
    func keyboardShortcut() {
        let newFolder = Shortcut("cmd+shift+n")?.keyboardShortcut
        #expect(newFolder?.key == KeyEquivalent("n"))
        #expect(newFolder?.modifiers == [.command, .shift])
        #expect(Shortcut("cmd+delete")?.keyboardShortcut.key == .delete)
        #expect(Shortcut("tab")?.keyboardShortcut.modifiers == [])
        #expect(Shortcut("f5")?.keyboardShortcut.key == KeyEquivalent(Character(Unicode.Scalar(UInt32(NSF5FunctionKey))!)))
        #expect(Shortcut("cmd+plus")?.keyboardShortcut.key == KeyEquivalent("+"))
    }

    @Test("Every action's default is the shortcut the menus had before")
    func defaults() {
        #expect(KeyAction.newFolder.defaultShortcut?.text == "cmd+shift+n")
        #expect(KeyAction.openInTerminal.defaultShortcut?.text == "cmd+alt+shift+t")
        #expect(KeyAction.openInExternalTerminal.defaultShortcut?.text == "cmd+ctrl+alt+t")
        #expect(KeyAction.openInExternalTerminal.defaultShortcut?.display == "⌃⌥⌘T")
        #expect(KeyAction.openInExternalTerminal.menu == .file)
        #expect(KeyAction.openInExternalTerminal.rawValue == "openInExternalTerminal")
        #expect(KeyAction.splitView.defaultShortcut?.text == "cmd+d")
        #expect(KeyAction.goBack.defaultShortcut?.text == "cmd+[")
        #expect(KeyAction.copyToOtherPane.defaultShortcut?.text == "f5")
        #expect(KeyAction.rename.defaultShortcut?.text == "f2")
        #expect(KeyAction.rename.menu == .file)
        #expect(KeyAction.smartClean.defaultShortcut == nil)
        #expect(KeyAction.emptyTrash.defaultShortcut?.text == "cmd+shift+delete")
        #expect(KeyAction.emptyTrash.defaultShortcut?.display == "⇧⌘⌫")
        #expect(KeyAction.emptyTrash.menu == .file)
        #expect(KeyAction.focusLeftPane.defaultShortcut?.text == "cmd+alt+left")
        #expect(KeyAction.focusRightPane.defaultShortcut?.text == "cmd+alt+right")
        #expect(KeyAction.focusLeftPane.defaultShortcut?.display == "⌥⌘←")
        // No two actions share a default.
        let defaults = KeyAction.allCases.compactMap(\.defaultShortcut)
        #expect(Set(defaults).count == defaults.count)
    }
}

@MainActor
@Suite("Keybindings file")
struct KeyBindingStoreTests {
    let dir: TemporaryDirectory
    let file: URL

    init() throws {
        dir = try TemporaryDirectory()
        file = dir.url.appending(path: "config/filefinder/keybindings.json")
    }

    private func written() throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test("The file lives in ~/.config/filefinder, or under XDG_CONFIG_HOME when it is set")
    func location() {
        let home = URL(filePath: "/Users/someone")
        #expect(KeyBindingStore.fileURL(home: home, environment: [:]).path == "/Users/someone/.config/filefinder/keybindings.json")
        #expect(KeyBindingStore.fileURL(home: home, environment: ["XDG_CONFIG_HOME": "/tmp/xdg"]).path == "/tmp/xdg/filefinder/keybindings.json")
        #expect(KeyBindingStore.fileURL(home: home, environment: ["XDG_CONFIG_HOME": ""]).path == "/Users/someone/.config/filefinder/keybindings.json")
    }

    @Test("A missing file is created with every action and its default")
    func createdWithDefaults() throws {
        let store = KeyBindingStore(fileURL: file, watchesFile: false)

        let saved = try written()
        #expect(saved.count == KeyAction.allCases.count)
        #expect(saved["newFolder"] == "cmd+shift+n")
        #expect(saved["smartClean"] == "")
        #expect(store.shortcut(for: .newFolder)?.text == "cmd+shift+n")
    }

    @Test("The file's shortcuts win; missing, unreadable and wrongly typed values keep the default; unknown keys are ignored")
    func merged() throws {
        try write(#"{ "newFolder": "ctrl+n", "splitView": "", "goBack": "cmd+banana", "goForward": 3, "noSuchAction": "cmd+q" }"#)

        let store = KeyBindingStore(fileURL: file, watchesFile: false)

        #expect(store.shortcut(for: .newFolder)?.text == "ctrl+n")
        #expect(store.shortcut(for: .splitView) == nil)
        #expect(store.shortcut(for: .goBack)?.text == "cmd+[")
        #expect(store.shortcut(for: .goForward)?.text == "cmd+]")
        #expect(store.shortcut(for: .open)?.text == "cmd+o")
        // Reading never rewrites the user's file.
        #expect(try String(contentsOf: file, encoding: .utf8).contains("noSuchAction"))
    }

    @Test("A file that isn't valid JSON is set aside and the defaults are written again")
    func damaged() throws {
        try write("{ newFolder: cmd+n")

        let store = KeyBindingStore(fileURL: file, watchesFile: false)

        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(names.contains { $0.hasPrefix("keybindings.json.damaged-") })
        #expect(try written()["newFolder"] == "cmd+shift+n")
        #expect(store.shortcut(for: .newFolder)?.text == "cmd+shift+n")
    }

    @Test("Changing, clearing and resetting a shortcut write the whole file at once")
    func changes() throws {
        let store = KeyBindingStore(fileURL: file, watchesFile: false)

        try store.set(Shortcut("cmd+shift+k"), for: .newFolder)
        #expect(try written()["newFolder"] == "cmd+shift+k")
        #expect(store.shortcut(for: .newFolder)?.text == "cmd+shift+k")

        try store.set(nil, for: .splitView)
        #expect(try written()["splitView"] == "")
        #expect(store.shortcut(for: .splitView) == nil)

        store.reset(.newFolder)
        #expect(try written()["newFolder"] == "cmd+shift+n")

        try store.set(Shortcut("cmd+shift+k"), for: .open)
        store.resetAll()
        #expect(try written() == Dictionary(uniqueKeysWithValues: KeyAction.allCases.map { ($0.rawValue, $0.defaultShortcut?.text ?? "") }))
    }

    @Test("A shortcut another action uses is refused, naming that action")
    func conflict() throws {
        let store = KeyBindingStore(fileURL: file, watchesFile: false)

        #expect(throws: KeyBindingError.alreadyUsed(by: .splitView)) { try store.set(Shortcut("cmd+d"), for: .newFolder) }
        #expect(KeyBindingError.alreadyUsed(by: .splitView).localizedDescription == "Already used by “Split View”.")
        #expect(store.shortcut(for: .newFolder)?.text == "cmd+shift+n")
        // Setting an action to its own shortcut again is fine.
        try store.set(Shortcut("cmd+d"), for: .splitView)
    }

    @Test("Resetting refuses nothing: a default taken by another action is cleared from it")
    func resetTakesBackDefault() throws {
        let store = KeyBindingStore(fileURL: file, watchesFile: false)
        try store.set(Shortcut("ctrl+d"), for: .splitView)
        try store.set(Shortcut("cmd+d"), for: .newFolder)

        store.reset(.splitView)

        #expect(store.shortcut(for: .splitView)?.text == "cmd+d")
        #expect(store.shortcut(for: .newFolder) == nil)
    }

    @Test("A file saved with a mistake while the app runs is left alone; the shortcuts in use stay")
    func brokenEditLeftAlone() async throws {
        let store = KeyBindingStore(fileURL: file, watchesFile: true)
        try write(#"{ "newFolder": "ctrl+alt+n" }"#)
        let deadline = Date.now.addingTimeInterval(5)
        while store.shortcut(for: .newFolder)?.text != "ctrl+alt+n", Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        try write(#"{ "newFolder": "ctrl+alt+n", "#)
        try await Task.sleep(for: .milliseconds(500))

        #expect(try String(contentsOf: file, encoding: .utf8) == #"{ "newFolder": "ctrl+alt+n", "#)
        #expect(store.shortcut(for: .newFolder)?.text == "ctrl+alt+n")
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(!names.contains { $0.contains("damaged") })
    }

    @Test("Damaged files set aside in the same second are all kept")
    func damagedKeptApart() throws {
        try write("not json")
        _ = KeyBindingStore(fileURL: file, watchesFile: false)
        try write("[1, 2]")
        _ = KeyBindingStore(fileURL: file, watchesFile: false)

        let folder = file.deletingLastPathComponent()
        let damaged = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("damaged") }
        let contents = try Set(damaged.map { try String(contentsOf: folder.appending(path: $0), encoding: .utf8) })
        #expect(contents == ["not json", "[1, 2]"])
    }

    @Test("Edits made to the file while the app runs are picked up")
    func externalEdit() async throws {
        let store = KeyBindingStore(fileURL: file, watchesFile: true)
        // An editor saving the file by replacing it.
        let replacement = file.deletingLastPathComponent().appending(path: "keybindings.json.tmp")
        try Data(#"{ "newFolder": "ctrl+alt+n" }"#.utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)

        let deadline = Date.now.addingTimeInterval(5)
        while store.shortcut(for: .newFolder)?.text != "ctrl+alt+n", Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.shortcut(for: .newFolder)?.text == "ctrl+alt+n")
        #expect(store.shortcut(for: .open)?.text == "cmd+o")
    }
}

@Suite("Recording a shortcut")
struct ShortcutRecordingTests {
    @Test("A key press becomes the shortcut it types: unshifted key, its modifiers")
    func fromKeyPress() {
        #expect(Shortcut(keyCode: 45, characters: "n", flags: [.command, .shift])?.text == "cmd+shift+n")
        #expect(Shortcut(keyCode: 47, characters: ".", flags: [.command, .shift, .capsLock])?.text == "cmd+shift+.")
        #expect(Shortcut(keyCode: 96, characters: "\u{F708}", flags: [.function])?.text == "f5")
        #expect(Shortcut(keyCode: 48, characters: "\t", flags: [])?.text == "tab")
        #expect(Shortcut(keyCode: 51, characters: "\u{7F}", flags: [.command])?.text == "cmd+delete")
        #expect(Shortcut(keyCode: 126, characters: "\u{F700}", flags: [.command, .numericPad, .function])?.text == "cmd+up")
        #expect(Shortcut(keyCode: 24, characters: "+", flags: [.command])?.text == "cmd+plus")
        #expect(Shortcut(keyCode: 0, characters: "a", flags: [.control, .option])?.text == "ctrl+alt+a")
    }

    @Test("Settings only records keys that can't be typed as text: a letter needs ⌘, ⌃ or ⌥; F-keys and Tab don't")
    func typesText() {
        #expect(Shortcut("n")?.typesText == true)
        #expect(Shortcut("shift+n")?.typesText == true)
        #expect(Shortcut("delete")?.typesText == true)
        #expect(Shortcut("space")?.typesText == true)
        #expect(Shortcut("cmd+n")?.typesText == false)
        #expect(Shortcut("ctrl+n")?.typesText == false)
        #expect(Shortcut("alt+shift+n")?.typesText == false)
        #expect(Shortcut("f5")?.typesText == false)
        #expect(Shortcut("tab")?.typesText == false)
        #expect(KeyBindingError.typesText.localizedDescription == "Add ⌘, ⌃ or ⌥: that key alone is needed for typing.")
    }

    @Test("Escape alone, and keys that type nothing usable, give no shortcut")
    func nothing() {
        #expect(Shortcut(keyCode: 53, characters: "\u{1B}", flags: []) == nil)
        #expect(Shortcut(keyCode: 0, characters: "", flags: [.command]) == nil)
        #expect(Shortcut(keyCode: 0, characters: nil, flags: [.command]) == nil)
    }
}
