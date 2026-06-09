// ============================================================
// RecentProjectMetadata.swift
// SOLARO — sidecar metadata rendered on the welcome screen cards
// ============================================================
//
// Per issue #276. The welcome screen replaces text-only recents with
// cards that show "at-a-glance" info: when the project was last
// touched, how many feature sets it has, what git branch it's on,
// and how far ahead / behind of origin. This file owns the
// background fetcher that produces a `RecentProjectMetadata` value
// for each `Project` so the SwiftUI view stays presentation-only.

import Foundation
import AROParser

/// Snapshot rendered on a single recent-project card.
struct RecentProjectMetadata: Sendable, Equatable {
    let lastModified: Date?
    let featureSetCount: Int?
    let git: GitStatus?

    struct GitStatus: Sendable, Equatable {
        let branch: String
        let ahead: Int
        let behind: Int
        let dirty: Bool
    }

    static let empty = RecentProjectMetadata(
        lastModified: nil,
        featureSetCount: nil,
        git: nil
    )
}

/// Pulls together the per-card metadata off the main actor. Each
/// piece is best-effort — a missing git binary or unreadable file
/// just leaves that field nil so the card still renders the parts
/// it has.
enum RecentProjectMetadataLoader {

    static func load(_ project: Project) async -> RecentProjectMetadata {
        async let mtime = lastModified(of: project)
        async let count = featureSetCount(of: project)
        async let git = gitStatus(of: project)
        return RecentProjectMetadata(
            lastModified: await mtime,
            featureSetCount: await count,
            git: await git
        )
    }

    /// Newest mtime across the project root and any of its `.aro`
    /// source files. Recursing one level deep is enough for the
    /// usual project layout; deeper trees would just make the
    /// "last modified" stamp flicker on every save in any
    /// subfolder.
    private static func lastModified(of project: Project) async -> Date? {
        let fm = FileManager.default
        var newest: Date? = nil
        let url = project.rootPath
        if let stamp = mtime(at: url) { newest = stamp }
        for sub in (try? fm.contentsOfDirectory(at: url,
                                                includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if sub.pathExtension.lowercased() == "aro" {
                if let stamp = mtime(at: sub),
                   stamp > (newest ?? .distantPast) {
                    newest = stamp
                }
            }
        }
        return newest
    }

    /// Parse every `.aro` file in the project root and sum
    /// `featureSets.count`. Cheap on typical project sizes (single-
    /// digit ms) and worth doing lazily on the card's `.task` —
    /// the welcome screen never displays more than ~10 cards.
    private static func featureSetCount(of project: Project) async -> Int? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: project.rootPath,
            includingPropertiesForKeys: nil
        ) else { return nil }
        let compiler = Compiler()
        var total = 0
        for file in files where file.pathExtension.lowercased() == "aro" {
            guard let text = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            let result = compiler.compile(text)
            total += result.analyzedProgram.featureSets.count
        }
        return total
    }

    /// Branch + ahead / behind + dirty from a single
    /// `git status --porcelain=v1 -b` invocation. Returns nil
    /// when the directory isn't a git repo or git isn't installed.
    private static func gitStatus(of project: Project) async -> RecentProjectMetadata.GitStatus? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git", "status", "--porcelain=v1", "-b"]
        task.currentDirectoryURL = project.rootPath
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseGitStatus(raw)
    }

    static func parseGitStatus(_ raw: String) -> RecentProjectMetadata.GitStatus? {
        let lines = raw.split(separator: "\n",
                              omittingEmptySubsequences: false)
        guard let header = lines.first,
              header.hasPrefix("## ") else { return nil }
        let body = String(header.dropFirst(3))
        // Possible shapes:
        //   "main"
        //   "main...origin/main"
        //   "main...origin/main [ahead 2]"
        //   "main...origin/main [ahead 2, behind 3]"
        //   "HEAD (no branch)"
        var branch = body
        var ahead = 0
        var behind = 0
        if let bracket = branch.range(of: " [") {
            let aheadBehindPart = String(branch[bracket.upperBound...]
                .dropLast()) // drop trailing ']'
            branch = String(branch[..<bracket.lowerBound])
            for piece in aheadBehindPart.split(separator: ",") {
                let piece = piece.trimmingCharacters(in: .whitespaces)
                if piece.hasPrefix("ahead "), let n = Int(piece.dropFirst(6)) {
                    ahead = n
                }
                if piece.hasPrefix("behind "), let n = Int(piece.dropFirst(7)) {
                    behind = n
                }
            }
        }
        if let tripleDot = branch.range(of: "...") {
            branch = String(branch[..<tripleDot.lowerBound])
        }
        let dirty = lines.dropFirst().contains { line in
            !line.isEmpty && !line.hasPrefix("## ")
        }
        return .init(branch: branch, ahead: ahead, behind: behind,
                     dirty: dirty)
    }

    private static func mtime(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }
}
