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
    /// Revision the working tree is compared against.
    var baseRevision: String = "HEAD"

    private(set) var diff: FeatureGraphDiff?
    private(set) var isLoading = false
    private(set) var error: String?

    func load(project: Project) async {
        isLoading = true
        error = nil
        let base = baseRevision.trimmingCharacters(in: .whitespaces)
        let root = project.rootPath
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.build(root: root, base: base)
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

    // MARK: - Off-main work

    private enum Outcome {
        case success(FeatureGraphDiff)
        case failure(String)
    }

    private nonisolated static func build(root: URL, base: String) -> Outcome {
        let listing = git(["ls-tree", "-r", "--name-only", base], in: root)
        guard listing.exitCode == 0 else {
            return .failure(listing.stderr.isEmpty
                ? "Unknown revision '\(base)'"
                : listing.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var beforeFiles: [String: FeatureGraph.Source] = [:]
        for line in listing.stdout.split(whereSeparator: \.isNewline) {
            guard line.hasSuffix(".aro") else { continue }
            let path = String(line)
            let show = git(["show", "\(base):\(path)"], in: root)
            guard show.exitCode == 0 else { continue }
            beforeFiles[path] = source(show.stdout)
        }

        var afterFiles: [String: FeatureGraph.Source] = [:]
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
            afterFiles[relative] = source(text)
        }

        return .success(FeatureGraphDiff.compare(
            before: FeatureGraph.build(files: beforeFiles),
            after: FeatureGraph.build(files: afterFiles),
            beforeLabel: base,
            afterLabel: "working tree"))
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

    private nonisolated static func git(_ args: [String], in root: URL) -> GitRun {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git"] + args
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
