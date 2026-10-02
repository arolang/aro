// ============================================================
// RepairLogExport.swift
// AROAsk — turn `aro ask` repair logs into training seeds (GitLab #800)
// ============================================================
//
// `AskSession.saveRepairLog` writes `.context.repairs.jsonl` into the
// directory the user ran `aro ask` in. The preference stage reads
// `ARO_ROOT/.context.repairs.jsonl` — the ARO-Train project root. Those two
// paths coincide only if somebody happens to run the assistant from inside the
// training checkout, which nobody does, so every real repair the assistant has
// ever performed has been written to disk and left there.
//
// That is the highest-signal preference data available: a human hit a real
// failure, the model's first answer was wrong, `aro check` said why, and a
// later answer was right. Both sides of a preference pair, with the reason
// attached, produced by use rather than by sampling.
//
// This is the bridge, and it is **opt-in**. A repair log is a transcript of
// somebody's private project; copying it anywhere has to be something they ask
// for, not something a background task decides. So it is a command, it says
// what it collected, and it writes only where it is told.
//
// Three things happen on the way across:
//
//   * **Anonymisation.** Absolute paths, the home directory and the username
//     are removed. A diagnostic quotes the file it was about, and that path
//     names a person and their machine.
//   * **Re-validation.** The fix is parsed again, now, by this build. A pair
//     is kept only when the fixed side is clean and the broken side is not —
//     which is the claim the pair makes. A log entry recorded against an older
//     checker may no longer mean what it said.
//   * **Classification.** Each entry gets the diagnostic class it was repaired
//     from, so coverage over diagnostics is countable instead of anecdotal.
//
// Deliberately NOT done: running the code. #800 suggests re-validating with
// `aro run` as well as `aro check`. Executing programs harvested from
// somebody's session, as a side effect of an export, is not a thing this
// should do — the training pipeline has sandboxed execution stages for code it
// generated itself, and that is where execution belongs.

import AROParser
import Foundation

/// One line of `.context.repairs.jsonl`.
struct RepairLogEntry: Codable, Sendable {
    let brokenOutput: String
    let errorPrompt: String
    let fixedOutput: String
    let attempts: Int?
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case brokenOutput = "broken_output"
        case errorPrompt = "error_prompt"
        case fixedOutput = "fixed_output"
        case attempts
        case timestamp
    }
}

/// One exported seed: a preference pair with the diagnostic that caused it.
struct RepairSeed: Codable, Sendable {
    /// The diagnostic the user hit, anonymised.
    let prompt: String
    /// The answer that failed — the rejected side.
    let rejected: String
    /// The answer that passed — the chosen side.
    let chosen: String
    /// Which `aro check` diagnostic this repair was about.
    let diagnosticClass: String
    /// How many attempts the repair took. A 4-attempt repair is a harder case
    /// than a 1-attempt one and the training side may want to weigh it.
    let attempts: Int
    let timestamp: String?
    /// Always `ask_feedback`, so the share cap and the quality tables see one
    /// source rather than one per user.
    let origin: String

    enum CodingKeys: String, CodingKey {
        case prompt, rejected, chosen, attempts, timestamp, origin
        case diagnosticClass = "diagnostic_class"
    }
}

/// What an export run did, for the summary the user reads before deciding
/// whether to keep the file.
struct RepairExportSummary: Sendable {
    var read = 0
    var exported = 0
    var droppedFixStillFails = 0
    var droppedBrokenAlreadyPassed = 0
    var droppedEmpty = 0
    var byDiagnostic: [String: Int] = [:]
}

enum RepairLogExport {

    static let logFileName = ".context.repairs.jsonl"

    // MARK: - Diagnostic classification

    /// Which `aro check` diagnostic a repair was about.
    ///
    /// Matched on the checker's own wording rather than on an error code,
    /// because the diagnostics do not carry codes. A message this does not
    /// recognise is `other` rather than a guess: an unrecognised class that
    /// shows up often is a signal to add it, and a wrong one is a count that
    /// quietly lies.
    static func diagnosticClass(for errorPrompt: String) -> String {
        let text = errorPrompt.lowercased()
        let table: [(needle: String, name: String)] = [
            ("is not a verb of any action", "unknown_verb"),
            ("unknown compute qualifier", "unknown_qualifier"),
            ("qualifier", "unknown_qualifier"),
            ("preposition", "wrong_preposition"),
            ("cannot rebind immutable", "immutability"),
            ("is not published by any feature set", "unpublished_dependency"),
            ("undefined variable", "undefined_variable"),
            ("application-start", "entry_point"),
            ("expected", "syntax"),
            ("unexpected", "syntax"),
        ]
        for entry in table where text.contains(entry.needle) {
            return entry.name
        }
        return "other"
    }

    // MARK: - Anonymisation

