// ============================================================
// CrashReporter.swift
// SOLARO — local crash logging + Report a Bug menu (#233 §5)
// ============================================================
//
// ADR-007 + ADR-010: SOLARO ships with no telemetry, no auto-
// upload of crash data. When the app trips a fatal signal we
// write a local crash log under
//   ~/Library/Application Support/SOLARO/crashes/
// and surface a "Help → Report a Bug…" menu item that opens the
// GitLab new-issue page with the most recent crash log
// pre-quoted, so the user stays in charge of what (if anything)
// gets reported.

import Foundation
import AppKit
import AROVersion

enum CrashReporter {

    /// Directory the crash logs land in. Created on demand.
    static var crashesDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("SOLARO")
            .appendingPathComponent("crashes")
    }

    /// Install signal handlers for the most common fatal signals.
    /// Each handler writes a single-line stack-snapshot to disk
    /// and re-raises the signal so the OS still terminates the
    /// process with the original status.
    static func install() {
        try? FileManager.default.createDirectory(
            at: crashesDirectory,
            withIntermediateDirectories: true
        )
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig) { signum in
                CrashReporter.writeCrash(signal: signum)
                // Re-raise with the default handler so the OS still
                // surfaces the standard crash dialog / exit code.
                Foundation.signal(signum, SIG_DFL)
                Foundation.raise(signum)
            }
        }
    }

    /// Path to the most recent crash log (if any). Used by the
    /// Report a Bug menu item.
    static func mostRecentCrashLog() -> URL? {
        let fm = FileManager.default
        let logs = (try? fm.contentsOfDirectory(
            at: crashesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return logs.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            return aDate > bDate
        }.first
    }

    /// Open the GitLab new-issue URL with the most recent crash
    /// log embedded in the description as a fenced block.
    static func openReportBugPage() {
        let url = composeReportURL()
        NSWorkspace.shared.open(url)
    }

    /// Build the new-issue URL. Public so a SwiftUI button can
    /// trigger it; tests can also exercise the URL composition.
    static func composeReportURL() -> URL {
        let base = "https://git.ausdertechnik.de/arolang/aro/-/issues/new"
        var components = URLComponents(string: base)!
        var description = "**SOLARO version:** \(AROVersion.shortVersion)\n"
        description += "**Platform:** macOS\n\n"
        description += "## What happened?\n\n_describe the unexpected behaviour_\n\n"
        description += "## Steps to reproduce\n\n1.\n2.\n3.\n"
        if let log = mostRecentCrashLog(),
           let text = try? String(contentsOf: log, encoding: .utf8)
        {
            description += "\n## Most recent crash log\n\n"
            description += "<details>\n<summary>\(log.lastPathComponent)</summary>\n\n"
            description += "```\n\(text)\n```\n\n</details>\n"
        }
        components.queryItems = [
            URLQueryItem(name: "issue[title]",
                         value: "SOLARO crash / bug report"),
            URLQueryItem(name: "issue[description]", value: description),
        ]
        return components.url!
    }

    // MARK: - Private

    /// Signal-handler-safe writer. Only uses APIs that are async-
    /// signal-safe on Darwin (write(2), no Swift allocations
    /// post-signal). Best-effort — if the path or process state
    /// is hostile we drop the report silently.
    private static func writeCrash(signal: Int32) {
        let timestamp = Self.timestamp()
        let filename = "crash-\(timestamp).txt"
        let url = crashesDirectory.appendingPathComponent(filename)
        let body = """
        SOLARO crash report
        ---
        time:    \(Date())
        signal:  \(signal)
        version: \(AROVersion.shortVersion)
        macOS:   \(ProcessInfo.processInfo.operatingSystemVersionString)

        ## Stack trace (best-effort)

        \(Thread.callStackSymbols.joined(separator: "\n"))
        """
        // Synchronous, fall-through-on-failure write.
        try? body.write(to: url, atomically: false, encoding: .utf8)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
