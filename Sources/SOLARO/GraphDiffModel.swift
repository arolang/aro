// ============================================================
// GraphDiffModel.swift
// SOLARO — feature-graph diff against a revision (#443)
// ============================================================
//
// Loads the application's feature graph at a git revision and at
// the working tree, and compares them with the same core the CLI
// uses (`FeatureGraphDiff` in AROParser) — so `aro diff --graph`
// in a terminal and the sheet in the IDE cannot drift apart.
//
// Git is shelled out to rather than read through libgit2: reading
// a tree is two plumbing commands, and SOLARO already talks to the
// git CLI everywhere else (GitStatusMonitor, the commit overlay).

import Foundation
import Observation
import AROParser

@MainActor
@Observable
final class GraphDiffModel {
    /// What is being compared (#767).
    ///
    /// The view used to accept one typed revision and always compare it
    /// against the working tree, while the CLI has supported
    /// `main..my-branch` ranges since `aro diff --graph` existed. A
    /// reviewer's actual question is "what did this branch change in
    /// the graph", and that needs two revisions.
    var baseRevision: String = "HEAD"

    /// The other side. Empty means the working tree, which is what the
    /// view has always compared against and stays the default.
    var targetRevision: String = ""

    /// A `a..b` range as the CLI spells it, for display and for handing
    /// to `aro diff --graph`.
    var rangeExpression: String {
        targetRevision.isEmpty
            ? baseRevision
            : "\(baseRevision)..\(targetRevision)"
    }

    /// Accept a range typed into one field, so `main..topic` pasted
    /// from a terminal does what it says.
    func setRange(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.range(of: "..") else {
            baseRevision = trimmed
            targetRevision = ""
            return
        }
        baseRevision = String(trimmed[trimmed.startIndex..<separator.lowerBound])
        targetRevision = String(trimmed[separator.upperBound...])
    }

    private(set) var diff: FeatureGraphDiff?
    private(set) var isLoading = false
    private(set) var error: String?

    func load(project: Project) async {
        // The graph is built from the files on disk (#748).
        EditorWriteQueue.flushNow()
        isLoading = true
        error = nil
        let base = baseRevision.trimmingCharacters(in: .whitespaces)
        let target = targetRevision.trimmingCharacters(in: .whitespaces)
        let root = project.rootPath
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.build(root: root, base: base,
                       target: target.isEmpty ? nil : target)
        }.value
        switch outcome {
        case .success(let value):
            diff = value
            error = nil
        case .failure(let message):
            diff = nil
            error = message
        }
        isLoading = false
    }

    // MARK: - HTML export (#767)

    /// Whether an export is running, so the button can say so.
    private(set) var isExporting = false

    /// Write the CLI's own HTML report for the current comparison.
    ///
    /// Shells out rather than reimplementing the renderer: `aro diff
    /// --graph --html` already produces the report people share in
    /// review, and a second implementation would drift from it.
    func exportHTML(project: Project, to destination: URL) async {
        isExporting = true
        defer { isExporting = false }
        // The report is built from the files on disk.
        EditorWriteQueue.flushNow()
        let range = rangeExpression
        let root = project.rootPath
        let aro = ConsoleProcess.resolveAroBinary(near: project)
        let result = await Task.detached(priority: .userInitiated) { () -> String? in
            let run = Self.git(binary: aro,
                               args: ["diff", "--graph", range,
                                      "--html", destination.path],
                               in: root)
            guard run.exitCode == 0 else {
                return run.stderr.isEmpty
                    ? "aro diff exited \(run.exitCode)"
                    : run.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }.value
        error = result
    }

    // MARK: - Off-main work

    private enum Outcome {
        case success(FeatureGraphDiff)
        case failure(String)
    }

    /// Compare `base` against `target`, or against the working tree
    /// when `target` is nil (#767).
    private nonisolated static func build(root: URL, base: String,
                                          target: String?) -> Outcome {
        let before: [String: FeatureGraph.Source]
        switch filesAtRevision(base, in: root) {
        case .failure(let message): return .failure(message)
        case .success(let files):   before = files
        }

        let after: [String: FeatureGraph.Source]
        if let target {
            switch filesAtRevision(target, in: root) {
            case .failure(let message): return .failure(message)
            case .success(let files):   after = files
            }
        } else {
            after = filesInWorkingTree(at: root)
        }

        return .success(FeatureGraphDiff.compare(
            before: FeatureGraph.build(files: before),
            after: FeatureGraph.build(files: after),
            beforeLabel: base,
            afterLabel: target ?? "working tree"))
    }

    private enum FileOutcome {
        case success([String: FeatureGraph.Source])
        case failure(String)
    }

    private nonisolated static func filesAtRevision(
        _ revision: String, in root: URL
    ) -> FileOutcome {
        let listing = git(["ls-tree", "-r", "--name-only", revision], in: root)
        guard listing.exitCode == 0 else {
            return .failure(listing.stderr.isEmpty
                ? "Unknown revision '\(revision)'"
                : listing.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var files: [String: FeatureGraph.Source] = [:]
        for line in listing.stdout.split(whereSeparator: \.isNewline) {
            guard line.hasSuffix(".aro") else { continue }
            let path = String(line)
            let show = git(["show", "\(revision):\(path)"], in: root)
            guard show.exitCode == 0 else { continue }
            files[path] = source(show.stdout)
        }
        return .success(files)
    }

    private nonisolated static func filesInWorkingTree(
        at root: URL
    ) -> [String: FeatureGraph.Source] {
        var files: [String: FeatureGraph.Source] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            // An `.aro` under `.build` belongs to a dependency's
            // fixtures, not to this application.
            if [".git", ".build", "node_modules"].contains(url.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            guard url.pathExtension == "aro" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Same key shape as `git ls-tree`, so the two sides of
            // the comparison line up.
            let relative = url.standardizedFileURL.path
                .replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
            files[relative] = source(text)
        }
        return files
    }

    /// Parsing is deliberately tolerant: a diff is exactly when
    /// half-finished code shows up, and refusing to draw the other
    /// side helps nobody.
    private nonisolated static func source(_ text: String) -> FeatureGraph.Source {
        FeatureGraph.Source(text: text, program: try? Parser.parse(text))
    }

    private struct GitRun {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Run an arbitrary binary the same way `git` is run above, so the
    /// `aro diff --html` export shares the pipe handling (#767).
    private nonisolated static func git(binary: String, args: [String],
                                        in root: URL) -> GitRun {
        let task = Process()
        if binary == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["aro"] + args
        } else {
            task.executableURL = URL(fileURLWithPath: binary)
            task.arguments = args
        }
        return run(task, in: root)
    }

    private nonisolated static func git(_ args: [String], in root: URL) -> GitRun {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git"] + args
        return run(task, in: root)
    }

    private nonisolated static func run(_ task: Process, in root: URL) -> GitRun {
        task.currentDirectoryURL = root
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return GitRun(
                exitCode: task.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? "")
        } catch {
            return GitRun(exitCode: -1, stdout: "",
                          stderr: error.localizedDescription)
        }
    }
}
