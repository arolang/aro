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

    /// The fatal signals we install a handler for.
    ///
    /// SIGTRAP is in the set because Swift runtime traps —
    /// `fatalError`, force-unwrapping nil, out-of-bounds indexing,
    /// integer overflow, `precondition` failures — compile to a
    /// `brk` instruction on arm64 and are delivered as SIGTRAP,
    /// not SIGILL (that's the x86 `ud2` behaviour). Without it the
    /// most common category of Swift crash left no log (#526).
    static let installedSignals: [Int32] = [
        SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP,
    ]

    /// Install signal handlers for the most common fatal signals.
    /// Each handler writes a stack-snapshot to disk and re-raises
    /// the signal so the OS still terminates the process with the
    /// original status.
    ///
    /// Everything the handler needs (paths, header strings, scratch
    /// buffers) is prepared HERE — inside the handler only async-
    /// signal-safe calls remain (#525).
    static func install() {
        prepare(directory: crashesDirectory)
        for sig in installedSignals {
            signal(sig) { signum in
                CrashReporter.writeCrashSignalSafe(signal: signum)
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

    /// Open the new-issue page with the most recent crash log
    /// embedded in the description as a fenced block.
    ///
    /// Destination is GitLab (`origin`), not the GitHub mirror
    /// (#275). The mirror was the earlier target on the theory
    /// that outside reporters can reach it, but a report filed
    /// where the work isn't tracked is a report nobody sees.
    static func openReportBugPage() {
        let url = composeReportURL()
        NSWorkspace.shared.open(url)
    }

    /// Build the new-issue URL. Public so a SwiftUI button can
    /// trigger it; tests can also exercise the URL composition.
    static func composeReportURL() -> URL {
        let base = "https://\(CrashSubmission.host)/\(CrashSubmission.projectPath)/-/issues/new"
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
        // GitLab's new-issue form takes `issue[title]` /
        // `issue[description]` — GitHub's `title` / `body` names
        // are silently ignored here, which is how a pre-filled
        // form arrives empty.
        components.queryItems = [
            URLQueryItem(name: "issue[title]",
                         value: "SOLARO crash / bug report"),
            URLQueryItem(name: "issue[description]", value: description),
        ]
        return components.url!
    }

    // MARK: - Signal-safe crash writing (#525)

    /// Everything the signal handler needs, computed up front in
    /// `prepare(directory:)` so the handler itself never touches
    /// Foundation and never allocates. Written once before any
    /// handler is installed, then only read on the (fatal, one-shot)
    /// crash path — hence `nonisolated(unsafe)`.
    private enum SignalState {
        /// Crash directory path, NUL-terminated.
        nonisolated(unsafe) static var directory: UnsafeMutablePointer<CChar>?
        /// `version: x.y.z\n`, NUL-terminated.
        nonisolated(unsafe) static var versionLine: UnsafeMutablePointer<CChar>?
        /// `macOS:   Version …\n`, NUL-terminated.
        nonisolated(unsafe) static var osLine: UnsafeMutablePointer<CChar>?
        /// Scratch buffer for the file path and header lines.
        nonisolated(unsafe) static var scratch: UnsafeMutablePointer<CChar>?
        /// Scratch buffer for backtrace(3) return addresses.
        nonisolated(unsafe) static var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

        static let scratchSize = 4096
        static let maxFrames = 128
    }

    /// Pre-compute everything the crash handler will need: create
    /// the directory, render the version / OS header lines, and
    /// allocate the scratch buffers. All Foundation work happens
    /// here, at install time — never inside the handler.
    /// Internal (not private) so tests can point the writer at a
    /// temp directory.
    static func prepare(directory: URL) {
        // Best-effort: if the directory can't be created the handler's
        // open(2) fails and the report is dropped, which is the
        // documented degradation mode.
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        replaceCString(&SignalState.directory, with: directory.path)
        replaceCString(&SignalState.versionLine,
                       with: "version: \(AROVersion.shortVersion)\n")
        replaceCString(&SignalState.osLine,
                       with: "macOS:   \(ProcessInfo.processInfo.operatingSystemVersionString)\n")
        if SignalState.scratch == nil {
            SignalState.scratch = .allocate(capacity: SignalState.scratchSize)
        }
        if SignalState.frames == nil {
            SignalState.frames = .allocate(capacity: SignalState.maxFrames)
        }
    }

    private static func replaceCString(
        _ slot: inout UnsafeMutablePointer<CChar>?, with value: String
    ) {
        let copy = strdup(value)
        if let old = slot { free(old) }
        slot = copy
    }

    /// Runs INSIDE the signal handler. Only async-signal-safe calls:
    /// time(2), open(2), write(2), close(2), backtrace(3) and
    /// backtrace_symbols_fd(3) — no Foundation, no Swift String, no
    /// allocation. The previous implementation used DateFormatter,
    /// `Thread.callStackSymbols` and Foundation writes here, which
    /// deadlocks in malloc for exactly the heap-corruption crashes
    /// the reporter exists to capture (#525).
    ///
    /// Output keeps the exact shape `CrashReport.parse` and
    /// `CrashReport.dateFromFileName` read back: a
    /// `crash-yyyyMMdd-HHmmss.txt` filename (UTC) and a
    /// `key: value` header block terminated by a `##` line.
    ///
    /// Best-effort — if the path or process state is hostile we
    /// drop the report silently so the re-raise still happens.
    static func writeCrashSignalSafe(signal signum: Int32) {
        guard let dir = SignalState.directory,
              let buf = SignalState.scratch else { return }

        // UTC components by pure arithmetic — gmtime(3) is not
        // async-signal-safe (first call can allocate / read tzdata).
        let now = time(nil)
        guard now > 0 else { return }
        let (year, month, day, hour, minute, second) = utcComponents(of: now)

        // <dir>/crash-yyyyMMdd-HHmmss.txt
        var i = 0
        i = append(buf, i, cString: dir)
        i = append(buf, i, literal: "/crash-")
        i = append(buf, i, number: year, width: 4)
        i = append(buf, i, number: month, width: 2)
        i = append(buf, i, number: day, width: 2)
        i = append(buf, i, literal: "-")
        i = append(buf, i, number: hour, width: 2)
        i = append(buf, i, number: minute, width: 2)
        i = append(buf, i, number: second, width: 2)
        i = append(buf, i, literal: ".txt")
        guard i < SignalState.scratchSize else { return }
        buf[i] = 0

        let fd = open(buf, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // Header block. open(2) copied the path out of `buf`, so the
        // scratch buffer is free to hold the header now.
        var j = 0
        j = append(buf, j, literal: "SOLARO crash report\n---\ntime:    ")
        j = append(buf, j, number: year, width: 4)
        j = append(buf, j, literal: "-")
        j = append(buf, j, number: month, width: 2)
        j = append(buf, j, literal: "-")
        j = append(buf, j, number: day, width: 2)
        j = append(buf, j, literal: " ")
        j = append(buf, j, number: hour, width: 2)
        j = append(buf, j, literal: ":")
        j = append(buf, j, number: minute, width: 2)
        j = append(buf, j, literal: ":")
        j = append(buf, j, number: second, width: 2)
        j = append(buf, j, literal: " +0000\nsignal:  ")
        j = append(buf, j, number: Int(signum), width: 0)
        j = append(buf, j, literal: "\n")
        writeFully(fd, buf, count: j)
        if let version = SignalState.versionLine {
            writeFully(fd, version, count: strlen(version))
        }
        if let os = SignalState.osLine {
            writeFully(fd, os, count: strlen(os))
        }
        writeLiteral(fd, "\n## Stack trace (best-effort)\n\n")

        // backtrace_symbols_fd symbolicates straight onto the fd —
        // unlike backtrace_symbols / Thread.callStackSymbols it
        // never mallocs.
        if let frames = SignalState.frames {
            let depth = backtrace(frames, Int32(SignalState.maxFrames))
            if depth > 0 {
                backtrace_symbols_fd(frames, depth, fd)
            }
        }
    }

    /// UTC calendar components from a Unix timestamp by pure integer
    /// arithmetic (Howard Hinnant's `civil_from_days`), usable where
    /// gmtime(3) is not. Caller guarantees `t > 0`.
    static func utcComponents(of t: time_t)
        -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)
    {
        let total = Int(t)
        let days = total / 86_400
        let secs = total % 86_400
        let z = days + 719_468
        let era = z / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        var year = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        if month <= 2 { year += 1 }
        return (year, month, day, secs / 3_600, (secs % 3_600) / 60, secs % 60)
    }

    // MARK: Allocation-free byte pushing

    /// Append a NUL-terminated C string; returns the new cursor.
    /// Truncates silently at the buffer edge (a truncated path just
    /// fails open(2); a truncated header still parses as far as it
    /// goes).
    private static func append(
        _ buf: UnsafeMutablePointer<CChar>, _ start: Int,
        cString source: UnsafePointer<CChar>
    ) -> Int {
        var i = start
        var s = source
        while s.pointee != 0, i < SignalState.scratchSize - 1 {
            buf[i] = s.pointee
            i += 1
            s += 1
        }
        return i
    }

    /// Append a compile-time literal. StaticString with pointer
    /// representation reads straight from constant data — no
    /// allocation.
    private static func append(
        _ buf: UnsafeMutablePointer<CChar>, _ start: Int,
        literal: StaticString
    ) -> Int {
        var i = start
        literal.withUTF8Buffer { bytes in
            for byte in bytes where i < SignalState.scratchSize - 1 {
                buf[i] = CChar(bitPattern: byte)
                i += 1
            }
        }
        return i
    }

    /// Append a non-negative integer, zero-padded to `width`
    /// (`width: 0` = natural width). Negative values render their
    /// magnitude after a `-`.
    private static func append(
        _ buf: UnsafeMutablePointer<CChar>, _ start: Int,
        number: Int, width: Int
    ) -> Int {
        var i = start
        var value = number
        if value < 0 {
            i = append(buf, i, literal: "-")
            value = -value
        }
        // Digits fall out lowest-first; stage them in a fixed-size
        // tuple on the stack (no allocation), then copy reversed.
        var staged: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                     CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                     CChar, CChar, CChar, CChar) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var count = 0
        withUnsafeMutableBytes(of: &staged) { raw in
            let stage = raw.bindMemory(to: CChar.self)
            repeat {
                stage[count] = CChar(UInt8(ascii: "0")) + CChar(value % 10)
                value /= 10
                count += 1
            } while value > 0 && count < 20
            while count < width && count < 20 {
                stage[count] = CChar(UInt8(ascii: "0"))
                count += 1
            }
            var k = count - 1
            while k >= 0, i < SignalState.scratchSize - 1 {
                buf[i] = stage[k]
                i += 1
                k -= 1
            }
        }
        return i
    }

    /// write(2) until everything went out or the write fails.
    private static func writeFully(
        _ fd: Int32, _ bytes: UnsafePointer<CChar>, count: Int
    ) {
        var offset = 0
        while offset < count {
            let n = write(fd, bytes + offset, count - offset)
            if n <= 0 { return }
            offset += n
        }
    }

    private static func writeLiteral(_ fd: Int32, _ literal: StaticString) {
        literal.withUTF8Buffer { bytes in
            guard let base = bytes.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                writeFully(fd, $0, count: bytes.count)
            }
        }
    }
}
