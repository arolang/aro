// StreamingValue.swift
// ARO Streaming Execution Engine
//
// Protocol and wrapper for values that can be either lazy (streamed) or eager (materialized).

import Foundation

/// Protocol for values that may be lazy (streamed) or eager (materialized).
///
/// This abstraction allows ARO actions to work uniformly with both streaming
/// and materialized data, enabling transparent lazy evaluation.
public protocol StreamingValue: Sendable {
    associatedtype Element: Sendable

    /// Whether this value is already materialized in memory
    var isMaterialized: Bool { get }

    /// Materialize the value into an array (may trigger computation)
    func materialize() async throws -> [Element]

    /// Get as an async stream (zero-cost if already lazy)
    func asStream() -> AROStream<Element>

    /// Estimated element count (nil if unknown)
    var estimatedCount: Int? { get }
}

/// A value that can be either an eager array or a lazy stream.
///
/// This is the primary wrapper used in ARO's RuntimeContext for
/// transparently supporting both streaming and materialized data.
public enum AROValue<T: Sendable>: Sendable, StreamingValue {
    /// An eager, already-materialized array
    case eager([T])

    /// A lazy stream that hasn't been evaluated yet
    case lazy(AROStream<T>)

    /// A teed stream for multi-consumer scenarios
    case teed(StreamTee<T>)

    public typealias Element = T

    /// Whether this value is already in memory
    public var isMaterialized: Bool {
        if case .eager = self { return true }
        return false
    }

    /// Materialize the value into an array
    ///
    /// For eager values, this is O(1).
    /// For lazy values, this consumes the entire stream.
    public func materialize() async throws -> [T] {
        switch self {
        case .eager(let array):
            return array
        case .lazy(let stream):
            return try await stream.collect()
        case .teed(let tee):
            let consumer = await tee.createConsumer()
            return try await consumer.collect()
        }
    }

    /// Get as a stream
    ///
    /// For eager values, wraps the array as a stream.
    /// For lazy values, returns the underlying stream.
    public func asStream() -> AROStream<T> {
        switch self {
        case .eager(let array):
            return AROStream.from(array)
        case .lazy(let stream):
            return stream
        case .teed(let tee):
            // Create a new consumer for each call
            // This allows multiple iterations
            return AROStream {
                AsyncThrowingStream { continuation in
                    Task {
                        let consumer = await tee.createConsumer()
                        do {
                            for try await element in consumer.stream {
                                continuation.yield(element)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }
        }
    }

    /// Estimated count (only known for eager values)
    public var estimatedCount: Int? {
        switch self {
        case .eager(let array):
            return array.count
        case .lazy, .teed:
            return nil
        }
    }

    /// Create an eager value from an array
    public static func fromArray(_ array: [T]) -> AROValue<T> {
        .eager(array)
    }

    /// Create a lazy value from a stream
    public static func fromStream(_ stream: AROStream<T>) -> AROValue<T> {
        .lazy(stream)
    }

    /// Convert to teed value for multi-consumer access
    public func teed(bufferCapacity: Int = RingBuffer<T>.defaultCapacity) -> AROValue<T> {
        switch self {
        case .eager:
            // Eager values don't need teeing - they can be read multiple times
            return self
        case .lazy(let stream):
            return .teed(StreamTee(source: stream, bufferCapacity: bufferCapacity))
        case .teed:
            // Already teed
            return self
        }
    }
}

// MARK: - Type Erased Streaming Value

/// Type-erased wrapper for StreamingValue
///
/// Used when the element type is not known at compile time (common in ARO's dynamic context).
public struct AnyStreamingValue: Sendable {
    private let _isMaterialized: @Sendable () -> Bool
    private let _materialize: @Sendable () async throws -> [any Sendable]
    private let _asStream: @Sendable () -> AROStream<any Sendable>
    private let _estimatedCount: @Sendable () -> Int?

    public var isMaterialized: Bool { _isMaterialized() }
    public var estimatedCount: Int? { _estimatedCount() }

    public func materialize() async throws -> [any Sendable] {
        try await _materialize()
    }

    public func asStream() -> AROStream<any Sendable> {
        _asStream()
    }

    public init<T: Sendable>(_ value: AROValue<T>) {
        self._isMaterialized = { value.isMaterialized }
        self._estimatedCount = { value.estimatedCount }
        self._materialize = {
            try await value.materialize()
        }
        self._asStream = {
            value.asStream().map { $0 as any Sendable }
        }
    }
}

// MARK: - Convenience Extensions

extension AROValue where T == [String: any Sendable] {
    /// Filter rows matching a predicate (preserves laziness)
    public func filter(_ predicate: @escaping @Sendable (T) -> Bool) -> AROValue<T> {
        switch self {
        case .eager(let array):
            return .eager(array.filter(predicate))
        case .lazy(let stream):
            return .lazy(stream.filter(predicate))
        case .teed(let tee):
            return .lazy(AROStream {
                AsyncThrowingStream { continuation in
                    Task {
                        let consumer = await tee.createConsumer()
                        do {
                            for try await element in consumer.stream {
                                if predicate(element) {
                                    continuation.yield(element)
                                }
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            })
        }
    }

    /// Transform rows (preserves laziness)
    public func map<U: Sendable>(_ transform: @escaping @Sendable (T) -> U) -> AROValue<U> {
        switch self {
        case .eager(let array):
            return .eager(array.map(transform))
        case .lazy(let stream):
            return .lazy(stream.map(transform))
        case .teed(let tee):
            return .lazy(AROStream {
                AsyncThrowingStream { continuation in
                    Task {
                        let consumer = await tee.createConsumer()
                        do {
                            for try await element in consumer.stream {
                                continuation.yield(transform(element))
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            })
        }
    }
}

// MARK: - Streaming Helpers

/// Determines whether a value should be streamed based on heuristics
public struct StreamingHeuristics: Sendable {
    /// File size threshold for streaming (default: 10MB)
    public static let fileSizeThreshold: Int = 10_000_000

    /// Element count threshold for streaming (default: 10000)
    public static let elementCountThreshold: Int = 10_000

    /// Check if a file should be streamed based on size
    public static func shouldStream(fileSize: Int) -> Bool {
        fileSize >= fileSizeThreshold
    }

    /// Check if a collection should be streamed based on count
    public static func shouldStream(elementCount: Int) -> Bool {
        elementCount >= elementCountThreshold
    }
}
