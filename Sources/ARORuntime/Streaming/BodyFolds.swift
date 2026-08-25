// ============================================================
// BodyFolds.swift
// ARO Runtime - Computing over a body without building it (GitLab #477)
// ============================================================
//
// Some questions about a body do not need the body. A digest, a
// byte count, a line at a time: each of these can be answered
// while the bytes go past, and none of them needs a single place
// where the whole thing exists.
//
// The qualifier namespace is closed (GitLab #486), so the runtime
// already knows which qualifiers those are. This is the table,
// and `StreamConsumptionPolicy.foldingQualifiers` in AROParser is
// the same list seen by the analysis — one set, so what the
// analyzer predicts and what the runtime does cannot drift.
//
// What a fold sees is the **raw bytes**, because on a route that
// never reads its body the raw bytes are all there is. Hashing an
// upload therefore hashes the upload.

import Foundation
import AROParser
import Crypto

/// A computation that can consume a body chunk by chunk.
public enum BodyFold: Sendable, Equatable {
    /// SHA-256 over the raw bytes, hex encoded (`sha256`, `hash`).
    case digest
    /// Number of bytes (`length`, `count`, `size`).
    case byteCount
    /// The body's lines, lazily (`lines`).
    case lines

    /// The fold a qualifier names, or nil when the qualifier needs the value.
    public static func forQualifier(_ name: String) -> BodyFold? {
        switch name.lowercased() {
        case "sha256", "hash": return .digest
        case "length", "count", "size": return .byteCount
        case "lines": return .lines
        default: return nil
        }
    }

    /// Run this fold over a stream of chunks.
    public func apply(to stream: AROStream<Data>) async throws -> any Sendable {
        switch self {
        case .digest:
            var hasher = SHA256()
            var bytes = 0
            for try await chunk in stream.stream {
                hasher.update(data: chunk)
                bytes += chunk.count
            }
            MetricsCollector.shared.recordBodyStreamed(bytes: bytes)
            return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()

        case .byteCount:
            var bytes = 0
            for try await chunk in stream.stream {
                bytes += chunk.count
            }
            MetricsCollector.shared.recordBodyStreamed(bytes: bytes)
            return bytes

        case .lines:
            // Lazy on purpose: `for each <line> in <ls>` then iterates without
            // the lines ever being a list. A statement that does need the list
            // materializes it through the usual `AnyStreamingValue` path, and
            // is bounded by the same limit as any other read.
            return AnyStreamingValue(AROValue<any Sendable>.lazy(Self.lineStream(over: stream)))
        }
    }

    /// Split a byte stream into lines across chunk boundaries.
    ///
    /// A newline can land anywhere, including between two chunks, so the tail
    /// of each chunk is carried into the next. The trailing newline does not
    /// produce a phantom empty line — the same rule the buffered `lines`
    /// qualifier follows, because the two must agree.
    static func lineStream(over stream: AROStream<Data>) -> AROStream<any Sendable> {
        AROStream<any Sendable> {
            AsyncThrowingStream { continuation in
                Task {
                    var carry = Data()
                    let newline = UInt8(ascii: "\n")
                    do {
                        for try await chunk in stream.stream {
                            carry.append(chunk)
                            while let index = carry.firstIndex(of: newline) {
                                let lineBytes = carry[carry.startIndex..<index]
                                carry = carry[carry.index(after: index)...]
                                continuation.yield(Self.text(from: lineBytes))
                            }
                        }
                        if !carry.isEmpty {
                            continuation.yield(Self.text(from: carry[carry.startIndex...]))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    private static func text(from bytes: Data.SubSequence) -> String {
        var line = Data(bytes)
        // Tolerate CRLF, which is what an upload from a Windows client has.
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        return String(data: line, encoding: .utf8) ?? ""
    }
}
