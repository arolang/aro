// ============================================================
// DebugEventLog.swift
// ARO Runtime - Time-travel JSONL log (Issue #229 Phase 4)
// ============================================================
//
// One file format serves three jobs:
//   1. `aro debug --record session.jsonl`  → writes
//   2. `aro debug --replay session.jsonl`  → reads and re-pauses
//   3. SOLARO time-travel scrubber (issue #228, figure 11) consumes the
//      same stream live or after-the-fact.
//
// Each line is a single self-describing JSON object so the file is
// streamable, tail-able, diffable, and trivial to fan out to multiple
// readers without buffering the full session in memory.
//
// Wire schema (intentionally tiny; additive fields are fine):
//
//   {"t": 12.4, "k": "pause", "reason": "step|breakpoint|entry|event|error",
//    "fs": "createUser", "act": "User API",
//    "file": "users.aro", "line": 5, "col": 9,
//    "verb": "Create", "stmt": "Create the <user> with <data>.",
//    "syms": [{"n": "user", "ty": "User", "v": "{name:Ada,…}"}]}
//
//   {"t": 12.5, "k": "event", "name": "UserCreated", "payload": "{id:530}"}
//
//   {"t": 12.6, "k": "error", "msg": "Validation failed: email missing"}
//
// `t` is wall-clock seconds since the recording started (Double); SOLARO
// uses it for the cursor timeline. `k` is a one-letter discriminator.

import Foundation

public struct DebugEventRecord: Sendable {
    public enum Kind: String, Sendable { case pause, event, error, end }

    public let time: Double
    public let kind: Kind
    public let body: [String: String]   // flat string values; structured payloads pre-rendered

    public init(time: Double, kind: Kind, body: [String: String]) {
        self.time = time
        self.kind = kind
        self.body = body
    }

    public func encodeJSONLine() -> Data {
        var obj: [String: Any] = ["t": time, "k": kind.rawValue]
        for (k, v) in body { obj[k] = v }
        let json = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        var out = json
        out.append(0x0A) // newline
        return out
    }

    public static func decodeJSONLine(_ line: String) -> DebugEventRecord? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? Double,
              let kStr = obj["k"] as? String,
              let kind = Kind(rawValue: kStr)
        else { return nil }
        var body: [String: String] = [:]
        for (k, v) in obj where k != "t" && k != "k" {
            if let s = v as? String { body[k] = s }
            else if let n = v as? NSNumber { body[k] = n.stringValue }
            else { body[k] = String(describing: v) }
        }
        return DebugEventRecord(time: t, kind: kind, body: body)
    }
}

/// Append-only JSONL writer. Safe to call from any actor — wraps a
/// FileHandle in a synchronizing actor.
public actor DebugEventLogWriter {
    private let handle: FileHandle
    private let startedAt: Date

    /// Stop writing once the log reaches this many bytes.
    ///
    /// The file is truncated per run, but one run has no bound: every
    /// statement of every loop iteration appends a record carrying its whole
    /// symbol bag. A service left running for an afternoon wrote a
    /// multi-gigabyte file into the user's project directory, and the readers
    /// that load it whole then tried to hold all of it (GitLab #746).
    ///
    /// Stopping beats rotating here: the consumers — SOLARO's time-travel
    /// scrubber, `aro debug --replay` — read a session from the beginning, so
    /// a rotated log would silently lose the start of the story it is used to
    /// tell. A capped one is honest and still replays.
    ///
    /// `ARO_DEBUG_LOG_MAX_BYTES` overrides it; `0` means no limit.
    public static let defaultMaxBytes = 256 * 1024 * 1024

    private let maxBytes: Int
    private var bytesWritten = 0
    private var stoppedAtCap = false

    public init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else {
            throw NSError(domain: "DebugEventLogWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(path) for writing"])
        }
        self.handle = h
        self.startedAt = Date()
        if let raw = ProcessInfo.processInfo.environment["ARO_DEBUG_LOG_MAX_BYTES"],
           let parsed = Int(raw), parsed >= 0 {
            self.maxBytes = parsed
        } else {
            self.maxBytes = Self.defaultMaxBytes
        }
    }

    public func write(_ kind: DebugEventRecord.Kind, body: [String: String]) {
        guard !stoppedAtCap else { return }
        let t = Date().timeIntervalSince(startedAt)
        let record = DebugEventRecord(time: t, kind: kind, body: body)
        let line = record.encodeJSONLine()

        if maxBytes > 0, bytesWritten + line.count > maxBytes {
            stoppedAtCap = true
            // One last record, so a reader can tell a capped log from a
            // crashed one — the difference matters when the scrubber runs out
            // of frames earlier than the user expects.
            let notice = DebugEventRecord(
                time: t,
                kind: kind,
                body: [
                    "note": "debug log reached \(maxBytes) bytes; recording stopped",
                    "cap": String(maxBytes),
                ]
            )
            try? handle.write(contentsOf: notice.encodeJSONLine())
            FileHandle.standardError.write(Data(
                "[DebugEventLog] recording stopped at \(maxBytes) bytes; set ARO_DEBUG_LOG_MAX_BYTES to change\n".utf8
            ))
            return
        }

        bytesWritten += line.count
        try? handle.write(contentsOf: line)
    }

    public func close() {
        try? handle.close()
    }
}

/// JSONL replay reader. Loads the full file into memory (a session of a
/// few thousand events is hundreds of KB at most). The caller drives
/// playback by stepping the cursor — Phase 4 keeps this single-cursor
/// rather than building the full fork-and-replay tree out of the gate.
public struct DebugEventLogReader: Sendable {
    public let records: [DebugEventRecord]

    public init(path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        self.records = text.split(separator: "\n").compactMap {
            DebugEventRecord.decodeJSONLine(String($0))
        }
    }
}
