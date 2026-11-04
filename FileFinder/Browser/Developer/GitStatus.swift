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

    /// Status touches no submodule: each has a config of its own.
    static func statusArguments(root: URL) -> [String] {
        ["--no-optional-locks", "-C", root.path, "status", "--porcelain=v1", "--untracked-files=normal", "--ignore-submodules=all"]
    }

    /// Lists config names only; reading config never runs anything.
    static func filterConfigArguments(root: URL) -> [String] {
        ["--no-optional-locks", "-C", root.path, "config", "--name-only", "--get-regexp", "^filter\\."]
    }

    /// Driver names from `filter.<driver>.<key>` config names, verbatim: dotted, empty and
    /// "=" names included. A `filter.<key>` line (a section with no driver) names none.
    static func filterDrivers(configNames: String) -> [String] {
        var drivers: [String] = []
        for line in configNames.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("filter.") else { continue }
            let rest = line.dropFirst("filter.".count)
            guard let lastDot = rest.lastIndex(of: ".") else { continue }
            let name = String(rest[..<lastDot])
            if !drivers.contains(name) { drivers.append(name) }
        }
        return drivers
    }

    /// The environment git runs with. A folder's repository config is untrusted (a downloaded
    /// project can set anything), and `git status` would run some of it: the `core.fsmonitor`
    /// hook, clean filters for files whose stat info changed, and, in a partial clone missing
    /// an object, a fetch with the remote's own commands. Overrides go in `GIT_CONFIG_KEY_n`
    /// variables, which take any key verbatim (`-c` can't express driver names with "=") and
    /// also reach any git that git starts. Inherited `GIT_*` variables are dropped so nothing
    /// from the app's launch environment redirects git.
    static func gitEnvironment(inherited: [String: String], filterDrivers: [String]) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        var overrides = [("core.fsmonitor", "false")]
        for driver in filterDrivers {
            overrides += [
                ("filter.\(driver).clean", ""), ("filter.\(driver).process", ""), ("filter.\(driver).required", "false"),
            ]
        }
        environment["GIT_CONFIG_COUNT"] = String(overrides.count)
        for (index, (key, value)) in overrides.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = key
            environment["GIT_CONFIG_VALUE_\(index)"] = value
        }
        return environment
    }

    static func changeCount(porcelain: String) -> Int {
        porcelain.split(whereSeparator: \.isNewline).count
    }

    /// Branch and change count for the repository `folder` is in. Blocking: call off the main
    /// actor. Both git calls together get `timeout`.
    static func status(of folder: URL, git: URL?, timeout: TimeInterval = 5) -> GitStatus? {
        guard let repository = repository(containing: folder),
              let head = head(gitDir: repository.gitDir) else { return nil }
        let changes = git.flatMap { runStatus(git: $0, root: repository.root, deadline: Date.now.addingTimeInterval(timeout)) }
        return GitStatus(root: repository.root, branch: head.branch, isDetached: head.isDetached, changes: changes)
    }

    private static func runStatus(git: URL, root: URL, deadline: Date) -> Int? {
        let inherited = ProcessInfo.processInfo.environment
        // `--get-regexp` exits with 1 when nothing matches: no filters. Without the list the
        // filters can't be switched off, so status doesn't run at all.
        guard let names = run(git, filterConfigArguments(root: root),
                              environment: gitEnvironment(inherited: inherited, filterDrivers: []),
                              deadline: deadline, acceptedStatuses: [0, 1]) else { return nil }
        let environment = gitEnvironment(inherited: inherited, filterDrivers: filterDrivers(configNames: names))
        return run(git, statusArguments(root: root), environment: environment, deadline: deadline)
            .map { changeCount(porcelain: $0) }
    }

    /// Runs git and returns its output, or `nil` on failure or once `deadline` passes.
    private static func run(
        _ git: URL, _ arguments: [String], environment: [String: String], deadline: Date,
        acceptedStatuses: Set<Int32> = [0]
    ) -> String? {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
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
        // A huge work tree (or a FIFO in the config) must not keep the path bar waiting.
        DispatchQueue.global().asyncAfter(deadline: .now() + remaining) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, acceptedStatuses.contains(process.terminationStatus) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
