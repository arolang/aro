// ============================================================
// DiffCommand.swift
// ARO CLI — `aro diff --graph` (GitLab #443)
// ============================================================
//
// `git diff` answers "which lines changed". Reviewing an ARO
// change, the useful question is "which feature sets changed, what
// happened inside them, and which wires between them moved" — a
// statement that shifted because something was inserted above it is
// noise, a `Retrieve` whose repository changed is one edited step
// rather than a deletion plus an insertion, and a feature set that
// moved to another file is the same node at a new address.
//
// So this builds the application graph at both revisions (see
// `FeatureGraph` in AROParser — same wiring rules the runtime
// registers by) and compares them. Every `.aro` file folds into one
// graph because that is what the runtime does: no imports, every
// feature set globally visible.
//
// `--html` writes the same comparison as a self-contained report
// with the two graphs side by side, which is what a merge request
// can link to.

import ArgumentParser
import Foundation
import AROParser

struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare ARO feature-set graphs between two revisions"
    )

    @Argument(help: """
        Git revision range, e.g. `main..my-branch`, or a single \
        revision to compare the working tree against (`main`).
        """)
    var range: String

    @Option(name: .long, help: "Project directory (default: current)")
    var directory: String = "."

    @Flag(name: .long, help: "Graph-level diff (feature sets + statements)")
    var graph: Bool = false

    @Option(name: .long, help: "Write a self-contained HTML report to this path")
    var html: String?

    @Flag(name: .long, help: "List untouched feature sets too")
    var all: Bool = false

    func run() throws {
        // `--graph` is the only mode today. Requiring it keeps the
        // door open for a plain textual mode later without changing
        // what an existing invocation means.
        guard graph else {
            throw ValidationError(
                "aro diff currently implements --graph only. "
                + "Use `git diff` for a textual comparison.")
        }

        let root = URL(fileURLWithPath: directory).standardizedFileURL
        let (beforeRef, afterRef) = try Self.parseRange(range)

        let beforeSources = try Self.aroSources(at: beforeRef, root: root)
        let afterSources = try Self.aroSources(at: afterRef, root: root)

        let diff = FeatureGraphDiff.compare(
            before: FeatureGraph.build(files: beforeSources.mapValues(Self.file)),
            after: FeatureGraph.build(files: afterSources.mapValues(Self.file)),
            beforeLabel: beforeRef,
            afterLabel: afterRef ?? "working tree")

        if let html {
            let report = GraphDiffHTMLReport.render(
                range: range, diff: diff, includeUnchanged: all)
            try report.write(to: URL(fileURLWithPath: html),
                             atomically: true, encoding: .utf8)
            print("Wrote \(html)")
        }

        printSummary(diff)
    }

    // MARK: - Terminal report

    private func printSummary(_ diff: FeatureGraphDiff) {
        guard !diff.isEmpty || all else {
            print("No feature-set changes between \(range).")
            return
        }
        print("Graph diff \(range)")
        print(String(repeating: "─", count: 62))
        print(diff.summaryLine)

        section("Added", diff.nodes(.added), marker: "+")
        section("Removed", diff.nodes(.removed), marker: "-")
        section("Modified", diff.nodes(.modified), marker: "~")

        // A move changes two files and nothing about the program.
        // Worth naming, not worth a statement listing.
        let moved = diff.nodes.filter { $0.movedFile && $0.change == .unchanged }
        if !moved.isEmpty {
            print("\nMoved (\(moved.count))")
            for node in moved {
                print("  → (\(node.name): \(node.businessActivity))"
                      + "  \(node.beforeFile ?? "?") → \(node.afterFile ?? "?")")
            }
        }

        if all {
            let untouched = diff.nodes.filter { $0.isUntouched && !$0.movedFile }
            if !untouched.isEmpty {
                print("\nUnchanged (\(untouched.count))")
                for node in untouched {
                    print("    (\(node.name): \(node.businessActivity))  \(node.file)")
                }
            }
        }

        printWires(diff)
    }

    private func section(_ title: String,
                         _ nodes: [FeatureGraphDiff.NodeDiff],
                         marker: String)
    {
        guard !nodes.isEmpty else { return }
        print("\n\(title) (\(nodes.count))")
        for node in nodes {
            print("  \(marker) (\(node.name): \(node.businessActivity))"
                  + "  [\(node.kind.label)]  \(node.file)")
            if let previous = node.previousBusinessActivity {
                print("      activity: \(previous) → \(node.businessActivity)")
            }
            if node.movedFile {
                print("      moved: \(node.beforeFile ?? "?") → \(node.afterFile ?? "?")")
            }
            for statement in node.statements where statement.change != .unchanged {
                switch statement.change {
                case .modified:
                    print("      ~ \(statement.before ?? "")")
                    print("        → \(statement.after ?? "")")
                case .added:
                    print("      + \(statement.after ?? "")")
                case .removed:
                    print("      - \(statement.before ?? "")")
                case .unchanged:
                    break
                }
            }
        }
    }

    /// The wires. This is the part a textual diff cannot show: one
    /// deleted `Emit` line silences a whole handler, and that only
    /// reads as a change if you print the edge that vanished.
    private func printWires(_ diff: FeatureGraphDiff) {
        let changed = diff.edges.filter { $0.change != .unchanged }
        let shown = all ? diff.edges : changed
        guard !shown.isEmpty else { return }
        print("\nWires (+\(diff.edges(.added).count) −\(diff.edges(.removed).count))")
        for entry in shown {
            let marker: String
            switch entry.change {
            case .added:   marker = "+"
            case .removed: marker = "-"
            default:       marker = " "
            }
            print("  \(marker) \(entry.edge.from) ──\(entry.edge.kind.rawValue)"
                  + "(\(entry.edge.label))──▶ \(entry.edge.to)")
        }
    }

    // MARK: - Git plumbing

    /// `a..b` → (a, b); a bare `a` → (a, nil), meaning "compare
    /// against the working tree".
    static func parseRange(_ range: String) throws -> (String, String?) {
        // `...` (symmetric difference) is not what a graph diff
        // means, so it's rejected rather than silently treated as
        // `..` — the two select different commits.
        if range.contains("...") {
            throw ValidationError(
                "Symmetric ranges (`...`) aren't supported — use `a..b`.")
        }
        guard let separator = range.range(of: "..") else {
            return (range, nil)
        }
        let before = String(range[range.startIndex..<separator.lowerBound])
        let after = String(range[separator.upperBound...])
        guard !before.isEmpty else {
            throw ValidationError("Range is missing its left revision: \(range)")
        }
        return (before, after.isEmpty ? nil : after)
    }

    /// Every `.aro` file at a revision, keyed by repo-relative path.
    /// A nil revision reads the working tree.
    static func aroSources(at revision: String?, root: URL) throws -> [String: String] {
        guard let revision else {
            return try workingTreeSources(root: root)
        }
        let listing = try git(["ls-tree", "-r", "--name-only", revision], in: root)
        var sources: [String: String] = [:]
        for path in listing.split(whereSeparator: \.isNewline) {
            guard path.hasSuffix(".aro") else { continue }
            let file = String(path)
            sources[file] = try git(["show", "\(revision):\(file)"], in: root)
        }
        return sources
    }

    /// Directories a build drops sources into. An `.aro` file under
    /// `.build` belongs to a dependency's fixtures, not to this
    /// application, and folding it into the graph would invent
    /// feature sets that only one side of the comparison has.
    static let skippedDirectories: Set<String> = [".git", ".build", "node_modules"]

    static func workingTreeSources(root: URL) throws -> [String: String] {
        var sources: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if skippedDirectories.contains(url.lastPathComponent) {
                enumerator?.skipDescendants()
                continue
            }
            guard url.pathExtension == "aro" else { continue }
            // Keep the key shape identical to `git ls-tree` output so
            // the two sides of the comparison line up.
            let relative = url.standardizedFileURL.path
                .replacingOccurrences(of: root.path + "/", with: "")
            sources[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return sources
    }

    /// One file of the application, parsed. Parsing is tolerant of
    /// a file that doesn't compile on one side — a diff is exactly
    /// when half-finished code shows up, and refusing to render the
    /// other side helps nobody. The text rides along so statements
    /// display as the code the author wrote.
    static func file(_ source: String) -> FeatureGraph.Source {
        FeatureGraph.Source(text: source, program: try? Parser.parse(source))
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw ValidationError(
                "git \(arguments.joined(separator: " ")) failed: "
                + message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
