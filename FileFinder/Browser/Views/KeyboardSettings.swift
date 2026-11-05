import AppKit
import SwiftUI

/// Settings ▸ Keyboard: every menu command's shortcut, changed by recording a new one.
/// Changes are written to keybindings.json at once.
struct KeyboardSettings: View {
    let keys: KeyBindingStore
    @State private var recording: KeyAction?
    @State private var message: (action: KeyAction, text: String)?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(KeyAction.Menu.allCases, id: \.self) { menu in
                    Section(menu.rawValue) {
                        ForEach(KeyAction.allCases.filter { $0.menu == menu }) { row($0) }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Open keybindings.json") { NSWorkspace.shared.open(keys.fileURL) }
                Spacer()
                Button("Restore Defaults") {
                    recording = nil
                    message = nil
                    keys.resetAll()
                }
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .background(ShortcutRecorder(recording: $recording) { action, shortcut in
            record(shortcut, for: action)
        })
    }

    private func row(_ action: KeyAction) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Button(label(for: action)) {
                    message = nil
                    recording = recording == action ? nil : action
                }
                .frame(minWidth: 120)
                .accessibilityLabel("Shortcut for \(action.title)")
                .accessibilityValue(keys.shortcut(for: action)?.display ?? "None")
                Button("Clear", systemImage: "xmark.circle.fill") {
                    message = nil
                    try? keys.set(nil, for: action)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(keys.shortcut(for: action) == nil)
                .help("No shortcut")
                Button("Reset", systemImage: "arrow.uturn.backward") {
                    message = nil
                    keys.reset(action)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(keys.shortcut(for: action) == action.defaultShortcut)
                .help("Reset to \(action.defaultShortcut?.display ?? "no shortcut")")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                if let message, message.action == action {
                    Text(message.text)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func label(for action: KeyAction) -> String {
        if recording == action { return "Type Shortcut…" }
        return keys.shortcut(for: action)?.display ?? "None"
    }

    private func record(_ shortcut: Shortcut, for action: KeyAction) {
        do {
            if shortcut.typesText { throw KeyBindingError.typesText }
            try keys.set(shortcut, for: action)
            message = nil
        } catch {
            message = (action, error.localizedDescription)
        }
    }
}

/// While `recording` names an action, takes the next key press in this window as its new
/// shortcut instead of letting it act: Escape cancels, a press that types nothing usable is
/// ignored.
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var recording: KeyAction?
    let onRecord: (KeyAction, Shortcut) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            let coordinator = context.coordinator
            guard let action = coordinator.recording?(), event.window === view?.window else { return event }
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .control, .option, .shift]) {
                coordinator.stop?()
                return nil
            }
            let characters = event.characters(byApplyingModifiers: [])
            guard let shortcut = Shortcut(keyCode: event.keyCode, characters: characters, flags: event.modifierFlags) else { return nil }
            coordinator.stop?()
            coordinator.record?(action, shortcut)
            return nil
        }
        update(context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ coordinator: Coordinator) {
        let binding = $recording
        coordinator.recording = { binding.wrappedValue }
        coordinator.stop = { binding.wrappedValue = nil }
        coordinator.record = onRecord
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var monitor: Any?
        var recording: (() -> KeyAction?)?
        var stop: (() -> Void)?
        var record: ((KeyAction, Shortcut) -> Void)?
    }
}
