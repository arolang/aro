// ============================================================
// RequestBodyLimitTests.swift
// Request body limits and streaming (GitLab #477)
// ============================================================

import Testing
import Foundation
import AROParser
import Crypto
@testable import ARORuntime

@Suite("Request body limits (#477)")
struct RequestBodyLimitTests {

    // MARK: - ByteSize

    @Test("sizes are parsed the way humans write them")
    func parsesHumanSizes() {
        #expect(ByteSize.parse("1MB") == 1_000_000)
        #expect(ByteSize.parse("1mb") == 1_000_000)
        #expect(ByteSize.parse("512KB") == 512_000)
        #expect(ByteSize.parse("1MiB") == 1_048_576)
        #expect(ByteSize.parse("2 GB") == 2_000_000_000)
        #expect(ByteSize.parse("1.5MB") == 1_500_000)
        #expect(ByteSize.parse("2048") == 2048)
        #expect(ByteSize.parse("2048B") == 2048)
    }

    @Test("a value that is not a size is refused, not guessed")
    func refusesNonSizes() {
        #expect(ByteSize.parse("") == nil)
        #expect(ByteSize.parse("big") == nil)
        #expect(ByteSize.parse("MB") == nil)
        #expect(ByteSize.parse("-5MB") == nil)
    }

    @Test("describe round-trips through parse")
    func describeRoundTrips() {
        for bytes in [999, 1_000, 1_000_000, 2_500_000, 3_000_000_000] {
            let text = ByteSize.describe(bytes)
            if bytes >= 1_000 {
                #expect(ByteSize.parse(text) == bytes, "\(text) should parse back to \(bytes)")
            }
        }
    }

    // MARK: - Policy

    @Test("a route nothing is known about is bounded, not trusted")
    func defaultPolicyIsBounded() {
        let policy = BodyPolicy.default
        #expect(policy.mode == .buffered)
        #expect(policy.limit == RuntimeDefaults.maxMaterializedBody)
    }

    @Test("a streamed route has no wire limit but keeps a materialization ceiling")
    func streamedPolicyHasNoWireLimit() {
        let policy = BodyPolicy.streamed(materializationLimit: 4_000)
        #expect(policy.limit == nil)
        #expect(policy.materializationLimit == 4_000)
    }

    // MARK: - Contract

    @Test("x-aro-max-body is read off the operation, as text or as a number")
    func readsDeclaredLimit() throws {
        let yaml = """
        openapi: 3.0.3
        info:
          title: T
          version: 1.0.0
        paths:
          /a:
            post:
              operationId: withText
              x-aro-max-body: 256KB
              responses:
                '200':
                  description: ok
          /b:
            post:
              operationId: withNumber
              x-aro-max-body: 2048
              responses:
                '200':
                  description: ok
          /c:
            post:
              operationId: withNothing
              responses:
                '200':
                  description: ok
        """
        let spec = try OpenAPILoader.parse(data: Data(yaml.utf8), filename: "openapi.yaml")
        #expect(spec.paths["/a"]?.post?.maxBodyBytes == 256_000)
        #expect(spec.paths["/b"]?.post?.maxBodyBytes == 2048)
        #expect(spec.paths["/c"]?.post?.maxBodyBytes == nil)
    }

    // MARK: - Parsing parity

