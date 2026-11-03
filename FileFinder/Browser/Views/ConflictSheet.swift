import SwiftUI

/// "An item named … already exists" with Keep Both / Replace / Skip, plus "apply to all".
struct ConflictSheet: View {
    let conflict: NameConflict
    let onAnswer: (ConflictDecision) -> Void
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("An item named “\(conflict.existing.lastPathComponent)” already exists in “\(conflict.existing.deletingLastPathComponent().lastPathComponent)”.")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            Text("Replacing it moves the existing item to the Trash.")
                .foregroundStyle(.secondary)
            if conflict.remaining > 0 {
                Toggle("Apply to the \(conflict.remaining) remaining item\(conflict.remaining == 1 ? "" : "s")",
                       isOn: $applyToAll)
            }
            HStack {
                Button("Stop", role: .cancel) {
                    onAnswer(ConflictDecision(resolution: .skip, applyToAll: true))
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Skip") { answer(.skip) }
                Button("Replace") { answer(.replace) }
                Button("Keep Both") { answer(.keepBoth) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    private func answer(_ resolution: ConflictResolution) {
        onAnswer(ConflictDecision(resolution: resolution, applyToAll: applyToAll))
    }
}
