// ============================================================
// ConsoleLineAssemblerTests.swift
// SOLARO — console chunk → line reassembly (GitLab #541)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("ConsoleLineAssembler")
struct ConsoleLineAssemblerTests {

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test("Complete lines in one chunk come out whole, in order")
    func wholeChunk() {
        var a = ConsoleLineAssembler()
        #expect(a.append(bytes("one\ntwo\nthree\n")) == ["one", "two", "three"])
        #expect(a.flush().isEmpty)
    }

    /// The headline bug: a line split across two reads used to land
    /// as two separate log rows.
    @Test("A line split across reads is emitted once, joined")
    func splitLine() {
        var a = ConsoleLineAssembler()
        #expect(a.append(bytes("Can not retrieve the user from the ")).isEmpty)
        #expect(a.append(bytes("user-repository where id = 530\n"))
                == ["Can not retrieve the user from the user-repository where id = 530"])
    }

    @Test("A chunk that splits a multi-byte scalar keeps its text")
    func utf8Boundary() {
        var a = ConsoleLineAssembler()
        let full = Array(bytes("héllo ⏸ wörld\n"))
        // Cut inside the ⏸ (3 bytes) — the old code dropped the
        // whole chunk here because String(data:encoding:.utf8) fails.
        let cut = full.firstIndex(of: 0xE2)! + 1
        #expect(a.append(Data(full[..<cut])).isEmpty)
        #expect(a.append(Data(full[cut...])) == ["héllo ⏸ wörld"])
    }

    @Test("Blank lines survive")
    func blankLines() {
        var a = ConsoleLineAssembler()
        #expect(a.append(bytes("a\n\nb\n")) == ["a", "", "b"])
    }

    @Test("A trailing newline does not fabricate an empty line")
    func noPhantomTrailingLine() {
        var a = ConsoleLineAssembler()
        #expect(a.append(bytes("only\n")) == ["only"])
        #expect(a.flush().isEmpty)
    }

    @Test("An unterminated tail is emitted at EOF")
    func flushesTail() {
        var a = ConsoleLineAssembler()
        #expect(a.append(bytes("no newline here")).isEmpty)
        #expect(a.flush() == ["no newline here"])
        #expect(a.flush().isEmpty)
    }

    @Test("CRLF loses only the CR")
    func crlf() {
        var a = ConsoleLineAssembler()
        #expect(a.append(bytes("windows\r\nline\r\n")) == ["windows", "line"])
    }

    @Test("An escape sequence split across reads leaves no residue")
    func escapeAcrossChunks() {
        var a = ConsoleLineAssembler()
        #expect(a.append(bytes("start \u{001B}")).isEmpty)
        #expect(a.append(bytes("[31mred\u{001B}[0m end\n")) == ["start red end"])
    }

    @Test("A runaway line without a terminator is bounded, not buffered forever")
    func boundedLine() {
        var a = ConsoleLineAssembler()
        let big = String(repeating: "x", count: ConsoleLineAssembler.maxLineBytes + 16)
        let lines = a.append(bytes(big))
        #expect(lines.count == 1)
        #expect(lines[0].count == big.count)
        #expect(a.flush().isEmpty)
    }

    @Test("Byte-at-a-time feeding reassembles the same lines")
    func bytewise() {
        var a = ConsoleLineAssembler()
        var out: [String] = []
        for byte in bytes("alpha\nbeta\n") {
            out += a.append(Data([byte]))
        }
        #expect(out == ["alpha", "beta"])
    }
}

@Suite("ANSIEscape")
struct ANSIEscapeTests {

    @Test("SGR colour codes vanish, text stays")
    func sgr() {
        #expect(ANSIEscape.strip("\u{001B}[1;31mERROR\u{001B}[0m: boom")
                == "ERROR: boom")
    }

    /// The old strip stopped at the first *letter*, so an OSC title
    /// spilled its payload into the log.
    @Test("An OSC sequence takes its whole payload with it")
    func osc() {
        #expect(ANSIEscape.strip("\u{001B}]0;Building ARO\u{0007}done") == "done")
        #expect(ANSIEscape.strip("\u{001B}]0;Title\u{001B}\\after") == "after")
    }

    @Test("Two-character escapes consume exactly two characters")
    func twoCharEscape() {
        #expect(ANSIEscape.strip("a\u{001B}=b") == "ab")
    }

    @Test("Text without escapes is returned unchanged")
    func passthrough() {
        let plain = "plain ⏸ text with [brackets] and 100% no escapes"
        #expect(ANSIEscape.strip(plain) == plain)
    }

    @Test("A dangling ESC at end of line is dropped, not echoed")
    func danglingEscape() {
        #expect(ANSIEscape.strip("tail\u{001B}") == "tail")
        #expect(ANSIEscape.strip("tail\u{001B}[") == "tail")
    }
}
