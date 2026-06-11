// ============================================================
// GitStatusMonitor.swift
// SOLARO — git status for the file tree + status bar (#245)
// ============================================================
//
// Shells out to `git status --porcelain=v1 -b` once per refresh
// and parses the output into per-file status tags + the current
// branch / ahead-behind counts. Refresh hooks: project load,
// file save, and a manual "Refresh" command.

import Foundation

struct GitStatus: Equatable {
    var branch: String = ""
    var upstream: String = ""
    var ahead: Int = 0
    var behind: Int = 0
    /// Map from absolute file path → status code.
    var files: [String: FileStatus] = [:]

    enum FileStatus: Equatable, Hashable {
        case modified
        case added
        case deleted
        case renamed
        case untracked
        case ignored
        case conflicted
    }

    var hasUpstream: Bool { !upstream.isEmpty }
}

struct GitBranch: Equatable, Identifiable, Hashable {
    let name: String
    let isCurrent: Bool
    var id: String { name }
}

@MainActor
@Observable
final class GitStatusMonitor {
    private(set) var status: GitStatus = .init()
    private(set) var isAvailable: Bool = false
    private(set) var lastError: String?
    /// Local branches as of the last refresh, with `isCurrent`
    /// flagging which one HEAD points at.
    private(set) var branches: [GitBranch] = []

    /// Issue #311 — handle of the most recent in-flight refresh.
    /// `refresh(for:)` cancels the previous one before starting a
    /// new one so a rapid save burst doesn't fan out into dozens
    /// of overlapping `git status` invocations. The deinit cancels
    /// it on workspace teardown so a completed task can't fire
    /// its `MainActor.run` continuation against a deallocated
    /// observer.
    /// `@ObservationIgnored` + `nonisolated` so the non-isolated
    /// deinit can call `cancel()` directly. `Task` is already
    /// `Sendable`; the only other writer is the MainActor-isolated
    /// `refresh(for:)`. @Observable's macro otherwise rejects
    /// `nonisolated` on tracked stored properties.
    @ObservationIgnored
    private nonisolated(unsafe) var refreshTask: Task<Void, Never>?

    /// Issue #310 — debounce + cache so a rapid save burst doesn't
    /// fan out to N `git status` shells, and back-to-back callers
    /// reuse the most recent result for ~5s. UI consumers that
    /// genuinely need fresh state after a mutation (commit, branch
    /// switch) call `forceRefresh(for:)` instead.
    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastFreshAt: Date?
    private static let debounceWindow: Duration = .milliseconds(200)
    private static let cacheWindow: TimeInterval = 5.0

    deinit {
        refreshTask?.cancel()
        debounceTask?.cancel()
    }

