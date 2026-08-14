// ============================================================
// CrashReportStore.swift
// SOLARO — reading back what CrashReporter wrote (#275)
// ============================================================
//
// CrashReporter has been writing logs to
// ~/Library/Application Support/SOLARO/crashes/ since #233, and
// until now the only way to see one was Finder. This is the read
// side: parse the files into records the UI can list, and track
// which ones the user has already been shown so the welcome
// screen can raise a crash *once* rather than every launch.
//
// Nothing here uploads anything. Submission is a separate,
// explicit click — see CrashLogsSheet.

import Foundation
import AROVersion

/// One crash log on disk, parsed far enough to list it.
struct CrashReport: Identifiable, Hashable, Sendable {
    var url: URL
    /// Timestamp from the filename (`crash-yyyyMMdd-HHmmss.txt`),
    /// falling back to the file's mtime when the name doesn't
    /// match — a hand-copied file is still worth listing.
    var date: Date
    /// Signal number from the `signal:` header, when present.
    var signal: Int32?
    /// SOLARO version from the `version:` header.
    var version: String?
    /// Full file contents.
    var text: String

    var id: String { url.path }

    var fileName: String { url.lastPathComponent }

    /// `SIGSEGV (11)` — the number alone tells the user nothing.
    var signalName: String {
        guard let signal else { return "unknown" }
        let names: [Int32: String] = [
            SIGABRT: "SIGABRT", SIGSEGV: "SIGSEGV", SIGBUS: "SIGBUS",
            SIGILL: "SIGILL", SIGFPE: "SIGFPE", SIGTRAP: "SIGTRAP",
            SIGKILL: "SIGKILL", SIGTERM: "SIGTERM",
        ]
        guard let name = names[signal] else { return "signal \(signal)" }
        return "\(name) (\(signal))"
    }

    /// One-line summary for the list row.
    var summary: String {
        let stamp = CrashReport.displayFormatter.string(from: date)
        return "\(stamp) · \(signalName)"
    }

    static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Filename stamps are UTC (`CrashReporter.timestamp()`).
    static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Parse one log. `modified` is the filesystem fallback for the
    /// date when the filename isn't in the expected shape.
    static func parse(url: URL, text: String, modified: Date) -> CrashReport {
        var signal: Int32?
        var version: String?
        // Header block is `key: value` lines before the first `##`.
        for line in text.split(omittingEmptySubsequences: true,
                               whereSeparator: \.isNewline)
        {
            if line.hasPrefix("##") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "signal":  signal = Int32(value)
            case "version": version = value
            default:        break
            }
        }
        return CrashReport(
            url: url,
            date: dateFromFileName(url.lastPathComponent) ?? modified,
            signal: signal,
            version: version,
            text: text
        )
    }

    /// `crash-20260814-093015.txt` → that instant, or nil.
    static func dateFromFileName(_ name: String) -> Date? {
        guard name.hasPrefix("crash-") else { return nil }
        var stamp = String(name.dropFirst("crash-".count))
        if let dot = stamp.lastIndex(of: ".") {
            stamp = String(stamp[stamp.startIndex..<dot])
        }
        return fileNameFormatter.date(from: stamp)
    }
}

@MainActor
@Observable
final class CrashReportStore {
    /// Newest first.
    private(set) var reports: [CrashReport] = []

    /// Filename of the newest crash the user has already been
    /// shown. The welcome banner keys off this so a crash raises
    /// itself once, not on every launch afterwards.
    private static let lastSeenKey = "solaro.crash.lastSeenFile"

    private let directory: URL

    init(directory: URL = CrashReporter.crashesDirectory) {
        self.directory = directory
    }

    func reload() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            reports = []
            return
        }
        reports = urls
            .filter { $0.pathExtension.lowercased() == "txt" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8)
                else { return nil }
                let modified = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return CrashReport.parse(url: url, text: text, modified: modified)
            }
            .sorted { $0.date > $1.date }
    }

    /// The newest crash the user hasn't been shown yet, if any.
    var unseenReport: CrashReport? {
        guard let newest = reports.first else { return nil }
        let lastSeen = UserDefaults.standard.string(forKey: Self.lastSeenKey)
        return newest.fileName == lastSeen ? nil : newest
    }

    /// Mark everything up to the newest as seen. Called when the
    /// user dismisses the banner or opens the sheet — either way
    /// they now know about it.
    func markSeen() {
        guard let newest = reports.first else { return }
        UserDefaults.standard.set(newest.fileName, forKey: Self.lastSeenKey)
    }

    @discardableResult
    func discard(_ report: CrashReport) -> Bool {
        do {
            try FileManager.default.removeItem(at: report.url)
        } catch {
            return false
        }
        reports.removeAll { $0.id == report.id }
        return true
    }

    func discardAll() {
        for report in reports {
            try? FileManager.default.removeItem(at: report.url)
        }
        reports = []
    }
}
