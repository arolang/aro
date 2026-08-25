// ============================================================
// AnchoredBody.swift
// ARO Runtime - A body that outlives its request (GitLab #477)
// ============================================================
//
// `Emit`, `Publish as` and a repository `Store` hand a value to
// something that outlives the statement that produced it. A
// request body cannot go through as it is: it is tied to a
// connection that will be closed, and it can only be read once,
// while an event may have many handlers.
//
// So it is *anchored*: drained to a file next to the process's
// temporary directory as it arrives, one chunk at a time, and
// handed on as a value that any number of readers can open
// independently. Memory stays at one chunk; the file is deleted
// when the last reference to it goes away, which is ordinary ARC
// rather than a lifetime rule anyone has to remember.
//
// This is the one place spooling survives in #477's design, and
// it is the exception with a reason: crossing a lifetime
// boundary, not the default path.

import Foundation

/// A request body that has been drained to a file so it can outlive the
/// request it arrived on.
public final class AnchoredBody: UnreadBody, @unchecked Sendable, Equatable, CustomStringConvertible {

    /// Where the bytes live until the last reader is done with them.
    /// Internal rather than private so a test can watch it disappear.
    let file: URL

    public let contentType: String?
    public let route: String
    public let byteCount: Int

    private init(file: URL, contentType: String?, route: String, byteCount: Int) {
        self.file = file
        self.contentType = contentType
        self.route = route
        self.byteCount = byteCount
    }

    deinit {
        // The last holder releases the disk. No explicit lifetime to track and
        // no cleanup pass to forget: when nothing refers to the body, the file
        // it lived in is gone.
        try? FileManager.default.removeItem(at: file)
    }

    public var description: String {
        "<body> of \(route), \(ByteSize.describe(byteCount)) anchored"
    }

    public static func == (lhs: AnchoredBody, rhs: AnchoredBody) -> Bool {
        lhs === rhs
    }

    /// Drain a request body to disk. Reads one chunk at a time, so the memory
    /// cost is a chunk regardless of the body's size.
    public static func anchor(_ body: RequestBodyValue, statement: String) async throws -> AnchoredBody {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-anchored", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(UUID().uuidString)

        let chunks = try body.chunks(consumer: statement)
        let written = try await StreamingFileWriter.write(chunks, to: file.path)
        MetricsCollector.shared.recordBodyStreamed(bytes: written)

        return AnchoredBody(
            file: file,
            contentType: body.contentType,
            route: body.route,
            byteCount: written
        )
    }

    /// The bytes, again. Unlike a live body an anchored one can be read as
    /// often as it is needed — that is what anchoring buys, and why an event
    /// with three handlers works.
    public func chunks() -> AROStream<Data> {
        let path = file.path
        let chunkSize = RuntimeDefaults.bodyChunkSize
        // Capture self so the file cannot be deleted while a reader still has
        // a stream open over it.
        let anchor = self
        return AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    _ = anchor
                    do {
                        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                        defer { try? handle.close() }
                        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Read the whole thing as a value, bounded the same way a live body is.
    public func materialize(statement: String, limit: Int? = nil) async throws -> any Sendable {
        let ceiling = limit ?? RuntimeDefaults.maxMaterializedBody
        guard byteCount <= ceiling else {
            throw RequestBodyError.tooLargeToRead(
                route: route, statement: statement, size: byteCount, limit: ceiling)
        }
        let data = try Data(contentsOf: file)
        MetricsCollector.shared.recordBodyMaterialized(bytes: data.count)
        return RequestBodyParser.parse(data, contentType: contentType)
    }

    // MARK: - UnreadBody

    public func chunkStream(consumer: String) throws -> AROStream<Data> {
        // An anchored body is re-readable, so the consumer name is only
        // context for errors — there is nothing to take exclusively.
        _ = consumer
        return chunks()
    }

    public func materializedValue(statement: String) async throws -> any Sendable {
        try await materialize(statement: statement)
    }
}
