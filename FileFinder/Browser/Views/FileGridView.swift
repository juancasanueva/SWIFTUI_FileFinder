import AppKit
import SwiftUI

/// Card view: real previews, folder size and item count under each folder.
struct FileGridView: View {
    let model: BrowserModel

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.iconSize.cardSide + 48), spacing: 12, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(model.items) { item in
                    FileCard(model: model, item: item, isSelected: model.selection.contains(item.url))
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { model.open([item.url]) }
                        .onTapGesture { model.click(item, modifiers: NSEvent.modifierFlags) }
                        .contextMenu {
                            FileContextMenu(
                                model: model,
                                urls: model.selection.contains(item.url) ? model.selection : [item.url])
                        }
                }
            }
            .padding(16)
        }
        .contentShape(.rect)
        .onTapGesture { model.selection = [] }
        .contextMenu { FileContextMenu(model: model, urls: []) }
    }
}

private struct FileCard: View {
    let model: BrowserModel
    let item: FileItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            FileIconView(item: item, side: model.iconSize.cardSide, preview: true)
                .padding(6)
                .background(isSelected ? Color.secondary.opacity(0.18) : .clear, in: .rect(cornerRadius: 8))

            if model.renamingURL == item.url {
                RenameField(item: item) { model.commitRename(item, to: $0) } onCancel: { model.cancelRename() }
                    .frame(width: model.iconSize.cardSide + 40)
            } else {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
                    .background(isSelected ? Color.accentColor : .clear, in: .rect(cornerRadius: 4))
                    .foregroundStyle(isSelected ? Color.white : .primary)
            }

            Text(model.cardSubtitle(for: item))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .opacity(item.isHidden ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
