import SwiftUI

/// Progress of the running copy, with Cancel. Appears only once a copy has run for a moment,
/// so quick copies don't flash it.
struct TransferBar: View {
    let actions: FileActions
    @State private var visibleTransfer: ObjectIdentifier?

    var body: some View {
        if let transfer = actions.currentTransfer {
            Group {
                if visibleTransfer == ObjectIdentifier(transfer) {
                    content(transfer)
                }
            }
            .task(id: ObjectIdentifier(transfer)) {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { visibleTransfer = ObjectIdentifier(transfer) }
            }
        }
    }

    private func content(_ transfer: TransferProgress) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    if transfer.isMeasuring {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: transfer.fraction)
                    }
                    Text(detail(transfer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Cancel") { actions.cancelCurrentTransfer() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ transfer: TransferProgress) -> String {
        var text = transfer.isMeasuring
            ? "Preparing…"
            : "\(StatusText.formatBytes(transfer.completedBytes)) of \(StatusText.formatBytes(transfer.totalBytes))"
        if actions.queuedOperations > 0 {
            text += " · \(actions.queuedOperations) more queued"
        }
        return text
    }
}
