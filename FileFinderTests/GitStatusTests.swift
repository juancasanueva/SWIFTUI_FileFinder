import Foundation
import Testing
@testable import FileFinder

@MainActor
@Suite("Git at a glance")
struct GitStatusTests {
    let dir: TemporaryDirectory

    init() throws {
        dir = try TemporaryDirectory()
    }

    private static let git = GitStatusReader.gitExecutable()

    /// Runs git in the test repository (setup only; the app itself never writes).
    @discardableResult
    private func run(_ arguments: [String], in folder: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = try #require(Self.git)
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
            + arguments
        process.currentDirectoryURL = folder ?? dir.url
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func makeRepository() throws {
        try run(["init", "-q", "-b", "main"])
        try dir.file("README.md", bytes: 3)
        try run(["add", "README.md"])
        try run(["commit", "-q", "-m", "first"])
    }

    /// Every path under `.git` with its modification date and size.
    private func snapshot(_ gitDir: URL) -> [String: String] {
        var result: [String: String] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(at: gitDir, includingPropertiesForKeys: keys)
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            result[url.path] = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)/\(values?.fileSize ?? -1)"
        }
        return result
    }

    // MARK: - Finding the repository

    @Test("A folder anywhere inside a work tree belongs to its repository")
    func findsRoot() throws {
        try dir.folder(".git")
        let nested = try dir.folder("Sources/App")

        let found = try #require(GitStatusReader.repository(containing: nested))

        #expect(found.root == dir.url.canonical)
        #expect(found.gitDir == dir.url.appending(path: ".git").canonical)
        #expect(GitStatusReader.repository(containing: dir.url.deletingLastPathComponent()) == nil)
    }

    @Test("A linked worktree's .git file points at its git directory")
    func worktreeFile() throws {
        let gitDir = try dir.folder("main/.git/worktrees/feature")
        try "gitdir: \(gitDir.path)\n".write(to: try dir.folder("feature").appending(path: ".git"), atomically: true, encoding: .utf8)
        try "gitdir: ../main/.git/worktrees/feature\n".write(
            to: try dir.folder("relative").appending(path: ".git"), atomically: true, encoding: .utf8)

        #expect(GitStatusReader.repository(containing: dir.url.appending(path: "feature"))?.gitDir == gitDir.canonical)
        #expect(GitStatusReader.repository(containing: dir.url.appending(path: "relative"))?.gitDir == gitDir.canonical)
    }

    @Test("The inside of a .git folder isn't a work tree")
    func insideGitDir() throws {
        let objects = try dir.folder(".git/objects")
        #expect(GitStatusReader.repository(containing: objects) == nil)
    }

    // MARK: - Reading

    @Test("HEAD names the branch, or a short commit id when detached", arguments: [
        ("ref: refs/heads/main\n", "main", false),
        ("ref: refs/heads/feature/login\n", "feature/login", false),
        ("3f2a9c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39\n", "3f2a9c1", true),
    ])
    func head(contents: String, branch: String, detached: Bool) throws {
        let gitDir = try dir.folder(".git")
        try contents.write(to: gitDir.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        let head = try #require(GitStatusReader.head(gitDir: gitDir))
        #expect(head.branch == branch)
        #expect(head.isDetached == detached)
    }

    @Test("Each porcelain line is one uncommitted change")
    func porcelainCount() {
        #expect(GitStatusReader.changeCount(porcelain: " M a.swift\n?? b.txt\nR  c -> d\n") == 3)
        #expect(GitStatusReader.changeCount(porcelain: "") == 0)
    }

    @Test("Status never takes optional locks, so it never rewrites the index")
    func readOnlyArguments() {
        let arguments = GitStatusReader.statusArguments(root: URL(filePath: "/repo"))
        #expect(arguments.first == "--no-optional-locks")
        #expect(arguments.contains("status") && arguments.contains("--porcelain=v1"))
        #expect(!arguments.contains { ["fetch", "pull", "add", "commit", "checkout"].contains($0) })
    }

    @Test("Only git binaries that exist are used, and none means no change count")
    func gitLookup() throws {
        let fake = try dir.file("bin/git")
        let notExecutable = try dir.file("bin/plain-git")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        #expect(GitStatusReader.gitExecutable(candidates: [notExecutable.path]) == nil)
        #expect(GitStatusReader.gitExecutable(candidates: ["/nonexistent/git", fake.path]) == fake)
        #expect(GitStatusReader.gitExecutable(candidates: ["/nonexistent/git"]) == nil)
        #expect(!GitStatusReader.defaultGitCandidates.contains("/usr/bin/git"))   // the shim prompts to install tools
    }

    @Test("A real repository shows its branch and uncommitted changes, and reading it changes nothing",
          .enabled(if: git != nil))
    func realRepository() throws {
        try makeRepository()
        try dir.file("README.md", bytes: 5)   // modified
        try dir.file("notes.txt")             // untracked
        let gitDir = dir.url.appending(path: ".git")
        let before = snapshot(gitDir)

        let status = try #require(GitStatusReader.status(of: try dir.folder("Sources"), git: Self.git))

        #expect(status.branch == "main")
        #expect(!status.isDetached)
        #expect(status.changes == 2)
        #expect(snapshot(gitDir) == before)
    }

    @Test("A repository's own config can't make reading it run commands", .enabled(if: git != nil))
    func repositoryConfigRunsNothing() throws {
        try makeRepository()
        try dir.file("data.txt", bytes: 4)
        try run(["add", "data.txt"])
        try run(["commit", "-q", "-m", "data"])
        let marker = dir.url.appending(path: "ran").path
        let script = "sh -c 'touch \"\(marker)\"; cat'"
        // Set only after committing, so setup itself never runs them.
        try "*.txt filter=evil\n".write(to: dir.url.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)
        try run(["config", "filter.evil.clean", script])
        try run(["config", "filter.evil.required", "true"])
        try run(["config", "core.fsmonitor", "touch \"\(marker)\"; false"])
        try Data(repeating: 0x41, count: 4).write(to: dir.url.appending(path: "data.txt"))   // stat-dirty, same content

        let status = try #require(GitStatusReader.status(of: dir.url, git: Self.git))

        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(status.changes != nil)
        // The trap is real: plain git status does run it.
        try run(["status", "--porcelain"])
        #expect(FileManager.default.fileExists(atPath: marker))
    }

    @Test("Filter driver names are read verbatim, including dotted, empty and '=' names; malformed keys are ignored")
    func filterDriverNames() {
        let names = GitStatusReader.filterDrivers(
            configNames: "filter.lfs.clean\nfilter.lfs.process\nfilter.a.b.smudge\nfilter.x=y.clean\nfilter..clean\nfilter.clean\nfilter.\n")
        #expect(names == ["lfs", "a.b", "x=y", ""])
    }

    @Test("Overrides travel as environment config, so any key is taken verbatim")
    func overridesInEnvironment() {
        let environment = GitStatusReader.gitEnvironment(
            inherited: ["PATH": "/bin", "GIT_DIR": "/elsewhere", "GIT_CONFIG_PARAMETERS": "'x.y=z'"],
            filterDrivers: ["a=b", ""])
        #expect(environment["PATH"] == "/bin")
        #expect(environment["GIT_DIR"] == nil && environment["GIT_CONFIG_PARAMETERS"] == nil)
        #expect(environment["GIT_NO_LAZY_FETCH"] == "1" && environment["GIT_OPTIONAL_LOCKS"] == "0")
        let count = Int(environment["GIT_CONFIG_COUNT"] ?? "") ?? 0
        let pairs = (0..<count).map { (environment["GIT_CONFIG_KEY_\($0)"] ?? "", environment["GIT_CONFIG_VALUE_\($0)"] ?? "?") }
        #expect(pairs.contains { $0 == ("core.fsmonitor", "false") })
        #expect(pairs.contains { $0 == ("filter.a=b.clean", "") } && pairs.contains { $0 == ("filter.a=b.process", "") })
        #expect(pairs.contains { $0 == ("filter..clean", "") } && pairs.contains { $0 == ("filter..required", "false") })
        #expect(GitStatusReader.statusArguments(root: URL(filePath: "/repo")).contains("--ignore-submodules=all"))
    }

    /// Commits data.txt, then (after the commit, so setup never runs it) makes the driver
    /// `attribute` with config section `section` run a marker-touching clean filter.
    private func trapFilter(attribute: String, configLines: String) throws -> String {
        try makeRepository()
        try dir.file("data.txt", bytes: 4)
        try run(["add", "data.txt"])
        try run(["commit", "-q", "-m", "data"])
        let marker = dir.url.appending(path: "ran").path
        try "*.txt filter=\(attribute)\n".write(to: dir.url.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)
        let config = dir.url.appending(path: ".git/config")
        let handle = try FileHandle(forWritingTo: config)
        handle.seekToEndOfFile()
        handle.write(Data(configLines.replacingOccurrences(of: "PAYLOAD", with: "sh -c 'touch \\\"\(marker)\\\"; cat'").utf8))
        try handle.close()
        try Data(repeating: 0x41, count: 4).write(to: dir.url.appending(path: "data.txt"))   // stat-dirty, same content
        return marker
    }

    @Test("Filters with names -c can't express ('=' or empty) run nothing either", .enabled(if: git != nil), arguments: [
        ("a=b", "[filter \"a=b\"]\n\tclean = \"PAYLOAD\"\n"),
        ("", "[filter \"\"]\n\tclean = \"PAYLOAD\"\n"),
    ])
    func oddFilterNamesRunNothing(attribute: String, configLines: String) throws {
        let marker = try trapFilter(attribute: attribute, configLines: configLines)

        _ = GitStatusReader.status(of: dir.url, git: Self.git)

        #expect(!FileManager.default.fileExists(atPath: marker))
        try run(["status", "--porcelain"])
        #expect(FileManager.default.fileExists(atPath: marker))   // the trap is real
    }

    @Test("A filter section without a driver name doesn't crash the reader", .enabled(if: git != nil))
    func driverlessFilterSection() throws {
        try makeRepository()
        let handle = try FileHandle(forWritingTo: dir.url.appending(path: ".git/config"))
        handle.seekToEndOfFile()
        handle.write(Data("[filter]\n\tclean = x\n".utf8))
        try handle.close()

        let status = GitStatusReader.status(of: dir.url, git: Self.git)

        #expect(status?.branch == "main")
    }

    @Test("A partial clone missing an object never fetches, so its remote's commands never run", .enabled(if: git != nil))
    func noLazyFetch() throws {
        try makeRepository()
        let tree = try run(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(at: dir.url.appending(path: ".git/objects/\(tree.prefix(2))/\(tree.dropFirst(2))"))
        let marker = dir.url.appending(path: "ran").path
        try run(["config", "core.repositoryformatversion", "1"])
        try run(["config", "extensions.partialClone", "origin"])
        try run(["config", "remote.origin.url", "ssh://attacker.invalid/x"])
        try run(["config", "remote.origin.promisor", "true"])
        try run(["config", "remote.origin.uploadpack", "touch \"\(marker)\"; false"])
        try run(["config", "core.sshCommand", "touch \"\(marker)\"; false"])

        let status = GitStatusReader.status(of: dir.url, git: Self.git)

        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(status?.branch == "main")
        try run(["status", "--porcelain"])
        #expect(FileManager.default.fileExists(atPath: marker))   // the trap is real
    }

    @Test("Without git only the branch is shown")
    func noGitBinary() throws {
        let gitDir = try dir.folder(".git")
        try "ref: refs/heads/dev\n".write(to: gitDir.appending(path: "HEAD"), atomically: true, encoding: .utf8)

        let status = try #require(GitStatusReader.status(of: dir.url, git: nil))

        #expect(status.branch == "dev")
        #expect(status.changes == nil)
    }

    // MARK: - Pane

    @Test("The pane knows the git status of the folder it shows, and not of workspaces", .enabled(if: git != nil))
    func pane() async throws {
        try makeRepository()
        let defaults = try #require(UserDefaults(suiteName: "FileFinderTests-\(UUID())"))
        let store = WorkspaceStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "FileFinderTests-\(UUID())/workspaces.json"))
        let pane = BrowserModel(start: dir.url, defaults: defaults, workspaces: store)

        await pane.reload()
        #expect(pane.gitStatus?.branch == "main")
        #expect(pane.gitStatus?.changes == 0)

        try dir.file("new.txt")
        await pane.reload()
        #expect(pane.gitStatus?.changes == 1)

        let workspace = store.create(named: "W")
        await pane.openWorkspace(workspace.id)
        #expect(pane.gitStatus == nil)

        pane.navigate(to: dir.url.deletingLastPathComponent())
        await pane.reload()
        #expect(pane.gitStatus == nil)
    }
}
