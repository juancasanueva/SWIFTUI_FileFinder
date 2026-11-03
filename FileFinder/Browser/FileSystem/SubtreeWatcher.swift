import CoreServices
import Foundation

/// Watches a whole folder tree with FSEvents. `DirectoryWatcher` only sees entries added or
/// removed directly in a folder; this catches changes at any depth, which is what folder sizes
/// need.
nonisolated enum SubtreeWatcher {
    /// A stream of batches of changed paths (resolved, e.g. "/private/var/…"). Watching starts
    /// immediately and stops when the stream is released or its consumer is cancelled.
    static func changes(of folder: URL, latency: TimeInterval = 1.0) -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let box = Unmanaged.passRetained(ContinuationBox(continuation))
            var context = FSEventStreamContext(
                version: 0, info: box.toOpaque(), retain: nil,
                release: { info in
                    if let info { Unmanaged<ContinuationBox>.fromOpaque(info).release() }
                },
                copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
                guard let info else { return }
                let box = Unmanaged<ContinuationBox>.fromOpaque(info).takeUnretainedValue()
                let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                box.continuation.yield(changed)
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, [folder.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else {
                box.release()
                continuation.finish()
                return
            }
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "SubtreeWatcher"))
            FSEventStreamStart(stream)
            nonisolated(unsafe) let ownedStream = stream
            continuation.onTermination = { _ in
                FSEventStreamStop(ownedStream)
                FSEventStreamInvalidate(ownedStream)
                FSEventStreamRelease(ownedStream)  // also releases `box` via the context
            }
        }
    }

    /// Names of the direct children of `folder` that contain a changed path at least one level
    /// down. Changes to direct children themselves are left to `DirectoryWatcher`.
    static func changedChildren(paths: [String], in folder: URL) -> Set<String> {
        // FSEvents reports real paths ("/private/var/…"); `resolvingSymlinksInPath()` would strip
        // "/private", so ask the kernel with realpath(3).
        var roots: Set<String> = [folder.standardizedFileURL.path]
        if let real = realpath(folder.path, nil) {
            roots.insert(String(cString: real))
            free(real)
        }
        var names: Set<String> = []
        for path in paths {
            for root in roots {
                let prefix = root.hasSuffix("/") ? root : root + "/"
                guard path.hasPrefix(prefix) else { continue }
                let components = path.dropFirst(prefix.count).split(separator: "/")
                if components.count >= 2 { names.insert(String(components[0])) }
            }
        }
        return names
    }

    private final class ContinuationBox {
        let continuation: AsyncStream<[String]>.Continuation
        init(_ continuation: AsyncStream<[String]>.Continuation) { self.continuation = continuation }
    }
}
