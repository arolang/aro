// ============================================================
// StreamReaderTests.swift
// SOLARO — chunked file reading (#487)
// ============================================================
//
// The point of these tests is the chunk boundary. A reader that
// decodes each chunk independently looks correct on ASCII and on
// any small test file, and corrupts real content the moment a
// multi-byte scalar happens to straddle a read — which, at a fixed
// buffer size, is a property of where the bytes fall, not of the
// file being unusual. So every case here uses a deliberately tiny
// buffer and puts multi-byte scalars at every offset across it.

import Testing
import Foundation
@testable import SOLARO

@Suite("StreamReader")
struct StreamReaderTests {

    // MARK: - Fixtures

    private func tmpFile(_ contents: String,
                         name: String = UUID().uuidString) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-stream-\(name)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func tmpFile(bytes: [UInt8]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-stream-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - Round-trip

    @Test("Reading back a file reproduces it exactly",
          arguments: [
            "",
            "plain ascii\n",
            "no trailing newline",
            "crlf\r\nlines\r\n",
            "emoji 👩‍👩‍👧‍👦 and ümlauts and 漢字\n",
            "trailing blank lines\n\n\n",
          ])
    func roundTrip(source: String) throws {
        let url = try tmpFile(source)
        defer { try? FileManager.default.removeItem(at: url) }
        // A 3-byte buffer guarantees multi-byte scalars are split.
        #expect(StreamReader(url: url, bufferSize: 3).readAll() == source)
    }

    @Test("A multi-byte scalar split across a chunk boundary survives")
    func scalarAcrossChunkBoundary() throws {
        // "…" is 3 bytes (E2 80 A6). With a 4-byte buffer, shifting
        // it one byte at a time walks the split across every
        // possible offset: 0/3, 1/2, 2/1, 3/0.
        for padding in 0..<8 {
            let source = String(repeating: "a", count: padding) + "…tail"
            let url = try tmpFile(source)
            defer { try? FileManager.default.removeItem(at: url) }
            let read = StreamReader(url: url, bufferSize: 4).readAll()
            #expect(read == source, "padding \(padding) corrupted the scalar")
            #expect(!read.contains("\u{FFFD}"))
        }
    }

    @Test("A 4-byte scalar split across a boundary survives")
    func fourByteScalarAcrossBoundary() throws {
        for padding in 0..<8 {
            // U+1F600 is 4 bytes — the widest UTF-8 encoding, and
            // the one most likely to straddle a small buffer.
            let source = String(repeating: "x", count: padding) + "😀end"
            let url = try tmpFile(source)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(StreamReader(url: url, bufferSize: 5).readAll() == source)
        }
    }

    @Test("Many chunks reassemble in order")
    func multiChunkOrdering() throws {
        let source = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let url = try tmpFile(source)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(StreamReader(url: url, bufferSize: 64).readAll() == source)
    }

    @Test("Batches concatenate back to the file")
    func batchesConcatenate() throws {
        let source = (1...300).map { "ünïcode line \($0) 漢字" }
            .joined(separator: "\n")
        let url = try tmpFile(source)
        defer { try? FileManager.default.removeItem(at: url) }
        var rebuilt = ""
        var batches = 0
        StreamReader(url: url, bufferSize: 32)
            .streamBatches(batchBytes: 17) { batch in
                rebuilt += batch
                batches += 1
                return true
            }
        #expect(rebuilt == source)
        #expect(batches > 1, "batch size too large to exercise batching")
    }

    @Test("Returning false from a batch stops the read")
    func batchesCancel() throws {
        let source = String(repeating: "0123456789", count: 500)
        let url = try tmpFile(source)
        defer { try? FileManager.default.removeItem(at: url) }
        var seen = 0
        StreamReader(url: url, bufferSize: 64)
            .streamBatches(batchBytes: 100) { _ in
                seen += 1
                return seen < 3
            }
        #expect(seen == 3)
    }

    // MARK: - Head

    @Test("Head reads only what was asked for")
    func headIsBounded() throws {
        let source = String(repeating: "abcdefghij", count: 1000)
        let url = try tmpFile(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let head = StreamReader(url: url, bufferSize: 64).head(maxScalars: 25)
        #expect(head.unicodeScalars.count == 25)
        #expect(head == String(source.prefix(25)))
    }

    @Test("Head of a file shorter than the request returns the file")
    func headShorterThanRequest() throws {
        let url = try tmpFile("short")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(StreamReader(url: url).head(maxScalars: 4096) == "short")
    }

    // MARK: - Lines

    @Test("Lines are yielded without their terminators")
    func lineIteration() throws {
        let url = try tmpFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(at: url) }
        var lines: [(Int, String)] = []
        StreamReader(url: url, bufferSize: 2).forEachLine { number, line in
            lines.append((number, line))
            return true
        }
        #expect(lines.map(\.0) == [1, 2, 3])
        #expect(lines.map(\.1) == ["one", "two", "three"])
    }

    @Test("A file without a trailing newline still yields its last line")
    func lastLineWithoutTerminator() throws {
        let url = try tmpFile("alpha\nbeta")
        defer { try? FileManager.default.removeItem(at: url) }
        var lines: [String] = []
        StreamReader(url: url).forEachLine { _, line in
            lines.append(line)
            return true
        }
        #expect(lines == ["alpha", "beta"])
    }

    @Test("CRLF terminators are stripped for matching")
    func crlfLines() throws {
        let url = try tmpFile("one\r\ntwo\r\n")
        defer { try? FileManager.default.removeItem(at: url) }
        var lines: [String] = []
        StreamReader(url: url).forEachLine { _, line in
            lines.append(line)
            return true
        }
        #expect(lines == ["one", "two"])
    }

    @Test("Returning false stops line iteration")
    func lineIterationStops() throws {
        let url = try tmpFile((1...100).map(String.init).joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url) }
        var seen = 0
        StreamReader(url: url).forEachLine { _, _ in
            seen += 1
            return seen < 5
        }
        #expect(seen == 5)
    }

