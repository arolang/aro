// ============================================================
// CrashReportTests.swift
// SOLARO — crash log parsing, store, submission text (#275)
// ============================================================

import Foundation
import Testing
@testable import SOLARO

@Suite("Crash reports (#275)")
struct CrashReportTests {

    /// A log in exactly the shape `CrashReporter.writeCrash` emits.
    private func sampleLog(signal: Int32 = 11,
                           version: String = "0.11.5") -> String {
        """
        SOLARO crash report
        ---
        time:    2026-08-14 09:30:15 +0000
        signal:  \(signal)
        version: \(version)
        macOS:   Version 15.0 (Build 24A335)

        ## Stack trace (best-effort)

        0   SolaroApp    0x0000000102f3c1a4 crash_here + 42
        1   libsystem    0x00000001a1b2c3d4 _sigtramp + 56
        """
    }

    // MARK: - Parsing

    @Test("Header fields are read back")
    func parsesHeader() {
        let report = CrashReport.parse(
            url: URL(fileURLWithPath: "/tmp/crash-20260814-093015.txt"),
            text: sampleLog(), modified: .distantPast)
        #expect(report.signal == 11)
        #expect(report.version == "0.11.5")
    }

    @Test("Signal numbers get their names")
    func signalNames() {
        func name(_ signal: Int32) -> String {
            CrashReport.parse(
                url: URL(fileURLWithPath: "/tmp/c.txt"),
                text: sampleLog(signal: signal), modified: .distantPast
            ).signalName
        }
        #expect(name(11) == "SIGSEGV (11)")
        #expect(name(6) == "SIGABRT (6)")
        #expect(name(4) == "SIGILL (4)")
        // Unmapped numbers still render something useful.
        #expect(name(99) == "signal 99")
    }

    @Test("A log with no signal header reads as unknown")
    func missingSignal() {
        let report = CrashReport.parse(
            url: URL(fileURLWithPath: "/tmp/c.txt"),
            text: "SOLARO crash report\n---\nversion: 0.1.0\n",
            modified: .distantPast)
        #expect(report.signal == nil)
        #expect(report.signalName == "unknown")
    }

    @Test("Stack-trace lines are not parsed as headers")
    func stopsAtStackTrace() {
        // The frame lines contain colons; without the `##` stop the
        // parser would happily read "0   SolaroApp    0x…" as a field.
        let report = CrashReport.parse(
            url: URL(fileURLWithPath: "/tmp/c.txt"),
            text: sampleLog(), modified: .distantPast)
        #expect(report.version == "0.11.5")
    }

    @Test("The date comes from the filename")
    func dateFromFileName() throws {
        let date = try #require(
            CrashReport.dateFromFileName("crash-20260814-093015.txt"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 14)
        #expect(parts.hour == 9)
        #expect(parts.minute == 30)
    }

