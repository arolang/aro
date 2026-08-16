// ============================================================
// DiffCommand.swift
// ARO CLI — `aro diff --graph` (GitLab #443)
// ============================================================
//
// `git diff` answers "which lines changed". Reviewing an ARO
// change, the useful question is "which feature sets changed, and
// what happened inside them" — a statement that moved because
// something was inserted above it is noise, and a `Retrieve` whose
// repository changed is not a deletion plus an insertion, it's one
// edited step.
//
// So this diffs the parsed programs (see `AROGraphDiff` in
// AROParser) and reports per feature set. `--html` writes the same
// comparison as a self-contained report, which is what a merge
// request can link to.

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

        let beforeFiles = try Self.aroSources(at: beforeRef, root: root)
        let afterFiles = try Self.aroSources(at: afterRef, root: root)

        let paths = Set(beforeFiles.keys).union(afterFiles.keys).sorted()
        var results: [(path: String, diff: AROGraphDiff)] = []
        for path in paths {
            let before = beforeFiles[path].flatMap(Self.parse)
            let after = afterFiles[path].flatMap(Self.parse)
            let diff = AROGraphDiff.compare(before: before, after: after)
            if all || !diff.isEmpty {
                results.append((path, diff))
            }
        }

        if let html {
            let report = GraphDiffHTMLReport.render(
                range: range, results: results)
            try report.write(to: URL(fileURLWithPath: html),
                             atomically: true, encoding: .utf8)
            print("Wrote \(html)")
        }

        printSummary(results)
    }

    private func printSummary(_ results: [(path: String, diff: AROGraphDiff)]) {
        guard !results.isEmpty else {
            print("No feature-set changes between \(range).")
            return
        }
        print("Graph diff \(range)")
        print(String(repeating: "─", count: 60))
        for (path, diff) in results {
            print("\n\(path)  —  \(diff.summaryLine)")
            for set in diff.featureSets where all || !set.isUntouched {
                print("  \(marker(set.change)) (\(set.name): \(set.businessActivity))")
                for statement in set.statements where statement.change != .unchanged {
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
    }

    private func marker(_ change: GraphChange) -> String {
        switch change {
        case .added:     return "+"
        case .removed:   return "-"
        case .modified:  return "~"
        case .unchanged: return " "
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

    static func workingTreeSources(root: URL) throws -> [String: String] {
        var sources: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "aro" else { continue }
            // Keep the key shape identical to `git ls-tree` output so
            // the two sides of the comparison line up.
            let relative = url.standardizedFileURL.path
                .replacingOccurrences(of: root.path + "/", with: "")
            sources[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return sources
    }

    /// Parse, tolerating a file that doesn't compile on one side —
    /// a diff is exactly when half-finished code shows up, and
    /// refusing to render the other side helps nobody.
    static func parse(_ source: String) -> Program? {
        try? Parser.parse(source)
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

// MARK: - HTML report

/// Self-contained HTML — no external CSS or JS, so the file can be
/// attached to a merge request or opened from a CI artifact
/// without a network round trip.
enum GraphDiffHTMLReport {
    static func render(range: String,
                       results: [(path: String, diff: AROGraphDiff)]) -> String
    {
        var body = ""
        for (path, diff) in results {
            body += "<section><h2>\(escape(path))</h2>"
            body += "<p class=\"summary\">\(escape(diff.summaryLine))</p>"
            for set in diff.featureSets where !set.isUntouched {
                body += "<div class=\"fs \(set.change.rawValue)\">"
                body += "<h3>\(escape(set.name))"
                body += "<span class=\"activity\">\(escape(set.businessActivity))</span>"
                body += "<span class=\"badge\">\(set.change.rawValue)</span></h3>"
                for statement in set.statements {
                    let cssClass = statement.change.rawValue
                    switch statement.change {
                    case .modified:
                        body += "<div class=\"stmt modified\">"
                        body += "<del>\(escape(statement.before ?? ""))</del>"
                        body += "<ins>\(escape(statement.after ?? ""))</ins></div>"
                    case .added:
                        body += "<div class=\"stmt \(cssClass)\">+ \(escape(statement.after ?? ""))</div>"
                    case .removed:
                        body += "<div class=\"stmt \(cssClass)\">− \(escape(statement.before ?? ""))</div>"
                    case .unchanged:
                        body += "<div class=\"stmt \(cssClass)\">\(escape(statement.display))</div>"
                    }
                }
                body += "</div>"
            }
            body += "</section>"
        }
        if results.isEmpty {
            body = "<p class=\"empty\">No feature-set changes.</p>"
        }

        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <title>ARO graph diff — \(escape(range))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px/1.5 ui-sans-serif, system-ui, sans-serif;
               margin: 0 auto; max-width: 60rem; padding: 2rem; }
        h1 { font-size: 1.3rem; }
        h2 { font-size: 1rem; font-family: ui-monospace, monospace;
             border-bottom: 1px solid #8884; padding-bottom: .3rem; }
        h3 { font-size: .95rem; display: flex; gap: .5rem; align-items: baseline; }
        .activity { font-weight: 400; opacity: .6; font-size: .8rem; }
        .badge { margin-left: auto; font-size: .7rem; text-transform: uppercase;
                 letter-spacing: .08em; opacity: .7; }
        .summary { opacity: .7; font-size: .85rem; }
        .fs { border-left: 3px solid #8886; padding-left: .8rem; margin: 1rem 0; }
        .fs.added { border-color: #3fb950; }
        .fs.removed { border-color: #f85149; }
        .fs.modified { border-color: #d29922; }
        .stmt { font-family: ui-monospace, monospace; font-size: .82rem;
                padding: .15rem .4rem; border-radius: 3px; white-space: pre-wrap; }
        .stmt.unchanged { opacity: .45; }
        .stmt.added { background: #3fb95022; }
        .stmt.removed { background: #f8514922; }
        .stmt.modified del { display: block; background: #f8514922;
                             text-decoration: none; opacity: .8; }
        .stmt.modified ins { display: block; background: #3fb95022;
                             text-decoration: none; }
        .empty { opacity: .6; }
        </style></head><body>
        <h1>ARO graph diff <code>\(escape(range))</code></h1>
        \(body)
        </body></html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