    // MARK: - Offsets

    @Test("Line offsets address the line inside the whole document")
    func lineOffsetsMatchDocument() throws {
        let source = "alpha\nbrävo\ncharlie\n漢字\ndelta"
        let url = try tmpFile(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let ns = source as NSString
        StreamReader(url: url, bufferSize: 3)
            .forEachLineWithOffset { _, line, offset in
                // The offset + the line's own length must carve
                // exactly that line out of the whole document —
                // this is what makes streamed find-and-replace
                // ranges land in the right place.
                let range = NSRange(location: offset,
                                    length: (line as NSString).length)
                #expect(ns.substring(with: range) == line)
                return true
            }
    }

    @Test("CRLF is preserved in offset-bearing lines")
    func offsetsSurviveCRLF() throws {
        let source = "one\r\ntwo\r\nthree"
        let url = try tmpFile(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let ns = source as NSString
        var lines: [String] = []
        StreamReader(url: url).forEachLineWithOffset { _, line, offset in
            lines.append(line)
            let range = NSRange(location: offset,
                                length: (line as NSString).length)
            #expect(ns.substring(with: range) == line)
            return true
        }
        // The `\r` stays put — dropping it would shift every
        // subsequent offset by one.
        #expect(lines == ["one\r", "two\r", "three"])
    }

    // MARK: - Degenerate input

    @Test("An invalid byte does not truncate the rest of the file")
    func invalidByteIsReplaced() throws {
        // 0xFF is never valid UTF-8.
        var bytes = Array("before".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Array("after".utf8))
        let url = try tmpFile(bytes: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = StreamReader(url: url, bufferSize: 4).readAll()
        #expect(read.hasPrefix("before"))
        #expect(read.hasSuffix("after"))
        #expect(read.contains("\u{FFFD}"))
    }

    @Test("A missing file reads as empty rather than trapping")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/solaro/\(UUID().uuidString)")
        #expect(StreamReader(url: url).readAll() == "")
        #expect(StreamReader(url: url).head(maxScalars: 10) == "")
        #expect(StreamReader.byteSize(of: url) == nil)
    }
}

@Suite("LargeFilePolicy")
struct LargeFilePolicyTests {

    private func tmpFile(bytes count: Int) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-large-\(UUID().uuidString)")
        try Data(repeating: 0x61, count: count).write(to: url)
        return url
    }

    @Test("A normal source file is neither large nor unparseable")
    func smallFile() throws {
        let url = try tmpFile(bytes: 4096)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!LargeFilePolicy.isLarge(url))
        #expect(LargeFilePolicy.shouldParse(url))
    }

    @Test("Past the parse threshold, parsing is off but the guard is not")
    func betweenThresholds() throws {
        let url = try tmpFile(bytes: LargeFilePolicy.parseThreshold + 1)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!LargeFilePolicy.shouldParse(url))
        #expect(!LargeFilePolicy.isLarge(url))
    }

    @Test("Past the guard threshold the file opens read-only")
    func aboveGuard() throws {
        let url = try tmpFile(bytes: LargeFilePolicy.guardThreshold)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LargeFilePolicy.isLarge(url))
        #expect(!LargeFilePolicy.shouldParse(url))
        #expect(!LargeFilePolicy.describeSize(url).isEmpty)
    }

    @Test("A guarded file is never written back")
    func guardedFileIsNotWritable() throws {
        // The regression this locks down: streaming a file into the
        // editor buffer pushes it through the binding, and a binding
        // that writes would put the partial buffer on disk over the
        // file still being read.
        let big = try tmpFile(bytes: LargeFilePolicy.guardThreshold)
        defer { try? FileManager.default.removeItem(at: big) }
        #expect(!LargeFilePolicy.allowsWriteBack(big))

        let small = try tmpFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: small) }
        #expect(LargeFilePolicy.allowsWriteBack(small))
    }

    @Test("The parse threshold sits below the guard threshold")
    func thresholdOrdering() {
        // Parsing costs far more per byte than displaying, so it has
        // to switch off first. Inverting these would mean a file
        // that opens read-only still gets lexed on every load.
        #expect(LargeFilePolicy.parseThreshold < LargeFilePolicy.guardThreshold)
    }

    @Test("A missing file is treated as small, not as a 0-byte guard trip")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        #expect(!LargeFilePolicy.isLarge(url))
        #expect(LargeFilePolicy.shouldParse(url))
    }
}