    @Test("An unparsable filename falls back to the file's mtime")
    func dateFallsBackToModified() {
        #expect(CrashReport.dateFromFileName("notes.txt") == nil)
        #expect(CrashReport.dateFromFileName("crash-nonsense.txt") == nil)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let report = CrashReport.parse(
            url: URL(fileURLWithPath: "/tmp/hand-copied.txt"),
            text: sampleLog(), modified: stamp)
        #expect(report.date == stamp)
    }

    // MARK: - Store

    /// A temp crashes directory with `names` written into it.
    @MainActor
    private func makeStore(_ names: [String]) throws -> (CrashReportStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("solaro-crashes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        for name in names {
            try sampleLog().write(to: dir.appendingPathComponent(name),
                                  atomically: true, encoding: .utf8)
        }
        return (CrashReportStore(directory: dir), dir)
    }

    @MainActor
    @Test("Reports list newest first")
    func sortsNewestFirst() throws {
        let (store, dir) = try makeStore([
            "crash-20260101-000000.txt",
            "crash-20260814-093015.txt",
            "crash-20260601-120000.txt",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        store.reload()
        #expect(store.reports.count == 3)
        #expect(store.reports.first?.fileName == "crash-20260814-093015.txt")
        #expect(store.reports.last?.fileName == "crash-20260101-000000.txt")
    }

    @MainActor
    @Test("Non-txt files are ignored")
    func ignoresOtherFiles() throws {
        let (store, dir) = try makeStore(["crash-20260814-093015.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent(".DS_Store"))
        try "x".write(to: dir.appendingPathComponent("readme.md"),
                      atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.reports.count == 1)
    }

    @MainActor
    @Test("A missing directory is empty, not an error")
    func missingDirectory() {
        let store = CrashReportStore(
            directory: URL(fileURLWithPath: "/nonexistent/solaro/crashes"))
        store.reload()
        #expect(store.reports.isEmpty)
        #expect(store.unseenReport == nil)
    }

    @MainActor
    @Test("Discard removes the file from disk")
    func discardDeletes() throws {
        let (store, dir) = try makeStore(["crash-20260814-093015.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        store.reload()
        let report = try #require(store.reports.first)
        #expect(store.discard(report))
        #expect(store.reports.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: report.url.path))
    }

    @MainActor
    @Test("Discard all empties the folder")
    func discardAllDeletes() throws {
        let (store, dir) = try makeStore([
            "crash-20260101-000000.txt", "crash-20260814-093015.txt",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        store.reload()
        store.discardAll()
        #expect(store.reports.isEmpty)
        let left = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        #expect(left.isEmpty)
    }

    @MainActor
    @Test("A crash raises itself once, then stays quiet")
    func unseenThenSeen() throws {
        let (store, dir) = try makeStore(["crash-20260814-093015.txt"])
        defer {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults.standard.removeObject(forKey: "solaro.crash.lastSeenFile")
        }
        UserDefaults.standard.removeObject(forKey: "solaro.crash.lastSeenFile")
        store.reload()
        #expect(store.unseenReport != nil)
        store.markSeen()
        #expect(store.unseenReport == nil)
    }

    @MainActor
    @Test("A newer crash raises itself even after an older one was seen")
    func newerCrashRaisesAgain() throws {
        let (store, dir) = try makeStore(["crash-20260101-000000.txt"])
        defer {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults.standard.removeObject(forKey: "solaro.crash.lastSeenFile")
        }
        UserDefaults.standard.removeObject(forKey: "solaro.crash.lastSeenFile")
        store.reload()
        store.markSeen()
        #expect(store.unseenReport == nil)

        try sampleLog().write(
            to: dir.appendingPathComponent("crash-20260814-093015.txt"),
            atomically: true, encoding: .utf8)
        store.reload()
        #expect(store.unseenReport?.fileName == "crash-20260814-093015.txt")
    }
}

@Suite("Crash submission (#275)")
struct CrashSubmissionTests {

    private var report: CrashReport {
        CrashReport(
            url: URL(fileURLWithPath: "/tmp/crash-20260814-093015.txt"),
            date: Date(timeIntervalSince1970: 1_755_163_815),
            signal: 11,
            version: "0.11.5",
            text: "SOLARO crash report\nsignal: 11\n")
    }

    @Test("Title names the signal and version")
    func title() {
        let title = CrashSubmission.composeTitle(for: report)
        #expect(title.contains("SIGSEGV"))
        #expect(title.contains("0.11.5"))
    }

    @Test("Body carries the log and the environment")
    func body() {
        let body = CrashSubmission.composeBody(for: report)
        #expect(body.contains("SOLARO crash report"))
        #expect(body.contains("0.11.5"))
        #expect(body.contains("SIGSEGV"))
        #expect(body.contains("<details>"))
    }

    @Test("An empty note adds no empty section")
    func emptyNoteOmitted() {
        #expect(!CrashSubmission.composeBody(for: report).contains("What I was doing"))
        #expect(!CrashSubmission.composeBody(for: report, note: "   \n ")
            .contains("What I was doing"))
        #expect(CrashSubmission.composeBody(for: report, note: "clicked Run")
            .contains("What I was doing"))
    }

    @Test("Submissions target GitLab, never the GitHub mirror")
    func targetsGitLab() throws {
        // #275 is explicit about this, and it matches the project's
        // standing rule that origin is GitLab.
        let url = try #require(CrashSubmission.newIssueURL(for: report))
        #expect(url.host == CrashSubmission.host)
        #expect(!url.absoluteString.contains("github.com"))
        #expect(url.path.contains("/-/issues/new"))
    }

    @Test("Pre-filled form uses GitLab's parameter names")
    func gitLabQueryParameters() throws {
        // GitLab wants `issue[title]` / `issue[description]`;
        // GitHub's `title` / `body` are silently ignored, which is
        // how a "pre-filled" form arrives blank.
        let url = try #require(CrashSubmission.newIssueURL(for: report))
        let items = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let names = Set(items.map(\.name))
        #expect(names.contains("issue[title]"))
        #expect(names.contains("issue[description]"))
    }

    @Test("Report-a-Bug page also goes to GitLab")
    func reportBugURLIsGitLab() {
        let url = CrashReporter.composeReportURL()
        #expect(url.host == CrashSubmission.host)
        #expect(!url.absoluteString.contains("github.com"))
    }

    @Test("The issue URL is picked out of glab's output")
    func parsesGlabOutput() throws {
        let output = """
        - Creating issue in arolang/aro
        https://git.ausdertechnik.de/arolang/aro/-/issues/512
        """
        let url = try #require(CrashSubmission.issueURL(fromCLIOutput: output))
        #expect(url.absoluteString.hasSuffix("/issues/512"))
    }

    @Test("Output with no URL yields nil rather than a wrong guess")
    func noURLInOutput() {
        #expect(CrashSubmission.issueURL(fromCLIOutput: "error: 401 Unauthorized") == nil)
        #expect(CrashSubmission.issueURL(fromCLIOutput: "") == nil)
    }

    @Test("Trailing punctuation is trimmed off the parsed URL")
    func trimsPunctuation() throws {
        let url = try #require(CrashSubmission.issueURL(
            fromCLIOutput: "created (https://git.example.com/a/b/-/issues/7)."))
        #expect(url.absoluteString == "https://git.example.com/a/b/-/issues/7")
    }
}
