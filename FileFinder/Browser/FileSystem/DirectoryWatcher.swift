import Foundation

/// Watches a folder for entries being added, removed or renamed.
nonisolated enum DirectoryWatcher {
    /// A stream that yields (debounced) once per burst of changes. Watching starts immediately
    /// and stops when the consuming task is cancelled or the stream is released.
    static func changes(of folder: URL, debounce: Duration = .milliseconds(200)) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else {
                continuation.finish()
                return
            }
            let queue = DispatchQueue(label: "DirectoryWatcher")
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend, .link], queue: queue)
            let delay = DispatchTimeInterval.milliseconds(Int(debounce / .milliseconds(1)))
            var pending: DispatchWorkItem?

            source.setEventHandler {
                pending?.cancel()
                let work = DispatchWorkItem { continuation.yield() }
                pending = work
                queue.asyncAfter(deadline: .now() + delay, execute: work)
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    // The watched folder itself went away; the caller should navigate elsewhere.
                    continuation.finish()
                }
            }
            source.setCancelHandler { close(descriptor) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}
