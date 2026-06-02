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

@MainActor
@Observable
final class GitStatusMonitor {
    private(set) var status: GitStatus = .init()
    private(set) var isAvailable: Bool = false
    private(set) var lastError: String?

    func refresh(for project: Project) {
        Task.detached(priority: .utility) {
            let result = await Self.run(project: project)
            await MainActor.run {
                self.isAvailable = result.available
                self.status = result.status
                self.lastError = result.error
            }
        }
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
