import AppKit
import SwiftUI

/// Card view: real previews, folder size and item count under each folder. Arrow keys move the
/// selection (⇧ extends), ⌘↓ opens it.
struct FileGridView: View {
    let model: BrowserModel
    /// Focus lets arrow keys, Space (Quick Look) and Return (rename) reach the key handlers,
    /// which must sit on the focused view itself.
    @FocusState private var isFocused: Bool
    @State private var width: CGFloat = 0

    private var columnCount: Int {
        FileGridLayout.columns(
            forWidth: width - FileGridLayout.padding * 2,
            minimumItemWidth: FileGridLayout.minimumItemWidth(for: model.iconSize),
            spacing: FileGridLayout.spacing)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                grid(columnCount: columnCount)
            }
            .onChange(of: model.selectionCursor) { _, cursor in
                guard let cursor else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(cursor) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { handleArrow($0) }
        .onChange(of: model.focusRequest) { isFocused = true }
        .contentShape(.rect)
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls, onto: nil)
            return true
        }
        .onTapGesture {
            isFocused = true
            model.selection = []
        }
        .contextMenu { FileContextMenu(model: model, urls: []) }
    }

    private func grid(columnCount: Int) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: FileGridLayout.spacing, alignment: .top), count: columnCount)
        return LazyVGrid(columns: columns, spacing: 16, pinnedViews: [.sectionHeaders]) {
            if model.groups.isEmpty {
                cards(model.items)
            } else {
                // Each section starts a new row, matching `BrowserModel.moveSelection`.
                ForEach(model.groups) { group in
                    Section {
                        cards(group.items)
                    } header: {
                        GroupHeader(group: group)
                            .padding(.vertical, 4)
                            .background(.bar)
                    }
                }
            }
        }
        .padding(FileGridLayout.padding)
    }

    private func cards(_ items: [FileItem]) -> some View {
        ForEach(items) { item in
            FileCard(model: model, item: item, isSelected: model.selection.contains(item.url))
                .id(item.url)
                .contentShape(.rect)
                .onTapGesture(count: 2) { model.open([item.url]) }
                .onTapGesture {
                    isFocused = true
                    model.click(item, modifiers: NSEvent.modifierFlags)
                }
                .contextMenu {
                    FileContextMenu(
                        model: model,
                        urls: model.selection.contains(item.url) ? model.selection : [item.url])
                }
                .onDrag { model.beginDrag(item) }
                .dropDestination(for: URL.self) { urls, _ in
                    model.handleDrop(urls, onto: item)
                    return true
                }
        }
    }

    private func handleArrow(_ press: KeyPress) -> KeyPress.Result {
        guard !model.isTyping else { return .ignored }
        if press.modifiers.contains(.command) {
            // ⌘↓ opens like Finder; ⌘↑ (Enclosing Folder) is handled by the Go menu.
            guard press.key == .downArrow, !model.selection.isEmpty else { return .ignored }
            model.openSelection()
            return .handled
        }
        let move: SelectionMove = switch press.key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        default: .down
        }
        model.moveSelection(move, columns: columnCount, extending: press.modifiers.contains(.shift))
        return .handled
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
                RenameField(item: item) { name in Task { await model.commitRename(item, to: name) } } onCancel: { model.cancelRename() }
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
