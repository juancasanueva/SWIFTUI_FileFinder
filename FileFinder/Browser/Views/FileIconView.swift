import AppKit
import QuickLookThumbnailing
import SwiftUI

/// The item's icon, upgraded to a real Quick Look preview (document page, photo, video frame)
/// when `preview` is on.
struct FileIconView: View {
    @Environment(\.displayScale) private var displayScale
    let item: FileItem
    let side: CGFloat
    var preview = false
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: item.url.path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .task(id: "\(item.url.path)|\(side)|\(preview)") {
                guard preview, !item.isDirectory else { thumbnail = nil; return }
                thumbnail = await Self.thumbnail(for: item.url, side: side, scale: displayScale)
            }
            .accessibilityHidden(true)
    }

    private static func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
