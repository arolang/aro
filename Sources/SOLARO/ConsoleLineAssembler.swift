// ============================================================
// ConsoleLineAssembler.swift
// SOLARO — chunk → line reassembly for process output
// ============================================================
//
// A pipe read hands back whatever bytes happen to be available:
// half a line, three-and-a-half lines, or the tail of a UTF-8
// scalar whose lead byte arrived in the previous read. The console
// used to treat every chunk as a self-contained unit, which cost it
// three ways (GitLab #541):
//
//   * a line longer than one read — guaranteed for output bursts
//     over the pipe buffer — landed as two or more log rows, so
//     runtime errors and JSON payloads were chopped at arbitrary
//     byte positions;
//   * a chunk that split a multi-byte scalar failed
//     `String(data:encoding:.utf8)` and was dropped *whole*;
//   * an ANSI escape straddling the boundary leaked its tail into
//     the visible text as `[0m`-shaped garbage.
//
// This is the pattern `ReplKernelClient.consumeStdout` already uses
// for the kernel protocol, and the one `StreamReader` documents for
// file reads: accumulate bytes, cut only at 0x0A, carry the
// remainder into the next read, decode and clean whole lines only.
//
// Blank lines survive. Program output uses them for structure, and
// the old `filter { !$0.isEmpty }` deleted them along with the
// trailing-newline artifact it was really aiming at — the artifact
// is now impossible by construction, because a line is only emitted
// once its terminator has been seen.

import Foundation

/// Splits a byte stream into complete, decoded, ANSI-free lines,
/// carrying partial lines across reads.
struct ConsoleLineAssembler {

    /// Bytes seen since the last newline.
    private var carry = Data()

    /// A "line" this long with no terminator in sight is flushed as
    /// one line rather than growing the buffer without bound — a
    /// child writing megabytes without a newline (a binary blob on
    /// stdout, say) must not be able to exhaust memory.
    static let maxLineBytes = 1 << 20   // 1 MB

    init() {}

    /// Feed one pipe read. Returns every line the chunk completed,
    /// in order; the trailing partial line is kept for next time.
    mutating func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        carry.append(data)
        var lines: [String] = []
        while let idx = carry.firstIndex(of: 0x0A) {
            lines.append(Self.line(from: carry[carry.startIndex..<idx]))
            carry.removeSubrange(carry.startIndex...idx)
        }
        if carry.count > Self.maxLineBytes {
            lines.append(Self.line(from: carry[...]))
            carry.removeAll(keepingCapacity: true)
        }
        return lines
    }

    /// End of stream: emit whatever is left, unterminated. A process
    /// that exits without a final newline still gets its last line
    /// into the log.
    mutating func flush() -> [String] {
        guard !carry.isEmpty else { return [] }
        let line = Self.line(from: carry[...])
        carry.removeAll(keepingCapacity: true)
        return [line]
    }

    /// Decode → drop the CR of a CRLF → strip escapes. Decoding uses
    /// the replacement-character form, so genuinely invalid bytes
    /// cost one glyph instead of the whole line.
    private static func line(from bytes: Data) -> String {
        var text = String(decoding: bytes, as: UTF8.self)
        if text.hasSuffix("\r") { text.removeLast() }
        return ANSIEscape.strip(text)
    }
}

/// Terminal escape-sequence removal.
///
/// The previous implementation ate everything from ESC to the next
/// *letter*, which is right for SGR (`ESC [ 0 m`) and wrong for
/// everything else: an OSC window title (`ESC ] 0 ; Building… BEL`)
/// stops at the first letter of the payload and spills the rest into
/// the log. This walks the actual grammar of the sequences a CLI
/// emits, so the payload of a string sequence goes with it.
enum ANSIEscape {

    nonisolated static func strip(_ input: String) -> String {
        guard input.contains("\u{001B}") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        let scalars = Array(input.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            guard s == "\u{001B}" else {
                out.unicodeScalars.append(s)
                i += 1
                continue
            }
            i += 1
            guard i < scalars.count else { break }   // dangling ESC
            switch scalars[i] {
            case "[":
                // CSI: parameter/intermediate bytes, then a final
                // byte in 0x40…0x7E.
                i += 1
                while i < scalars.count {
                    let v = scalars[i].value
                    i += 1
                    if (0x40...0x7E).contains(v) { break }
                }
            case "]", "P", "X", "^", "_":
                // String sequences (OSC / DCS / SOS / PM / APC):
                // run to BEL or to the string terminator ESC \.
                i += 1
                while i < scalars.count {
                    if scalars[i] == "\u{0007}" { i += 1; break }
                    if scalars[i] == "\u{001B}",
                       i + 1 < scalars.count, scalars[i + 1] == "\\" {
                        i += 2
                        break
                    }
                    i += 1
                }
            default:
                // Two-character escape (ESC c, ESC =, …).
                i += 1
            }
        }
        return out
    }
}
