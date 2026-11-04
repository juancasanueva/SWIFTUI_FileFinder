import AppKit
import SwiftUI

extension FileKind {
    /// Each kind folder's own color, shared by the Tidy preview and Group by Kind.
    var color: Color {
        switch self {
        case .videos: .purple
        case .images: .green
        case .pdfs: .red
        case .documents: .blue
        case .installers: .orange
        case .other: .gray
        }
    }
}

/// The header of one group in a grouped pane: a folder in the group's own color for kinds.
struct GroupHeader: View {
    let group: ItemGroup

    var body: some View {
        HStack(spacing: 6) {
            switch group.style {
            case .folders: Image(systemName: "folder.fill").foregroundStyle(.teal)
            case .kind(let kind): Image(systemName: "folder.fill").foregroundStyle(kind.color)
            case .date: Image(systemName: "calendar").foregroundStyle(.secondary)
            }
            Text(group.title).fontWeight(.semibold)
            Text("\(group.items.count)").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// The Tidy preview: which files go into which kind folder, before anything moves.
struct TidySheet: View {
    let plan: TidyPlan
    let onTidy: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tidy “\(FileManager.default.displayName(atPath: plan.folder.path))”")
                .font(.headline)
            if plan.isEmpty {
                Text("There are no loose files here. Folders and hidden files are never moved.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(summary).foregroundStyle(.secondary)
                List {
                    ForEach(plan.groups) { group in
                        Section {
                            ForEach(group.files, id: \.self) { file in
                                HStack(spacing: 6) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                    Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        } header: {
                            header(group)
                        }
                    }
                }
                .frame(height: 300)
            }
            if !plan.blockedKinds.isEmpty {
                Text(blockedNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !plan.isEmpty {
                    Text("Undo (⌘Z) puts everything back.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if plan.isEmpty {
                    Button("OK", action: onCancel).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    Button("Tidy", action: onTidy).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func header(_ group: TidyPlan.Group) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").foregroundStyle(group.kind.color)
            Text(group.folder.lastPathComponent).fontWeight(.semibold)
            Text(group.folderExists ? "existing folder" : "new folder").foregroundStyle(.secondary)
            Spacer()
            Text("\(group.files.count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let files = plan.fileCount == 1 ? "1 file moves" : "\(plan.fileCount) files move"
        let folders = plan.groups.count == 1 ? "1 folder" : "\(plan.groups.count) folders"
        return "\(files) into \(folders) by kind. Folders and hidden files stay where they are."
    }

    private var blockedNote: String {
        let names = plan.blockedKinds.map { "“\($0.folderName)”" }.joined(separator: ", ")
        return "Left as they are: a file is already named \(names), so those files have no folder to go into."
    }
}
