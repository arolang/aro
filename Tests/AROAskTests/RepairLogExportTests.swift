// ============================================================
// RepairLogExportTests.swift
// AROAsk — exporting `aro ask` repair logs as training seeds (GitLab #800)
// ============================================================
//
// Three things have to hold for the export to be worth having, and each of
// them fails quietly if it is wrong: a pair that is not re-validated teaches
// the model a "fix" that does not check, a pair that is not anonymised ships
// somebody's directory layout into a public dataset, and a class that is
// mislabelled makes coverage over diagnostics a number that lies.

import Testing
import Foundation
@testable import AROAsk

@Suite("Exporting ask repair logs (#800)")
struct RepairLogExportTests {

    // MARK: - Re-validation

    /// A repair that fixed an unknown verb. This is the single most common
    /// shape in a real log.
    private let brokenVerb = """
    ```aro
    (Demo: Example) {
        Hash the <digest> from the <password>.
        Return an <OK: status> with <digest>.
    }
    ```
    """
    private let fixedVerb = """
    ```aro
    (Demo: Example) {
        Compute the <digest: hash> from the <password>.
        Return an <OK: status> with <digest>.
    }
    ```
    """

    @Test("A real repair survives re-validation")
    func realRepairIsKept() {
        var summary = RepairExportSummary()
        let entry = RepairLogEntry(
            brokenOutput: brokenVerb,
            errorPrompt: "main.aro:3:5: error: 'Hash' is not a verb of any action",
            fixedOutput: fixedVerb, attempts: 2, timestamp: "2026-09-30T10:00:00Z")

        let seed = RepairLogExport.seed(from: entry, summary: &summary)
        #expect(seed != nil)
        #expect(seed?.diagnosticClass == "unknown_verb")
        #expect(seed?.attempts == 2)
        #expect(seed?.origin == "ask_feedback")
    }

    @Test("An unknown verb really is an error here")
    func unknownVerbIsNotClean() {
        // The load-bearing detail. `Compiler.compile(_:)` defaults
        // `pluginActionsPossible` to true, under which an unknown verb is NOT
        // reported — a plugin might provide it. Validate with that default and
        // a repaired program and its broken twin both check clean, so every
        // unknown-verb repair in the log is silently dropped as "the broken
        // side passes now". The export compiles with it false.
        #expect(RepairLogExport.checksClean(brokenVerb) == false)
        #expect(RepairLogExport.checksClean(fixedVerb) == true)
    }

    @Test("A fix that still fails is dropped")
    func brokenFixIsDropped() {
        var summary = RepairExportSummary()
        let entry = RepairLogEntry(
            brokenOutput: "```aro\n(A: B) { Frobnicate the <x> from the <y>. }\n```",
            errorPrompt: "error: 'Frobnicate' is not a verb of any action",
            fixedOutput: "```aro\n(A: B) { Wibble the <x> from the <y>. }\n```",
            attempts: 3, timestamp: nil)

        #expect(RepairLogExport.seed(from: entry, summary: &summary) == nil)
        #expect(summary.droppedFixStillFails == 1)
    }

    @Test("A pair whose broken side checks clean is dropped")
    func notActuallyBrokenIsDropped() {
        // The pair claims one side failed. If the checker disagrees today —
        // a diagnostic was removed, or the log predates a fix — the pair would
        // teach a preference between two correct answers.
        var summary = RepairExportSummary()
        let entry = RepairLogEntry(
            brokenOutput: fixedVerb,
            errorPrompt: "error: something",
            fixedOutput: brokenVerb.replacingOccurrences(of: "Hash", with: "Compute"),
            attempts: 1, timestamp: nil)

        _ = RepairLogExport.seed(from: entry, summary: &summary)
        #expect(summary.droppedBrokenAlreadyPassed == 1)
    }

    @Test("An unchanged answer is not a repair")
    func unchangedIsDropped() {
        var summary = RepairExportSummary()
        let entry = RepairLogEntry(brokenOutput: "same", errorPrompt: "e",
                                   fixedOutput: "same", attempts: 1, timestamp: nil)
        #expect(RepairLogExport.seed(from: entry, summary: &summary) == nil)
        #expect(summary.droppedEmpty == 1)
    }

    @Test("An answer with no ARO in it is not a repair")
    func proseOnlyIsDropped() {
        var summary = RepairExportSummary()
        let entry = RepairLogEntry(
            brokenOutput: "I think you want to use a different action here.",
            errorPrompt: "error: something",
            fixedOutput: "Try the other one instead.",
            attempts: 1, timestamp: nil)
        #expect(RepairLogExport.seed(from: entry, summary: &summary) == nil)
    }

    // MARK: - Anonymisation

    @Test("The home directory and username are removed")
    func anonymisesHomeAndUser() {
        let text = "/Users/alice/Projects/thing/main.aro:3:5: error: alice broke it"
        let out = RepairLogExport.anonymise(
            text, home: URL(fileURLWithPath: "/Users/alice"), username: "alice")

        #expect(!out.contains("/Users/alice"))
        #expect(!out.lowercased().contains("alice"))
        #expect(out.contains("main.aro:3:5"), "the diagnostic has to survive")
    }

