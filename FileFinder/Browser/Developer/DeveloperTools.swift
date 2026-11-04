import AppKit
import Foundation

/// A terminal or editor a folder can be opened in.
nonisolated struct DeveloperApp: Identifiable, Hashable, Sendable {
    enum Role: String, Sendable {
        case terminal, editor
    }

    /// How the folder is handed to the app.
    enum Opening: Hashable, Sendable {
        /// Open the folder with the app, like dropping it on its icon.
        case folder
        /// Warp opens a tab through its URL scheme.
        case warpTab
    }

    /// Stable key stored in the preferences.
    let id: String
    let name: String
    let role: Role
    /// Bundle identifiers to look for, in order (for example stable before preview builds).
    let bundleIDs: [String]
    var opening: Opening = .folder

    static let terminals: [DeveloperApp] = [
        DeveloperApp(id: "terminal", name: "Terminal", role: .terminal, bundleIDs: ["com.apple.Terminal"]),
        DeveloperApp(id: "iterm", name: "iTerm", role: .terminal, bundleIDs: ["com.googlecode.iterm2"]),
        DeveloperApp(id: "warp", name: "Warp", role: .terminal, bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"], opening: .warpTab),
        DeveloperApp(id: "ghostty", name: "Ghostty", role: .terminal, bundleIDs: ["com.mitchellh.ghostty"]),
    ]

    static let editors: [DeveloperApp] = [
        DeveloperApp(id: "vscode", name: "VS Code", role: .editor, bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
        DeveloperApp(id: "cursor", name: "Cursor", role: .editor, bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        DeveloperApp(id: "zed", name: "Zed", role: .editor, bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"]),
        DeveloperApp(id: "xcode", name: "Xcode", role: .editor, bundleIDs: ["com.apple.dt.Xcode"]),
        DeveloperApp(id: "sublime", name: "Sublime Text", role: .editor, bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"]),
        DeveloperApp(id: "nova", name: "Nova", role: .editor, bundleIDs: ["com.panic.Nova"]),
        DeveloperApp(id: "bbedit", name: "BBEdit", role: .editor, bundleIDs: ["com.barebones.bbedit"]),
        // JetBrains IDEs
        DeveloperApp(id: "intellij", name: "IntelliJ IDEA", role: .editor, bundleIDs: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        DeveloperApp(id: "webstorm", name: "WebStorm", role: .editor, bundleIDs: ["com.jetbrains.WebStorm"]),
        DeveloperApp(id: "pycharm", name: "PyCharm", role: .editor, bundleIDs: ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        DeveloperApp(id: "goland", name: "GoLand", role: .editor, bundleIDs: ["com.jetbrains.goland"]),
        DeveloperApp(id: "phpstorm", name: "PhpStorm", role: .editor, bundleIDs: ["com.jetbrains.PhpStorm"]),
        DeveloperApp(id: "rubymine", name: "RubyMine", role: .editor, bundleIDs: ["com.jetbrains.rubymine"]),
        DeveloperApp(id: "clion", name: "CLion", role: .editor, bundleIDs: ["com.jetbrains.CLion"]),
        DeveloperApp(id: "rider", name: "Rider", role: .editor, bundleIDs: ["com.jetbrains.rider"]),
        DeveloperApp(id: "rustrover", name: "RustRover", role: .editor, bundleIDs: ["com.jetbrains.rustrover"]),
    ]

    static func all(_ role: Role) -> [DeveloperApp] { role == .terminal ? terminals : editors }
}

nonisolated enum DeveloperToolError: LocalizedError, Equatable {
    case notInstalled(String)
    case noneInstalled(DeveloperApp.Role)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            "“\(name)” isn't installed."
        case .noneInstalled(.terminal):
            "No terminal is installed. Install one of Terminal, iTerm, Warp or Ghostty."
        case .noneInstalled(.editor):
            "No editor is installed. Install one of VS Code, Cursor, Zed, Xcode, Sublime Text, Nova, BBEdit or a JetBrains IDE."
        }
    }
}

/// Finds installed terminals and editors, remembers the picked ones (Settings), and opens
/// folders in them.
final class DeveloperTools {
    enum OpenRequest: Equatable {
        case folder(URL, app: URL)
        case url(URL)
    }

    static let shared = DeveloperTools()

    static func preferenceKey(_ role: DeveloperApp.Role) -> String { "\(role.rawValue)App" }

    private let defaults: UserDefaults
    private let locate: (String) -> URL?
    private let performOpen: (OpenRequest) -> Void

    init(
        defaults: UserDefaults = .standard,
        locate: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        open: @escaping (OpenRequest) -> Void = DeveloperTools.systemOpen
    ) {
        self.defaults = defaults
        self.locate = locate
        self.performOpen = open
    }

    func location(of app: DeveloperApp) -> URL? {
        app.bundleIDs.lazy.compactMap(locate).first
    }

    func installed(_ role: DeveloperApp.Role) -> [DeveloperApp] {
        DeveloperApp.all(role).filter { location(of: $0) != nil }
    }

    /// The picked app while it is installed, otherwise the first installed one.
    func preferred(_ role: DeveloperApp.Role) -> DeveloperApp? {
        let available = installed(role)
        let picked = defaults.string(forKey: Self.preferenceKey(role))
        return available.first { $0.id == picked } ?? available.first
    }

    func setPreferred(_ app: DeveloperApp, for role: DeveloperApp.Role) {
        defaults.set(app.id, forKey: Self.preferenceKey(role))
    }

    func open(_ folder: URL, in app: DeveloperApp) throws {
        guard let appURL = location(of: app) else { throw DeveloperToolError.notInstalled(app.name) }
        switch app.opening {
        case .folder:
            performOpen(.folder(folder, app: appURL))
        case .warpTab:
            var components = URLComponents()
            components.scheme = "warp"
            components.host = "action"
            components.path = "/new_tab"
            components.queryItems = [URLQueryItem(name: "path", value: folder.path)]
            guard let url = components.url else { throw DeveloperToolError.notInstalled(app.name) }
            performOpen(.url(url))
        }
    }

    /// "Open in iTerm", "Open in VS Code", or a generic title when nothing is installed.
    func openTitle(_ role: DeveloperApp.Role) -> String {
        "Open in \(preferred(role)?.name ?? (role == .terminal ? "Terminal" : "Editor"))"
    }

    func openInPreferred(_ folder: URL, role: DeveloperApp.Role) throws {
        guard let app = preferred(role) else { throw DeveloperToolError.noneInstalled(role) }
        try open(folder, in: app)
    }

    static func systemOpen(_ request: OpenRequest) {
        switch request {
        case .folder(let folder, let app):
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .url(let url):
            NSWorkspace.shared.open(url)
        }
    }
}
