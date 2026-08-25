// ============================================================
// RequestBodyValue.swift
// ARO Runtime - The request body as ARO sees it (GitLab #477)
// ============================================================
//
// What `<request: body>` binds to on a route that streams. It is
// not the bytes: it is the promise of them, in arrival order.
//
// Moving it (`Write … to the <file: …>`, `Return … with <it>`,
// `for each <chunk> in <it>`) consumes chunks and never builds
// the whole. Reading it (a field access, a parse, a fold) calls
// `materialize`, which is bounded — that bound is the whole point
// of the type, and the error it raises names the two ways out.

import Foundation

/// A body that has not been read into memory: live from a connection
/// (`RequestBodyValue`) or anchored to a file (`AnchoredBody`).
///
/// Every place that has to decide between moving bytes and reading them —
/// `Write`, `Return`, the executor's safety net — talks to this rather than to
/// the two concrete types, so a body behaves the same whether or not it has
/// crossed a lifetime boundary on the way.
public protocol UnreadBody: Sendable {
    /// `Content-Type`, for parsing on materialization.
    var contentType: String? { get }
    /// `METHOD /path`, for messages.
    var route: String { get }
    /// The bytes, in order.
    func chunkStream(consumer: String) throws -> AROStream<Data>
    /// The bytes as a value, bounded.
    func materializedValue(statement: String) async throws -> any Sendable
}

/// The body of a request that has not been read into memory.
public final class RequestBodyValue: UnreadBody, @unchecked Sendable, CustomStringConvertible, Equatable {

    /// The chunks as they arrive.
    private let source: RequestBodyStream

    /// `Content-Type`, so materializing can parse the body the same way the
    /// buffered path does.
    public let contentType: String?

    /// `METHOD /path`, for error messages that have to name the route whose
    /// limit was exceeded.
    public let route: String

    /// Materialization limit in bytes, or nil when the route declares none.
    public var limit: Int? { source.limit }

    /// `Content-Length`, when the client declared one.
    public var declaredLength: Int? { source.declaredLength }

    private let lock = NSLock()
    private var consumedBy: String?
    private var materialized: (any Sendable)?

    public init(source: RequestBodyStream, contentType: String?, route: String) {
        self.source = source
        self.contentType = contentType
        self.route = route
    }

    public var description: String {
        "<request: body> of \(route) (not read)"
    }

    /// Identity, not content: two bodies are the same body only if they are
    /// the same arrival. There is no content to compare without reading it,
    /// and reading it is the thing this type exists to make explicit.
    public static func == (lhs: RequestBodyValue, rhs: RequestBodyValue) -> Bool {
        lhs === rhs
    }

    // MARK: - Moving it

    /// Take the chunks. A body arrives once and is not retained, so the second
    /// caller gets an error naming the first — a diagnostic rather than an
    /// empty stream, which is what silent double consumption would look like.
    public func chunks(consumer: String) throws -> AROStream<Data> {
        try lock.withLock {
            if let first = consumedBy {
                throw RequestBodyError.alreadyConsumed(route: route, by: first, now: consumer)
            }
            consumedBy = consumer
            return source.chunks
        }
    }

    // MARK: - Reading it

    /// Read the whole body and parse it the way the buffered path would.
    ///
    /// Bounded by the route's limit: the bytes over it are never accumulated,
    /// and the error names the statement that asked, the size, and both fixes.
    public func materialize(statement: String) async throws -> any Sendable {
        if let cached = lock.withLock({ materialized }) { return cached }

        let ceiling = limit ?? RuntimeDefaults.maxMaterializedBody
        if let declared = declaredLength, declared > ceiling {
            throw RequestBodyError.tooLargeToRead(
                route: route, statement: statement, size: declared, limit: ceiling)
        }

        let stream = try chunks(consumer: statement)
        var accumulated = Data()
        for try await chunk in stream.stream {
            // Checked before appending, so the memory over the limit is never
            // allocated — the same rule the server applies on the wire.
            if accumulated.count + chunk.count > ceiling {
                throw RequestBodyError.tooLargeToRead(
                    route: route,
                    statement: statement,
                    size: accumulated.count + chunk.count,
                    limit: ceiling)
            }
            accumulated.append(chunk)
        }

        MetricsCollector.shared.recordBodyMaterialized(bytes: accumulated.count)
        let parsed = RequestBodyParser.parse(accumulated, contentType: contentType)
        lock.withLock { materialized = parsed }
        return parsed
    }
}

extension RequestBodyValue {
    public func chunkStream(consumer: String) throws -> AROStream<Data> {
        try chunks(consumer: consumer)
    }

    public func materializedValue(statement: String) async throws -> any Sendable {
        try await materialize(statement: statement)
    }
}

// MARK: - Errors

public enum RequestBodyError: Error, CustomStringConvertible, Sendable {
    /// A body read past the route's limit.
    case tooLargeToRead(route: String, statement: String, size: Int, limit: Int)
    /// A body consumed twice.
    case alreadyConsumed(route: String, by: String, now: String)

    public var description: String {
        switch self {
        case .tooLargeToRead(let route, let statement, let size, let limit):
            return "Cannot \(statement): reading the request body needs "
                + "\(ByteSize.describe(size)), above \(route)'s \(ByteSize.describe(limit)) limit. "
                + "Stream it (Write the <body> to the <file: …>), "
                + "or raise x-aro-max-body for \(route)."
        case .alreadyConsumed(let route, let by, let now):
            return "Cannot \(now): the request body of \(route) was already consumed by \(by). "
                + "A body arrives once and is not kept. Use the earlier result, "
                + "or raise x-aro-max-body to hold the body in memory."
        }
    }

    public var localizedDescription: String { description }
}

// MARK: - Parsing

/// Turns body bytes into an ARO value according to `Content-Type`.
///
/// Extracted so the buffered path and a materialized stream produce exactly
/// the same value — a body that arrives on a streaming route and then gets
/// read must not be shaped differently from the same body on a buffered one.
public enum RequestBodyParser {

    public static func parse(_ body: Data, contentType: String?) -> any Sendable {
        guard !body.isEmpty else { return "" }

        let baseContentType = contentType?
            .split(separator: ";").first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        switch baseContentType {
        case "application/x-www-form-urlencoded":
            var dictionary: [String: any Sendable] = [:]
            for (key, value) in SchemaBinding.parseFormURLEncoded(body) {
                dictionary[key] = SendableConverter.fromJSON(value)
            }
            return dictionary

        case "multipart/form-data":
            if let rawContentType = contentType,
               let boundary = SchemaBinding.extractBoundary(from: rawContentType) {
                var dictionary: [String: any Sendable] = [:]
                for (key, value) in SchemaBinding.parseMultipartFormData(body, boundary: boundary) {
                    dictionary[key] = SendableConverter.fromJSON(value)
                }
                return dictionary
            }
            return String(data: body, encoding: .utf8) ?? ""

        default:
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                var dictionary: [String: any Sendable] = [:]
                for (key, value) in json {
                    dictionary[key] = SendableConverter.fromJSON(value)
                }
                return dictionary
            }
            return String(data: body, encoding: .utf8) ?? ""
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