    /// Debounced + cached refresh. Coalesces rapid calls inside a
    /// ~200ms window; serves the cached result when the last fresh
    /// snapshot is < 5s old.
    func refresh(for project: Project) {
        if let last = lastFreshAt,
           Date().timeIntervalSince(last) < Self.cacheWindow {
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceWindow)
            if Task.isCancelled { return }
            self?.runRefresh(for: project)
        }
    }

    /// Bypass the debounce + cache. Use after a mutation we know
    /// changed the working tree (commit, branch switch, restore).
    func forceRefresh(for project: Project) {
        debounceTask?.cancel()
        runRefresh(for: project)
    }

    private func runRefresh(for project: Project) {
        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .utility) {
            let result = await Self.run(project: project)
            if Task.isCancelled { return }
            let branches = await Self.runBranches(project: project)
            if Task.isCancelled { return }
            await MainActor.run {
                self.isAvailable = result.available
                self.status = result.status
                self.lastError = result.error
                self.branches = branches
                self.lastFreshAt = Date()
            }
        }
    }

    /// Run `git checkout <branch>` and refresh on success. Returns
    /// the trimmed stderr on failure so callers can show it.
    func checkout(branch: String, in project: Project) async -> String? {
        let err = await Self.runCheckout(branch: branch, project: project)
        if err == nil { forceRefresh(for: project) }
        return err
    }

    /// Combined unstaged + staged diff against HEAD, capped at a
    /// large-but-bounded size so prompts to `aro ask` stay reasonable.
    /// Returns "" if there's nothing to diff or git fails.
    func diffAgainstHEAD(in project: Project) async -> String {
        await Self.runDiff(project: project, path: nil)
    }

    /// Per-file diff against HEAD. Used by the commit dialog when
    /// the user clicks a file in the sidebar to scope the diff
    /// view to just that file. Returns "" when the file has no
    /// tracked changes or git can't resolve it.
    func diffAgainstHEAD(in project: Project, path: String) async -> String {
        await Self.runDiff(project: project, path: path)
    }

    /// Discard a tracked file's local changes by restoring its
    /// HEAD contents. For untracked files we just delete from the
    /// working tree — `git restore` doesn't know about them. The
    /// returned string is nil on success and the trimmed stderr on
    /// failure so the caller can surface it.
    func revertLocalChanges(
        in project: Project,
        path: String,
        status: GitStatus.FileStatus
    ) async -> String? {
        let err: String?
        switch status {
        case .untracked:
            do {
                try FileManager.default.removeItem(
                    atPath: path
                )
                err = nil
            } catch {
                err = error.localizedDescription
            }
        case .modified, .added, .deleted, .renamed,
             .ignored, .conflicted:
            err = await Self.runRestore(project: project, path: path)
        }
        if err == nil { forceRefresh(for: project) }
        return err
    }

    /// Stage everything and commit with the given message. Trims
    /// the result; throws via the returned error string on failure.
    func commit(message: String, in project: Project) async -> String? {
        let err = await Self.runCommit(message: message, project: project)
        if err == nil { forceRefresh(for: project) }
        return err
    }

    /// Stage only the listed file paths and commit with the given
    /// message. Used by the commit dialog's per-file checkbox
    /// list so the user can commit a subset of the working-tree
    /// changes. `paths` are absolute (the same shape that
    /// `GitStatus.files` uses). Empty `paths` short-circuits with
    /// an error so we never produce an empty commit.
    func commit(
        message: String,
        files paths: [String],
        in project: Project
    ) async -> String? {
        guard !paths.isEmpty else { return "Nothing to commit — select at least one file." }
        let err = await Self.runScopedCommit(
            message: message, paths: paths, project: project
        )
        if err == nil { forceRefresh(for: project) }
        return err
    }

    private struct Result {
        let available: Bool
        let status: GitStatus
        let error: String?
    }

    private nonisolated static func run(project: Project) async -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git", "status", "--porcelain=v1", "-b"]
        task.currentDirectoryURL = project.rootPath
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                // Most likely "not a git repository" — surface
                // gracefully without spamming the UI.
                return Result(available: false, status: .init(), error: nil)
            }
            let text = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return Result(
                available: true,
                status: parse(porcelain: text, projectRoot: project.rootPath),
                error: nil
            )
        } catch {
            return Result(available: false, status: .init(),
                          error: error.localizedDescription)
        }
    }

    nonisolated static func parse(
        porcelain: String,
        projectRoot: URL
    ) -> GitStatus {
        var s = GitStatus()
        let rootPath = projectRoot.standardizedFileURL.path
        for rawLine in porcelain.split(separator: "\n",
                                       omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("## ") {
                parseBranchLine(line, into: &s)
                continue
            }
            guard line.count >= 3 else { continue }
            let statusBytes = String(line.prefix(2))
            let pathPart = line.index(line.startIndex, offsetBy: 3)
            let path = String(line[pathPart...])
            let absolute = (rootPath as NSString).appendingPathComponent(path)
            if let status = mapStatus(statusBytes) {
                s.files[absolute] = status
            }
        }
        return s
    }

    nonisolated private static func parseBranchLine(_ line: String, into s: inout GitStatus) {
        // Examples:
        //   ## main
        //   ## main...origin/main
        //   ## main...origin/main [ahead 2]
        //   ## main...origin/main [ahead 2, behind 1]
        //   ## HEAD (no branch)
        let body = String(line.dropFirst(3))
        var rest = body
        if let bracketRange = rest.range(of: " [") {
            let info = rest[bracketRange.upperBound...].dropLast()
            for chunk in info.split(separator: ",") {
                let parts = chunk.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ")
                guard parts.count == 2, let n = Int(parts[1]) else { continue }
                switch parts[0] {
                case "ahead":  s.ahead = n
                case "behind": s.behind = n
                default: break
                }
            }
            rest = String(rest[..<bracketRange.lowerBound])
        }
        if let dotsRange = rest.range(of: "...") {
            s.branch = String(rest[..<dotsRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            s.upstream = String(rest[dotsRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            s.branch = rest.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Branch / diff / commit

    nonisolated private static func runBranches(project: Project) async -> [GitBranch] {
        let result = runGit(
            args: ["branch", "--list", "--no-color"],
            project: project
        )
        guard result.exitCode == 0 else { return [] }
        var branches: [GitBranch] = []
        for raw in result.stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            guard line.count > 2 else { continue }
            let marker = line.first
            let name = String(line.dropFirst(2))
                .trimmingCharacters(in: .whitespaces)
            // Skip detached-HEAD lines like "* (HEAD detached at …)".
            if name.hasPrefix("(") && name.hasSuffix(")") { continue }
            guard !name.isEmpty else { continue }
            branches.append(GitBranch(name: name, isCurrent: marker == "*"))
        }
        return branches
    }

    nonisolated private static func runCheckout(branch: String, project: Project) async -> String? {
        let result = runGit(args: ["checkout", branch], project: project)
        if result.exitCode == 0 { return nil }
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? "git checkout failed (exit \(result.exitCode))" : err
    }

    /// Restore a path to its HEAD contents — both index (`--staged`)
    /// and working tree (`--worktree`) so the file reads as if the
    /// user never edited it. Returns nil on success, trimmed
    /// stderr on failure.
    nonisolated private static func runRestore(
        project: Project,
        path: String
    ) async -> String? {
        let run = runGit(args: ["restore", "--staged", "--worktree", "--", path],
                         project: project)
        if run.exitCode == 0 { return nil }
        let err = (run.stderr + run.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty
            ? "git restore failed (exit \(run.exitCode))"
            : err
    }

    nonisolated private static func runDiff(
        project: Project,
        path: String?
    ) async -> String {
        // Untracked files don't show up in `git diff HEAD` — we
        // include their full text via `git diff --no-index` for any
        // file the porcelain marked `??`. For tracked changes a
        // single `git diff HEAD` covers staged + unstaged combined.
        var args = ["diff", "HEAD", "--no-color"]
        if let path { args.append(contentsOf: ["--", path]) }
        let tracked = runGit(args: args, project: project)
        return tracked.stdout
    }

    /// Stage exactly the listed paths and commit with the given
    /// message. Wipes the index first via `git reset` so any
    /// already-staged-but-unselected files don't sneak into the
    /// commit. Untracked + modified are both handled by `git add`.
    nonisolated private static func runScopedCommit(
        message: String,
        paths: [String],
        project: Project
    ) async -> String? {
        _ = runGit(args: ["reset"], project: project)
        var addArgs = ["add", "--"]
        addArgs.append(contentsOf: paths)
        let add = runGit(args: addArgs, project: project)
        if add.exitCode != 0 {
            let err = add.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return err.isEmpty
                ? "git add failed (exit \(add.exitCode))"
                : err
        }
        let commit = runGit(args: ["commit", "-m", message], project: project)
        if commit.exitCode == 0 { return nil }
        let err = (commit.stderr + commit.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty
            ? "git commit failed (exit \(commit.exitCode))"
            : err
    }

    nonisolated private static func runCommit(message: String, project: Project) async -> String? {
        let add = runGit(args: ["add", "-A"], project: project)
        if add.exitCode != 0 {
            let err = add.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return err.isEmpty ? "git add failed (exit \(add.exitCode))" : err
        }
        let commit = runGit(args: ["commit", "-m", message], project: project)
        if commit.exitCode == 0 { return nil }
        let err = (commit.stderr + commit.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? "git commit failed (exit \(commit.exitCode))" : err
    }

    private struct GitRun {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Synchronous git invocation used by the off-main helpers
    /// above. Returns captured stdout/stderr and the exit code.
    nonisolated private static func runGit(args: [String], project: Project) -> GitRun {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git"] + args
        task.currentDirectoryURL = project.rootPath
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
            task.waitUntilExit()
            let outText = String(
                data: out.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let errText = String(
                data: err.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return GitRun(
                exitCode: task.terminationStatus,
                stdout: outText,
                stderr: errText
            )
        } catch {
            return GitRun(exitCode: -1, stdout: "",
                          stderr: error.localizedDescription)
        }
    }

    nonisolated private static func mapStatus(_ code: String) -> GitStatus.FileStatus? {
        switch code {
        case "??": return .untracked
        case "!!": return .ignored
        case " M", "M ", "MM", "AM": return .modified
        case " A", "A ", "AA": return .added
        case " D", "D ", "AD": return .deleted
        case "R ", " R", "RM": return .renamed
        case "UU", "AU", "UA", "DU", "UD": return .conflicted
        default:
            // Any other two-char code with at least one non-space
            // means the file is in the index in some shape — treat
            // as modified for display purposes.
            if code.allSatisfy({ $0 == " " }) { return nil }
            return .modified
        }
    }
}
