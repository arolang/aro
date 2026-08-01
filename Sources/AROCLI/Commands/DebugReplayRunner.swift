// ============================================================
// DebugReplayRunner.swift
// ARO CLI - `aro debug --replay` session playback
// ============================================================
//
// Extracted from DebugCommand (#354): replaying a recorded JSONL session
// short-circuits the runtime entirely and drives its own tiny navigation loop
// (next / prev / go-end / jump). It used to live inline in DebugCommand.swift;
// pulling it into its own extension keeps the command a thin coordinator.
//
// Issue #229 Phase 4. Doesn't support breakpoint/step semantics yet — every
// pause shows in source order and the user types `n` to advance.

import ArgumentParser
import Foundation
import ARORuntime

extension DebugCommand {
    /// Read a recorded JSONL session and pretend each `pause` record is a fresh
    /// checkpoint. Drives the same CLI navigation loop without re-running the
    /// program.
    func runReplay(path: String) async throws {
        let reader: DebugEventLogReader
        do {
            reader = try DebugEventLogReader(path: path)
        } catch {
            print("Cannot read \(path): \(error)")
            throw ExitCode.failure
        }
        let pauses = reader.records.filter { $0.kind == .pause }
        if pauses.isEmpty {
            print("No pause records in \(path).")
            return
        }
        print("aro debug · replay (\(pauses.count) pauses)")
        var cursor = 0
        while cursor < pauses.count {
            let rec = pauses[cursor]
            print("")
            print("⏸  [\(cursor+1)/\(pauses.count)] t=\(String(format: "%.3f", rec.time))s — \(rec.body["fs"] ?? "?"):\(rec.body["line"] ?? "0")")
            print("   \(rec.body["stmt"] ?? "")")
            if let symsJson = rec.body["syms"],
               let data = symsJson.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
               !arr.isEmpty {
                for s in arr {
                    print("     <\(s["n"] ?? "?")> : \(s["ty"] ?? "?") = \(s["v"] ?? "?")")
                }
            }
            print("(replay) ", terminator: "")
            guard let raw = readLine() else { return }
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "n", "next", "":
                cursor += 1
            case "p", "prev":
                cursor = max(0, cursor - 1)
            case "g":
                cursor = pauses.count - 1
            case "0":
                cursor = 0
            case "q", "quit":
                return
            case let s where Int(s) != nil:
                let idx = Int(s)! - 1
                cursor = max(0, min(pauses.count - 1, idx))
            default:
                print("commands: n(ext) p(rev) g(o-end) 0(start) <num> q(uit)")
            }
        }
        print("\nEnd of replay.")
    }
}
