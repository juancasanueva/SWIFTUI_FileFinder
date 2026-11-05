import AppKit
import SwiftUI

extension View {
    /// Runs `action` when a bare Escape is pressed in this view's window while `isActive`.
    ///
    /// A text field being edited never reports Escape to `onKeyPress` or `onExitCommand`: the
    /// AppKit field editor keeps it. A local event monitor sees the key before the field editor.
    func onEscapeKey(isActive: Bool, perform action: @escaping () -> Void) -> some View {
        background(EscapeKeyMonitor(isActive: isActive, action: action))
    }
}

private struct EscapeKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard coordinator.isActive, event.keyCode == 53, event.window === view?.window,
                  modifiers.isDisjoint(with: [.command, .control, .option, .shift])
            else { return event }
            coordinator.action()
            return nil
        }
        update(coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.isActive = isActive
        coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    final class Coordinator {
        var monitor: Any?
        var isActive = false
        var action: () -> Void = {}
    }
}
