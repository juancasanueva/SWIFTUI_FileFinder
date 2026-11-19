import Foundation

nonisolated struct SidebarItem: Identifiable, Hashable, Sendable {
    let title: String
    let systemImage: String
    let url: URL
    /// A pendrive, disk image or network share: shown with an eject button, as in Finder.
    let isEjectable: Bool
    var id: URL { url }

    init(title: String, systemImage: String, url: URL, isEjectable: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.url = url.canonical
        self.isEjectable = isEjectable
    }
}

/// Builds the sidebar sections: Favorites, Locations and Trash.
nonisolated enum SidebarLocations {
    /// Applications first, as in Finder, then the user's Desktop, Documents and Downloads.
    static func favorites(home: URL) -> [SidebarItem] {
        [
            SidebarItem(title: "Applications", systemImage: "app.dashed", url: URL(filePath: "/Applications", directoryHint: .isDirectory)),
            SidebarItem(title: "Desktop", systemImage: "menubar.dock.rectangle", url: home.appending(path: "Desktop")),
            SidebarItem(title: "Documents", systemImage: "doc", url: home.appending(path: "Documents")),
            SidebarItem(title: "Downloads", systemImage: "arrow.down.circle", url: home.appending(path: "Downloads")),
        ]
    }

    static func locations(
        home: URL, volumes: [URL], isEjectable: (URL) -> Bool = SidebarLocations.isEjectable
    ) -> [SidebarItem] {
        var items: [SidebarItem] = []
        let fileManager = FileManager.default

        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        if fileManager.fileExists(atPath: iCloud.path) {
            items.append(SidebarItem(title: "iCloud Drive", systemImage: "icloud", url: iCloud))
        }

        let cloudStorage = home.appending(path: "Library/CloudStorage")
        let providers = (try? fileManager.contentsOfDirectory(
            at: cloudStorage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for provider in providers.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            items.append(SidebarItem(
                title: providerTitle(provider.lastPathComponent), systemImage: "externaldrive.connected.to.line.below",
                url: provider))
        }

        items.append(SidebarItem(title: home.lastPathComponent, systemImage: "house", url: home))

        let root = URL(filePath: "/", directoryHint: .isDirectory)
        let rootName = (try? root.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
            ?? "Macintosh HD"
        items.append(SidebarItem(title: rootName, systemImage: "internaldrive", url: root))

        for volume in volumes where volume.path != "/" {
            let name = (try? volume.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
                ?? volume.lastPathComponent
            items.append(SidebarItem(
                title: name, systemImage: "externaldrive", url: volume, isEjectable: isEjectable(volume)))
        }
        return items
    }

    static func trash(home: URL) -> SidebarItem {
        SidebarItem(title: "Trash", systemImage: "trash", url: home.appending(path: ".Trash"))
    }

    static func mountedVolumes() -> [URL] {
        FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeLocalizedNameKey], options: [.skipHiddenVolumes]) ?? []
    }

    /// External and removable drives, disk images and network shares, as Finder decides. External
    /// USB SSDs report neither ejectable nor removable, only that they sit off the internal bus.
    static func isEjectable(_ volume: URL) -> Bool {
        guard volume.path != "/", let values = try? volume.resourceValues(
            forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsLocalKey])
        else { return false }
        return values.volumeIsEjectable == true || values.volumeIsRemovable == true
            || values.volumeIsInternal == false || values.volumeIsLocal == false
    }

    /// Whether `folder` is `volume` itself or somewhere inside it.
    static func folder(_ folder: URL, isOn volume: URL) -> Bool {
        let folderPath = folder.standardizedFileURL.path(percentEncoded: false)
        var volumePath = volume.standardizedFileURL.path(percentEncoded: false)
        if !volumePath.hasSuffix("/") { volumePath += "/" }
        return (folderPath + "/").hasPrefix(volumePath)
    }

    /// "GoogleDrive-me@example.com" → "Google Drive", "OneDrive-Personal" → "One Drive".
    static func providerTitle(_ folderName: String) -> String {
        let stem = folderName.split(separator: "-").first.map(String.init) ?? folderName
        var title = ""
        for (index, character) in stem.enumerated() {
            if index > 0, character.isUppercase, let last = title.last, last.isLowercase { title.append(" ") }
            title.append(character)
        }
        return title
    }
}