    @Test("A home directory from another machine is removed too")
    func anonymisesForeignHome() {
        // A log can be exported on a different machine, or a different OS,
        // than the one that wrote it.
        let out = RepairLogExport.anonymise(
            "/home/bob/src/app/main.aro: error: x",
            home: URL(fileURLWithPath: "/Users/alice"), username: "alice")
        #expect(!out.contains("/home/bob"))
        #expect(out.contains("~/src/app/main.aro"))
    }

    @Test("A short username is not substituted")
    func shortUsernameIsLeftAlone() {
        // Replacing a two-letter name would rewrite the code: `<x>` contains
        // no username, but a user called `al` would turn `Validate` into
        // `Vuserid…`. Below three characters the risk outweighs the benefit.
        let out = RepairLogExport.anonymise(
            "Validate the <alpha> from the <al>.",
            home: URL(fileURLWithPath: "/tmp/h"), username: "al")
        #expect(out.contains("Validate the <alpha>"))
    }

    // MARK: - Classification

    @Test("Diagnostics map to the class they repaired")
    func classifiesDiagnostics() {
        let cases: [(String, String)] = [
            ("'Hash' is not a verb of any action", "unknown_verb"),
            ("Unknown Compute qualifier 'linecount'", "unknown_qualifier"),
            ("action 'Store' does not accept preposition 'in'", "wrong_preposition"),
            ("Cannot rebind immutable variable 'total'", "immutability"),
            ("External dependency 'x' is not published by any feature set",
             "unpublished_dependency"),
            ("No Application-Start feature set", "entry_point"),
            ("something nobody has ever written", "other"),
        ]
        for (message, expected) in cases {
            #expect(RepairLogExport.diagnosticClass(for: message) == expected,
                    "\(message) → \(RepairLogExport.diagnosticClass(for: message))")
        }
    }

    // MARK: - Finding and writing

    @Test("Logs are found in the directory and one level below")
    func findsLogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("projectA")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try "{}".write(to: root.appendingPathComponent(RepairLogExport.logFileName),
                       atomically: true, encoding: .utf8)
        try "{}".write(to: nested.appendingPathComponent(RepairLogExport.logFileName),
                       atomically: true, encoding: .utf8)

        let found = RepairLogExport.findLogs(under: root)
        #expect(found.count == 2, "a folder of projects exports in one go")
    }

    @Test("A directory with no logs is not an error")
    func noLogsIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-none-\(UUID().uuidString)")
        #expect(RepairLogExport.findLogs(under: missing).isEmpty)
    }

    @Test("Seeds round-trip through the written file")
    func writesReadableJSONL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-seeds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = RepairSeed(
            prompt: "error: 'Hash' is not a verb of any action",
            rejected: brokenVerb, chosen: fixedVerb,
            diagnosticClass: "unknown_verb", attempts: 2,
            timestamp: "2026-09-30T10:00:00Z", origin: "ask_feedback")

        let target = try RepairLogExport.write([seed], to: directory)
        let text = try String(contentsOf: target, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)

        // The train side reads this with `json.loads` per line, so one line
        // must be one complete object.
        let decoded = try JSONDecoder().decode(
            RepairSeed.self, from: Data(lines[0].utf8))
        #expect(decoded.diagnosticClass == "unknown_verb")
        #expect(decoded.chosen == fixedVerb)
    }

    @Test("A whole log file is collected with its counts")
    func collectsAndCounts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-collect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        var lines: [String] = []
        for entry in [
            RepairLogEntry(brokenOutput: brokenVerb,
                           errorPrompt: "error: 'Hash' is not a verb of any action",
                           fixedOutput: fixedVerb, attempts: 2, timestamp: nil),
            RepairLogEntry(brokenOutput: "same", errorPrompt: "e",
                           fixedOutput: "same", attempts: 1, timestamp: nil),
        ] {
            lines.append(String(decoding: try encoder.encode(entry), as: UTF8.self))
        }
        let log = root.appendingPathComponent(RepairLogExport.logFileName)
        try (lines.joined(separator: "\n") + "\n").write(
            to: log, atomically: true, encoding: .utf8)

        var summary = RepairExportSummary()
        let seeds = RepairLogExport.collect(from: [log], summary: &summary)

        #expect(seeds.count == 1)
        #expect(summary.read == 2)
        #expect(summary.exported == 1)
        #expect(summary.byDiagnostic["unknown_verb"] == 1)
    }

    @Test("A malformed line is skipped, not fatal")
    func malformedLineIsSkipped() throws {
        // A log is appended to by a long-running session; a crash mid-write
        // leaves a partial line, and that must not cost the whole export.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-bad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let good = String(decoding: try JSONEncoder().encode(
            RepairLogEntry(brokenOutput: brokenVerb,
                           errorPrompt: "error: 'Hash' is not a verb of any action",
                           fixedOutput: fixedVerb, attempts: 1, timestamp: nil)),
            as: UTF8.self)
        let log = root.appendingPathComponent(RepairLogExport.logFileName)
        try ("{\"broken_output\": \"truncat\n" + good + "\n").write(
            to: log, atomically: true, encoding: .utf8)

        var summary = RepairExportSummary()
        let seeds = RepairLogExport.collect(from: [log], summary: &summary)
        #expect(seeds.count == 1)
    }
}