    /// Remove anything that names the person or the machine.
    ///
    /// A diagnostic quotes the file it was about, so a raw log carries
    /// `/Users/<name>/Projects/<their client>/main.aro` on most lines. Three
    /// passes, narrowest first: the real home directory, then any
    /// `/Users/<x>` or `/home/<x>` prefix, then the bare username — the last
    /// because a relative path like `kris-scratch/main.aro` still names them.
    static func anonymise(_ text: String, home: URL? = nil,
                          username: String? = nil) -> String {
        var out = text

        let homePath = (home ?? FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL.path
        if homePath.count > 1 {
            out = out.replacingOccurrences(of: homePath, with: "~")
        }

        // Any other machine's home directory, including one recorded on a
        // different OS than the one running the export.
        out = out.replacingOccurrences(
            of: #"/(?:Users|home)/[^/\s"']+"#,
            with: "~",
            options: .regularExpression)

        let name = username ?? NSUserName()
        if name.count >= 3 {
            out = out.replacingOccurrences(
                of: name, with: "user", options: .caseInsensitive)
        }
        return out
    }

    // MARK: - Validation

    /// Whether this text parses and checks clean as an ARO program.
    ///
    /// The model's answer is prose around fenced code, so the fences are what
    /// gets checked. An answer with no ARO in it at all is not a repair of
    /// anything and returns nil, which the caller drops.
    ///
    /// `pluginActionsPossible: false` is the load-bearing argument.
    /// `Compiler.compile(_:)` defaults it to true, and under it
    /// `CodeQualityValidator` says nothing about an unknown verb — a plugin
    /// could be providing it, and guessing would be worse than silence. A
    /// repair-log snippet has no plugins, and "'Hash' is not a verb of any
    /// action" is the single most common diagnostic these logs record, so
    /// compiling with the default turned a repaired program and its broken
    /// twin into two programs that both check clean.
    ///
    /// `checksWholeApplication: false` for the same kind of reason: a fenced
    /// snippet is not an application and has no `Application-Start`, which is
    /// an error about the file rather than about the code in it.
    static func checksClean(_ answer: String) -> Bool? {
        let blocks = aroCodeBlocks(in: answer)
        guard !blocks.isEmpty else { return nil }
        for block in blocks {
            let result = Compiler().compile(
                block,
                pluginActionsPossible: false,
                checksWholeApplication: false)
            if result.hasErrors { return false }
        }
        return true
    }

    /// The ```aro fenced blocks in a model answer, plus the whole text when it
    /// is bare ARO with no fences at all.
    static func aroCodeBlocks(in answer: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inside = false

        for line in answer.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inside {
                    let body = current.joined(separator: "\n")
                    if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(body)
                    }
                    current = []
                    inside = false
                } else {
                    let language = trimmed.dropFirst(3)
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    inside = language.isEmpty || language == "aro"
                }
                continue
            }
            if inside { current.append(line) }
        }

        if blocks.isEmpty, answer.contains("("), answer.contains("<") {
            // `/fix` writes the file back, so its logged answer is often the
            // program itself with no fence around it.
            blocks.append(answer)
        }
        return blocks
    }

    // MARK: - Export

    /// Read every repair log under `sources` and return the seeds worth keeping.
    static func collect(from sources: [URL],
                        summary: inout RepairExportSummary) -> [RepairSeed] {
        var seeds: [RepairSeed] = []

        for logURL in sources {
            guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else {
                continue
            }
            for line in contents.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                      let entry = try? JSONDecoder().decode(RepairLogEntry.self, from: data)
                else { continue }
                summary.read += 1

                guard let seed = seed(from: entry, summary: &summary) else { continue }
                seeds.append(seed)
                summary.exported += 1
                summary.byDiagnostic[seed.diagnosticClass, default: 0] += 1
            }
        }
        return seeds
    }

    /// One log entry, re-validated and anonymised, or nil with a reason counted.
    static func seed(from entry: RepairLogEntry,
                     summary: inout RepairExportSummary) -> RepairSeed? {
        let broken = entry.brokenOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixed = entry.fixedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !broken.isEmpty, !fixed.isEmpty, broken != fixed else {
            summary.droppedEmpty += 1
            return nil
        }

        // The pair claims "this one failed, that one passed". Check the claim
        // against the checker in this build rather than trusting a line written
        // by an older one — a diagnostic that has since been fixed, or newly
        // added, changes which side is which.
        guard let fixedClean = checksClean(fixed) else {
            summary.droppedEmpty += 1
            return nil
        }
        guard fixedClean else {
            summary.droppedFixStillFails += 1
            return nil
        }
        if checksClean(broken) == true {
            summary.droppedBrokenAlreadyPassed += 1
            return nil
        }

        return RepairSeed(
            prompt: anonymise(entry.errorPrompt),
            rejected: anonymise(broken),
            chosen: anonymise(fixed),
            diagnosticClass: diagnosticClass(for: entry.errorPrompt),
            attempts: entry.attempts ?? 1,
            timestamp: entry.timestamp,
            origin: "ask_feedback"
        )
    }

    /// Repair logs under `root`, searched one level deep so a directory of
    /// projects can be exported in one go.
    static func findLogs(under root: URL) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []

        let direct = root.appendingPathComponent(logFileName)
        if fm.fileExists(atPath: direct.path) { found.append(direct) }

        if let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) {
            for child in children {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                let nested = child.appendingPathComponent(logFileName)
                if fm.fileExists(atPath: nested.path) { found.append(nested) }
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Write seeds as JSONL. Returns the file written.
    static func write(_ seeds: [RepairSeed], to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let target = directory.appendingPathComponent("ask_repairs_\(stamp).jsonl")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var text = ""
        for seed in seeds {
            let data = try encoder.encode(seed)
            text += String(decoding: data, as: UTF8.self) + "\n"
        }
        try text.write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}