    @Test("a materialized stream parses to the same value as a buffered body")
    func parsingParity() {
        let json = Data(#"{"name":"Ada","age":36}"#.utf8)
        let parsed = RequestBodyParser.parse(json, contentType: "application/json")
        let dictionary = parsed as? [String: any Sendable]
        #expect(dictionary?["name"] as? String == "Ada")
        #expect(dictionary?["age"] as? Int == 36)

        let form = Data("a=1&b=two".utf8)
        let parsedForm = RequestBodyParser.parse(form, contentType: "application/x-www-form-urlencoded")
        let formDictionary = parsedForm as? [String: any Sendable]
        #expect(formDictionary?["b"] as? String == "two")

        // Not JSON, not a form: the text itself, as the buffered path did.
        let text = RequestBodyParser.parse(Data("plain".utf8), contentType: "text/plain")
        #expect(text as? String == "plain")
    }

    // MARK: - Reading a stream

    private func makeBody(
        chunks: [Data],
        limit: Int?,
        declaredLength: Int? = nil,
        contentType: String? = "application/json"
    ) -> RequestBodyValue {
        let stream = AROStream<Data> {
            AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        }
        return RequestBodyValue(
            source: RequestBodyStream(chunks: stream, declaredLength: declaredLength, limit: limit),
            contentType: contentType,
            route: "POST /test"
        )
    }

    @Test("reading a body inside the limit gives the parsed value")
    func readsWithinLimit() async throws {
        let body = makeBody(chunks: [Data(#"{"a":"#.utf8), Data(#"1}"#.utf8)], limit: 1_000)
        let value = try await body.materialize(statement: "Extract the <a> from the <body: a>")
        #expect((value as? [String: any Sendable])?["a"] as? Int == 1)
    }

    @Test("reading past the limit stops at the limit and names both fixes")
    func refusesToReadPastLimit() async {
        let chunk = Data(repeating: 0x41, count: 4_096)
        let body = makeBody(chunks: [chunk, chunk, chunk], limit: 5_000)

        do {
            _ = try await body.materialize(statement: "Extract the <text> from the <note: text>")
            Issue.record("reading a body past its limit should throw")
        } catch let error as RequestBodyError {
            let message = error.description
            #expect(message.contains("Extract the <text> from the <note: text>"))
            #expect(message.contains("5KB"))
            #expect(message.contains("x-aro-max-body"))
            #expect(message.contains("Stream it"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a declared length over the limit is refused before anything is read")
    func refusesDeclaredLengthUpFront() async {
        let body = makeBody(chunks: [Data(repeating: 0x41, count: 10)], limit: 1_000, declaredLength: 50_000)
        do {
            _ = try await body.materialize(statement: "Extract the <x> from the <body: x>")
            Issue.record("an oversized Content-Length should be refused")
        } catch let error as RequestBodyError {
            #expect(error.description.contains("50KB"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a body arrives once: the second consumer is told who took it")
    func bodyIsConsumedOnce() throws {
        let body = makeBody(chunks: [Data("x".utf8)], limit: 1_000)
        _ = try body.chunks(consumer: "Write the <upload> to the <file: target>")

        do {
            _ = try body.chunks(consumer: "Return an <OK: status> with <upload>")
            Issue.record("consuming a body twice should throw")
        } catch let error as RequestBodyError {
            #expect(error.description.contains("already consumed"))
            #expect(error.description.contains("Write the <upload>"))
        }
    }

    // MARK: - Anchoring

    @Test("an emitted body is anchored to a file and read back by several handlers")
    func anchoringSurvivesTheRequest() async throws {
        let payload = Data(repeating: 0x42, count: 200_000)
        let body = makeBody(
            chunks: stride(from: 0, to: payload.count, by: 65_536).map { offset in
                payload.subdata(in: offset..<min(offset + 65_536, payload.count))
            },
            limit: 1_000,
            contentType: "application/octet-stream"
        )

        let anchored = try await AnchoredBody.anchor(body, statement: "Emit a <Received: event> with <upload>")
        #expect(anchored.byteCount == payload.count)

        // Two independent readers, because an event may have many handlers.
        for _ in 0..<2 {
            var seen = Data()
            let stream = try anchored.chunkStream(consumer: "test")
            for try await chunk in stream.stream {
                seen.append(chunk)
            }
            #expect(seen == payload)
        }
    }

    @Test("an anchored body deletes its file when the last reference goes")
    func anchorCleansUpAfterItself() async throws {
        let body = makeBody(chunks: [Data("gone soon".utf8)], limit: 1_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-anchored", isDirectory: true)

        var anchored: AnchoredBody? = try await AnchoredBody.anchor(body, statement: "Publish as <x> <upload>")
        let path = try #require(anchored?.file.path)
        // The anchor directory is shared, so watch this body's own file rather
        // than counting entries another test may be adding to.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(directory.path.hasSuffix("aro-anchored"))

        anchored = nil
        #expect(!FileManager.default.fileExists(atPath: path),
                "the last reference going away takes the file with it")
    }

    // MARK: - Streaming to a file

    @Test("a streamed write publishes the file only once it is complete")
    func streamedWriteIsAtomic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("out.bin").path
        let failing = AROStream<Data> {
            AsyncThrowingStream { continuation in
                continuation.yield(Data(repeating: 0x43, count: 1_000))
                continuation.finish(throwing: RequestBodyError.alreadyConsumed(
                    route: "POST /x", by: "first", now: "second"))
            }
        }

        do {
            _ = try await StreamingFileWriter.write(failing, to: target)
            Issue.record("a truncated stream should fail the write")
        } catch {
            // Expected.
        }

        #expect(!FileManager.default.fileExists(atPath: target),
                "a half-written upload must not appear under its real name")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers.isEmpty, "the partial file must be cleaned up, found \(leftovers)")
    }

    // MARK: - Folding without building (#477 / #486)

    private func chunks(_ payload: Data, size: Int) -> AROStream<Data> {
        let pieces = stride(from: 0, to: max(payload.count, 1), by: size).map { offset in
            payload.subdata(in: offset..<min(offset + size, payload.count))
        }
        return AROStream<Data> {
            AsyncThrowingStream { continuation in
                for piece in pieces where !piece.isEmpty { continuation.yield(piece) }
                continuation.finish()
            }
        }
    }

    @Test("a streamed digest equals the digest of the whole body")
    func streamedDigestMatches() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let streamed = try await BodyFold.digest.apply(to: chunks(payload, size: 4_096))
        let whole = SHA256.hash(data: payload).compactMap { String(format: "%02x", $0) }.joined()
        #expect(streamed as? String == whole)
    }

    @Test("a streamed byte count equals the body's size")
    func streamedByteCount() async throws {
        let payload = Data(repeating: 0x41, count: 123_456)
        let counted = try await BodyFold.byteCount.apply(to: chunks(payload, size: 1_000))
        #expect(counted as? Int == 123_456)
    }

    @Test("lines are split across chunk boundaries, without a phantom last line")
    func streamedLines() async throws {
        // The newline between "beta" and "gamma" lands mid-chunk on purpose.
        let payload = Data("alpha\nbeta\ngamma\r\ndelta\n".utf8)
        let value = try await BodyFold.lines.apply(to: chunks(payload, size: 7))
        let streaming = try #require(value as? AnyStreamingValue)
        let lines = try await streaming.materialize().compactMap { $0 as? String }
        #expect(lines == ["alpha", "beta", "gamma", "delta"])
    }

    @Test("a body with no trailing newline keeps its last line")
    func streamedLinesWithoutTrailingNewline() async throws {
        let value = try await BodyFold.lines.apply(to: chunks(Data("one\ntwo".utf8), size: 3))
        let streaming = try #require(value as? AnyStreamingValue)
        let lines = try await streaming.materialize().compactMap { $0 as? String }
        #expect(lines == ["one", "two"])
    }

    @Test("only the qualifiers that can fold are treated as folds")
    func foldTable() {
        #expect(BodyFold.forQualifier("sha256") == .digest)
        #expect(BodyFold.forQualifier("hash") == .digest)
        #expect(BodyFold.forQualifier("length") == .byteCount)
        #expect(BodyFold.forQualifier("lines") == .lines)
        // Collection folds are questions about records, not about bytes.
        #expect(BodyFold.forQualifier("sum") == nil)
        #expect(BodyFold.forQualifier("avg") == nil)
        #expect(BodyFold.forQualifier("join") == nil)
        #expect(BodyFold.forQualifier("uppercase") == nil)
    }

    // MARK: - Metrics

    @Test("materialized and streamed bytes are counted separately")
    func metricsSeparateTheTwoPaths() {
        let collector = MetricsCollector()
        collector.recordBodyMaterialized(bytes: 100)
        collector.recordBodyStreamed(bytes: 4_000)
        collector.recordBodyRejected(method: "POST", path: "/notes")

        let snapshot = collector.snapshot()
        #expect(snapshot.bodyMetrics.materializedBytes == 100)
        #expect(snapshot.bodyMetrics.streamedBytes == 4_000)
        #expect(snapshot.bodyMetrics.rejectedCount == 1)
        #expect(snapshot.bodyMetrics.rejectedRoutes["POST /notes"] == 1)
    }
}
