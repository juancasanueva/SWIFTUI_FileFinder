import Foundation

/// Status bar summary, e.g. "21 items · 304.4 GB available".
nonisolated enum StatusText {
    static func make(itemCount: Int, selectedCount: Int, availableBytes: Int64?, locale: Locale = .current) -> String {
        var parts: [String] = []
        if selectedCount > 0 {
            parts.append("\(selectedCount) of \(itemCount) selected")
        } else {
            parts.append(itemCount == 1 ? "1 item" : "\(itemCount) items")
        }
        if let availableBytes {
            parts.append("\(formatBytes(availableBytes, locale: locale)) available")
        }
        return parts.joined(separator: " · ")
    }

    static func formatBytes(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
