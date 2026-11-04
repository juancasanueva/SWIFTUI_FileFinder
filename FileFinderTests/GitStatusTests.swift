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

    @Test("Filter drivers are read from config names, including dotted ones")
    func filterDriverNames() {
        let names = GitStatusReader.filterDrivers(configNames: "filter.lfs.clean\nfilter.lfs.process\nfilter.a.b.smudge\nfilter.x=y.clean\n")
        #expect(names == ["lfs", "a.b"])
        let arguments = GitStatusReader.statusArguments(root: URL(filePath: "/repo"), filterDrivers: ["lfs"])
        #expect(arguments.contains("core.fsmonitor=false"))
        #expect(arguments.contains("filter.lfs.clean=") && arguments.contains("filter.lfs.process="))
        #expect(arguments.contains("--ignore-submodules=all"))
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
