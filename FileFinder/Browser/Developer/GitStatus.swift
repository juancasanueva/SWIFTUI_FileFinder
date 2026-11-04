import Foundation

/// The git state shown in the path bar.
nonisolated struct GitStatus: Equatable, Sendable {
    let root: URL
    /// The branch name, or a short commit id when HEAD is detached.
    let branch: String
    let isDetached: Bool
    /// Uncommitted changes, untracked files included; `nil` when git couldn't be run.
    let changes: Int?
}

/// Reads git state without ever changing anything: HEAD is read straight from disk, and the
/// change count comes from `git status` without optional locks (so not even the index stat
/// cache is rewritten). It never fetches, pulls, or writes.
nonisolated enum GitStatusReader {
    /// Real git binaries only. `/usr/bin/git` is left out on purpose: without the command line
    /// tools it pops up an install prompt instead of running.
    static let defaultGitCandidates = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ]

    static func gitExecutable(candidates: [String] = defaultGitCandidates) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }

    /// The work tree `folder` is in and its git directory, or `nil` outside of one.
    static func repository(containing folder: URL) -> (root: URL, gitDir: URL)? {
        var current = folder.canonical
        // Inside a .git directory is git's own storage, not a work tree.
        guard !current.pathComponents.contains(".git") else { return nil }
        let fileManager = FileManager.default
        while true {
            let dotGit = current.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return (current, dotGit.canonical) }
                // A linked worktree or submodule: ".git" is a file saying "gitdir: <path>".
                if let text = try? String(contentsOf: dotGit, encoding: .utf8),
                   let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") {
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let gitDir = path.hasPrefix("/") ? URL(filePath: path) : current.appending(path: path)
                    return (current, gitDir.canonical)
                }
            }
            if current.path == "/" || current.pathComponents.count <= 1 { return nil }
            current = current.deletingLastPathComponent().canonical
        }
    }

    /// The checked-out branch from `<gitDir>/HEAD`.
    static func head(gitDir: URL) -> (branch: String, isDetached: Bool)? {
        guard let text = try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8) else { return nil }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            return (ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref, false)
        }
        guard !head.isEmpty else { return nil }
        return (String(head.prefix(7)), true)
    }

    static func statusArguments(root: URL) -> [String] {
        ["--no-optional-locks", "-C", root.path, "status", "--porcelain=v1", "--untracked-files=normal"]
    }

    static func changeCount(porcelain: String) -> Int {
        porcelain.split(whereSeparator: \.isNewline).count
    }

    /// Branch and change count for the repository `folder` is in. Blocking: call off the main actor.
    static func status(of folder: URL, git: URL?, timeout: TimeInterval = 5) -> GitStatus? {
        guard let repository = repository(containing: folder),
              let head = head(gitDir: repository.gitDir) else { return nil }
        let changes = git.flatMap { runStatus(git: $0, root: repository.root, timeout: timeout) }
        return GitStatus(root: repository.root, branch: head.branch, isDetached: head.isDetached, changes: changes)
    }

    private static func runStatus(git: URL, root: URL, timeout: TimeInterval) -> Int? {
        let process = Process()
        process.executableURL = git
        process.arguments = statusArguments(root: root)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // A huge work tree must not keep the path bar waiting forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return changeCount(porcelain: String(decoding: data, as: UTF8.self))
    }
}
