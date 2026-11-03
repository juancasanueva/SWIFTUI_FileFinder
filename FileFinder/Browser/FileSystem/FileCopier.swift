import Darwin
import Foundation

/// Copies a file or folder with copyfile(3), reporting progress and honoring cancellation.
/// `FileManager.copyItem` offers neither. Synchronous: call it off the main actor.
nonisolated enum FileCopier {
    /// Called with the bytes copied so far for this item (throttled, increasing).
    typealias Progress = @Sendable (Int64) -> Void

    /// - Parameter allowClone: on APFS, clone instead of copying when possible (instant, but
    ///   reports no progress). Tests turn it off to see real data copying.
    static func copy(
        from source: URL, to destination: URL, allowClone: Bool = true,
        progress: @escaping Progress, shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        if shouldCancel() { throw CancellationError() }
        // COPYFILE_EXCL only refuses file-onto-file: a folder (or file) copied onto an existing
        // folder would silently go inside it. Refuse anything already there, links included.
        var status = stat()
        if lstat(destination.path, &status) == 0 {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(EEXIST),
                userInfo: [NSFilePathErrorKey: destination.path, NSURLErrorKey: source])
        }

        let context = CallbackContext(progress: progress, shouldCancel: shouldCancel)
        guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
        defer { copyfile_state_free(state) }

        let callback: copyfile_callback_t = { what, stage, state, _, _, info in
            guard let info else { return COPYFILE_CONTINUE }
            let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
            if context.shouldCancel() {
                context.wasCancelled = true
                return COPYFILE_QUIT
            }
            if stage == COPYFILE_ERR { return COPYFILE_QUIT }
            // Data progress arrives as COPY_DATA/PROGRESS with the bytes copied of the current
            // file; there is no "data finished" stage, so a file is closed out when recursion
            // reports it finished (or at the end, for a single file).
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                context.report(currentFile: Int64(copied))
            } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
                context.finishFile()
            }
            return COPYFILE_CONTINUE
        }

        let info = Unmanaged.passUnretained(context).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), info)

        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL)
        if allowClone { flags |= copyfile_flags_t(COPYFILE_CLONE) }

        let result = withExtendedLifetime(context) { copyfile(source.path, destination.path, state, flags) }
        if result != 0 {
            let code = errno
            if context.wasCancelled || code == ECANCELED { throw CancellationError() }
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSFilePathErrorKey: destination.path, NSURLErrorKey: source])
        }
        context.flush()
    }

    /// Running totals for one copyfile call (which may cover many files when recursive).
    private final class CallbackContext {
        let progress: Progress
        let shouldCancel: @Sendable () -> Bool
        var wasCancelled = false
        private var finishedBytes: Int64 = 0
        private var currentFileBytes: Int64 = 0
        private var lastReported: Int64 = -1
        private var lastReportTime: ContinuousClock.Instant?

        init(progress: @escaping Progress, shouldCancel: @escaping @Sendable () -> Bool) {
            self.progress = progress
            self.shouldCancel = shouldCancel
        }

        func report(currentFile: Int64) {
            currentFileBytes = currentFile
            let total = finishedBytes + currentFile
            let now = ContinuousClock.now
            // The first update goes out at once, then at most ~20 a second.
            if let last = lastReportTime, now - last < .milliseconds(50) { return }
            guard total > lastReported else { return }
            lastReported = total
            lastReportTime = now
            progress(total)
        }

        func finishFile() {
            finishedBytes += currentFileBytes
            currentFileBytes = 0
        }

        func flush() {
            finishFile()
            if finishedBytes > lastReported { progress(finishedBytes) }
        }
    }
}
