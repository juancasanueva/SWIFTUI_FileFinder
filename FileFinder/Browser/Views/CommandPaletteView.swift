import AppKit
import SwiftUI

/// The ⌘K palette: a search box over commands and files, driven from the keyboard.
struct CommandPaletteView: View {
    @Bindable var palette: CommandPaletteModel
    /// Return (`false`) or ⌘Return (`true`, show in folder).
    let onActivate: (_ revealing: Bool) -> Void
    let onClose: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands and files", text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                if palette.isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear { isFocused = true }
        .background(PaletteKeyMonitor(
            onMove: palette.moveHighlight(by:), onActivate: onActivate, onClose: onClose))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Palette")
    }

    @ViewBuilder
    private var results: some View {
        if palette.results.isEmpty {
            Text(emptyText)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(palette.results.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, isHighlighted: index == palette.highlightedIndex)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    palette.highlight(index)
                                    onActivate(false)
                                }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: palette.highlightedIndex) {
                    if let id = palette.highlightedItem?.id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var emptyText: String {
        if palette.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Type a command or a file name"
        }
        return palette.isSearching ? "Searching…" : "No matches"
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("↩ Open")
            Text("⌘↩ Show in Folder")
            Text("↑↓ Move")
            Spacer()
            Text("esc Close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if case .command(let command) = item, let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.callout.monospaced())
                    .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(isHighlighted ? .white : .primary)
        .background(isHighlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        switch item {
        case .command:
            Image(systemName: "command")
                .foregroundStyle(isHighlighted ? .white : .secondary)
        case .file(let file):
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
        }
    }

    /// Where a file is, with the home folder written as ~.
    private var subtitle: String? {
        guard case .file(let file) = item else { return nil }
        let folder = file.url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}

/// Up, Down, Return, ⌘Return and Escape for the palette. The search field's editor keeps
/// these keys from SwiftUI, so a local event monitor takes them first.
private struct PaletteKeyMonitor: NSViewRepresentable {
    let onMove: (Int) -> Void
    let onActivate: (Bool) -> Void
    let onClose: () -> Void

    final class Coordinator {
        var monitor: Any?
        var parent: PaletteKeyMonitor?
        deinit { monitor.map(NSEvent.removeMonitor) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let parent = coordinator.parent, event.window === view?.window else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            switch event.keyCode {
            case 126 where modifiers.isEmpty: parent.onMove(-1)
            case 125 where modifiers.isEmpty: parent.onMove(1)
            case 36, 76:
                guard modifiers.isEmpty || modifiers == .command else { return event }
                parent.onActivate(modifiers == .command)
            case 53 where modifiers.isEmpty: parent.onClose()
            default: return event
            }
            return nil
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.monitor.map(NSEvent.removeMonitor)
        coordinator.monitor = nil
    }
}
