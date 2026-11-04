import Foundation
import UniformTypeIdentifiers

/// The kind folders Tidy sorts loose files into, in display order.
nonisolated enum FileKind: String, CaseIterable, Sendable {
    case videos, images, pdfs, documents, installers, other

    var folderName: String {
        switch self {
        case .videos: "Videos"
        case .images: "Images"
        case .pdfs: "PDFs"
        case .documents: "Documents"
        case .installers: "Installers"
        case .other: "Other"
        }
    }

    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]
    private static let documentExtensions: Set<String> = [
        "doc", "docx", "odt", "rtf", "rtfd", "txt", "md", "markdown", "tex", "pages", "epub",
        "xls", "xlsx", "ods", "csv", "numbers", "ppt", "pptx", "odp", "key",
    ]

    /// Classifies by file name extension. Source code, archives and audio count as Other.
    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        if installerExtensions.contains(ext) { return .installers }
        if documentExtensions.contains(ext) { return .documents }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdfs }
        if type.conforms(to: .movie) { return .videos }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) { return .documents }
        return .other
    }
}

/// What Tidy will do to one folder: which loose files go into which kind folder.
nonisolated struct TidyPlan: Equatable, Sendable {
    struct Group: Identifiable, Equatable, Sendable {
        let kind: FileKind
        /// `<folder>/<Kind>`, in the real letter case when the folder already exists.
        let folder: URL
        let folderExists: Bool
        let files: [URL]
        var id: FileKind { kind }
    }

    let folder: URL
    /// Non-empty groups in `FileKind` order.
    let groups: [Group]
    /// Kinds left out because a file already has their folder's name.
    let blockedKinds: [FileKind]

    var fileCount: Int { groups.reduce(0) { $0 + $1.files.count } }
    var isEmpty: Bool { groups.isEmpty }

    /// Extensions of files still being downloaded; moving them would break the download.
    private static let inProgressExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    /// Visible non-folder items directly in `folder`; packages such as apps count as files.
    static func looseFiles(in folder: URL) throws -> [FileItem] {
        try DirectoryLister.contents(of: folder, showHidden: false).filter {
            !$0.isNavigable && !$0.isHidden && !inProgressExtensions.contains($0.url.pathExtension.lowercased())
        }
    }

    static func make(for folder: URL) throws -> TidyPlan {
        let folder = folder.canonical
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let byKind = Dictionary(grouping: try looseFiles(in: folder)) { FileKind.of($0.url) }

        var groups: [Group] = []
        var blocked: [FileKind] = []
        for kind in FileKind.allCases {
            guard let files = byKind[kind], !files.isEmpty else { continue }
            // Prefer the exact name: on a case-sensitive volume "Images" and "images" differ.
            let existingName = names.contains(kind.folderName)
                ? kind.folderName
                : names.first { $0.lowercased() == kind.folderName.lowercased() }
            let target = folder.appendingPathComponent(existingName ?? kind.folderName)
            var isDirectory: ObjCBool = false
            let exists = existingName != nil && FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
            if exists, !isDirectory.boolValue {
                blocked.append(kind)
                continue
            }
            let sorted = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            groups.append(Group(kind: kind, folder: target.canonical, folderExists: exists, files: sorted.map(\.url)))
        }
        return TidyPlan(folder: folder, groups: groups, blockedKinds: blocked)
    }
}
