// ============================================================
// CrashSubmission.swift
// SOLARO — explicit, user-confirmed crash upload (#275)
// ============================================================
//
// ADR-007/010 rule out silent uploads, so this is deliberately
// the least automatic thing that still saves the user work: they
// read the exact text, they press the button, and only then does
// anything leave the machine.
//
// Destination is **GitLab** (`origin`), never the GitHub mirror —
// #275 says so explicitly and it matches the project's standing
// rule about remotes.
//
// Two paths, because `glab` may not be installed or logged in:
//   1. `glab issue create` — one click, issue URL comes back.
//   2. the GitLab new-issue web form, pre-filled — the user still
//      presses Submit themselves.

import Foundation
import AppKit
import AROVersion

enum CrashSubmission {
    /// Canonical remote. The GitHub repo is a mirror; bug reports
    /// and crash logs go to `origin`.
    static let host = "git.ausdertechnik.de"
    static let projectPath = "arolang/aro"

    /// Title for the filed issue.
    static func composeTitle(for report: CrashReport) -> String {
        let version = report.version ?? AROVersion.shortVersion
        return "SOLARO crash: \(report.signalName) in \(version)"
    }

    /// Issue body. Everything the user is about to publish is in
    /// this string — the confirmation sheet shows it verbatim, so
    /// there is nothing attached that they did not read.
    static func composeBody(for report: CrashReport,
                            note: String = "") -> String {
        var body = ""
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body += "## What I was doing\n\n\(note)\n\n"
        }
        body += "## Environment\n\n"
        body += "- SOLARO: \(report.version ?? AROVersion.shortVersion)\n"
        body += "- Signal: \(report.signalName)\n"
        body += "- When: \(CrashReport.displayFormatter.string(from: report.date))\n"
        body += "- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        body += "## Crash log\n\n"
        body += "<details>\n<summary>\(report.fileName)</summary>\n\n"
        body += "```\n\(report.text)\n```\n\n</details>\n"
        return body
    }

    /// Pre-filled new-issue URL — GitLab's form uses
    /// `issue[title]` / `issue[description]`, not GitHub's
    /// `title` / `body`.
    static func newIssueURL(for report: CrashReport,
                            note: String = "") -> URL? {
        var components = URLComponents(
            string: "https://\(host)/\(projectPath)/-/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "issue[title]", value: composeTitle(for: report)),
            URLQueryItem(name: "issue[description]",
                         value: composeBody(for: report, note: note)),
        ]
        return components?.url
    }

    /// First `https://…` in `glab issue create` output — it prints
    /// the new issue's URL on success.
    static func issueURL(fromCLIOutput output: String) -> URL? {
        for field in output.split(whereSeparator: \.isWhitespace) {
            let token = field.trimmingCharacters(
                in: CharacterSet(charactersIn: "()[]<>,."))
            if token.hasPrefix("https://"), let url = URL(string: token) {
                return url
            }
        }
        return nil
    }

    /// Locate `glab`. `Process` doesn't consult PATH the way a
    /// shell does, and a GUI app's PATH is the launchd one — which
    /// is why the Homebrew prefixes are checked explicitly.
    static func glabExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/glab",
            "/usr/local/bin/glab",
            "/usr/bin/glab",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    enum SubmissionResult {
        case filed(URL)
        /// `glab` ran and failed; the message is its stderr.
        case failed(String)
        /// `glab` isn't installed — the caller falls back to the web form.
        case unavailable
    }

    /// File the issue through `glab`. Blocking; call it off the
    /// main actor.
    ///
    /// `GITLAB_HOST` is set explicitly: outside a repository
    /// directory `glab` otherwise talks to gitlab.com and fails
    /// with a bare 401.
    static func submitViaCLI(report: CrashReport, note: String) -> SubmissionResult {
        guard let glab = glabExecutable() else { return .unavailable }

        let process = Process()
        process.executableURL = glab
        process.arguments = [
            "issue", "create",
            "--repo", projectPath,
            "--title", composeTitle(for: report),
            "--description", composeBody(for: report, note: note),
            "--yes",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["GITLAB_HOST"] = host
        process.environment = environment

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus == 0,
           let url = issueURL(fromCLIOutput: stdout + "\n" + stderr)
        {
            return .filed(url)
        }
        let message = stderr.isEmpty ? stdout : stderr
        return .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
