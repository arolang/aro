// AROStream.swift
// ARO Streaming Execution Engine
//
// A lazy sequence that defers computation until iteration.
// Inspired by Apache Spark's RDD but optimized for single-machine execution.

import Foundation

/// A lazy, streamable sequence that defers computation until consumed.
///
/// `AROStream` wraps Swift's `AsyncThrowingStream` to provide:
/// - Lazy evaluation (nothing executes until drained)
/// - Chainable transformations (filter, map, flatMap)
/// - Memory efficiency (O(1) for streaming operations)
/// - Backpressure support (consumers control the pace)
///
/// Example:
/// ```swift
/// let stream = AROStream.fromFile("huge.csv")
///     .filter { $0["status"] == "active" }
///     .map { $0["name"] as? String ?? "" }
///
/// // Nothing has executed yet - pipeline is lazy
///
/// try await stream.forEach { print($0) }  // NOW it executes
/// ```
public struct AROStream<Element: Sendable>: Sendable {

    /// The underlying producer function that creates the async stream
    private let _producer: @Sendable () -> AsyncThrowingStream<Element, Error>

    /// Create a stream from a producer function
    public init(_ producer: @escaping @Sendable () -> AsyncThrowingStream<Element, Error>) {
        self._producer = producer
    }

    /// Get the underlying async stream (triggers lazy evaluation when iterated)
    public func makeAsyncIterator() -> AsyncThrowingStream<Element, Error>.AsyncIterator {
        _producer().makeAsyncIterator()
    }

    /// Access the raw stream for iteration
    public var stream: AsyncThrowingStream<Element, Error> {
        _producer()
    }

    // MARK: - Factory Methods

    /// Create a stream from an array (wraps eager data as lazy)
    public static func from(_ array: [Element]) -> AROStream<Element> {
        AROStream {
            AsyncThrowingStream { continuation in
                for element in array {
                    continuation.yield(element)
                }
                continuation.finish()
            }
        }
    }

    /// Create an empty stream
    public static var empty: AROStream<Element> {
        AROStream {
            AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
    }

    /// Create a stream from a single element
    public static func just(_ element: Element) -> AROStream<Element> {
        AROStream {
            AsyncThrowingStream { continuation in
                continuation.yield(element)
                continuation.finish()
            }
        }
    }

    /// Create a stream from an async sequence
    public static func from<S: AsyncSequence & Sendable>(_ sequence: S) -> AROStream<Element> where S.Element == Element, S.AsyncIterator: Sendable {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await element in sequence {
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

    // MARK: - Transformations (Lazy - Build Pipeline)

    /// Filter elements that match a predicate
    ///
    /// This is a **narrow transformation** - each element is processed independently.
    /// Memory: O(1) - no intermediate storage required.
    public func filter(_ predicate: @escaping @Sendable (Element) -> Bool) -> AROStream<Element> {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await element in self.stream {
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
        }
    }

    /// Filter elements using an async predicate
    public func filter(_ predicate: @escaping @Sendable (Element) async throws -> Bool) -> AROStream<Element> {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await element in self.stream {
                            if try await predicate(element) {
                                continuation.yield(element)
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Transform each element
    ///
    /// This is a **narrow transformation** - each element is processed independently.
    /// Memory: O(1) - no intermediate storage required.
    public func map<T: Sendable>(_ transform: @escaping @Sendable (Element) -> T) -> AROStream<T> {
        AROStream<T> {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await element in self.stream {
                            continuation.yield(transform(element))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Transform each element using an async function
    public func map<T: Sendable>(_ transform: @escaping @Sendable (Element) async throws -> T) -> AROStream<T> {
        AROStream<T> {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await element in self.stream {
                            let transformed = try await transform(element)
                            continuation.yield(transformed)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Transform each element into multiple elements
    public func flatMap<T: Sendable>(_ transform: @escaping @Sendable (Element) -> [T]) -> AROStream<T> {
        AROStream<T> {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await element in self.stream {
                            for transformed in transform(element) {
                                continuation.yield(transformed)
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Compact map - transform and filter out nils
    public func compactMap<T: Sendable>(_ transform: @escaping @Sendable (Element) -> T?) -> AROStream<T> {
        AROStream<T> {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await element in self.stream {
                            if let transformed = transform(element) {
                                continuation.yield(transformed)
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Take first n elements
    public func take(_ count: Int) -> AROStream<Element> {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        var taken = 0
                        for try await element in self.stream {
                            if taken >= count {
                                break
                            }
                            continuation.yield(element)
                            taken += 1
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    /// Skip first n elements
    public func drop(_ count: Int) -> AROStream<Element> {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        var dropped = 0
                        for try await element in self.stream {
                            if dropped < count {
                                dropped += 1
                                continue
                            }
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

    /// Take elements while predicate is true
    public func takeWhile(_ predicate: @escaping @Sendable (Element) -> Bool) -> AROStream<Element> {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await element in self.stream {
                            if !predicate(element) {
                                break
                            }
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

    /// Drop elements while predicate is true
    public func dropWhile(_ predicate: @escaping @Sendable (Element) -> Bool) -> AROStream<Element> {
        AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        var dropping = true
                        for try await element in self.stream {
                            if dropping && predicate(element) {
                                continue
                            }
                            dropping = false
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

    // MARK: - Actions (Eager - Trigger Execution)

    /// Collect all elements into an array
    ///
    /// **WARNING:** This materializes the entire stream into memory.
    /// Use only when you need all elements, or when the stream is bounded.
    public func collect() async throws -> [Element] {
        var results: [Element] = []
        for try await element in stream {
            results.append(element)
        }
        return results
    }

    /// Reduce stream to a single value
    ///
    /// Memory: O(1) - only accumulator is stored.
    public func reduce<T: Sendable>(_ initial: T, _ combine: @escaping @Sendable (T, Element) -> T) async throws -> T {
        var accumulator = initial
        for try await element in stream {
            accumulator = combine(accumulator, element)
        }
        return accumulator
    }

    /// Reduce stream using an async combiner
    public func reduce<T: Sendable>(_ initial: T, _ combine: @escaping @Sendable (T, Element) async throws -> T) async throws -> T {
        var accumulator = initial
        for try await element in stream {
            accumulator = try await combine(accumulator, element)
        }
        return accumulator
    }

    /// Process each element with side effects (logging, sending, etc.)
    ///
    /// This is the primary way to "drain" a stream.
    public func forEach(_ body: @escaping @Sendable (Element) async throws -> Void) async throws {
        for try await element in stream {
            try await body(element)
        }
    }

    /// Count elements in the stream
    ///
    /// Memory: O(1)
    public func count() async throws -> Int {
        var count = 0
        for try await _ in stream {
            count += 1
        }
        return count
    }

    /// Get the first element (if any)
    public func first() async throws -> Element? {
        for try await element in stream {
            return element
        }
        return nil
    }

    /// Get the first element matching a predicate
    public func first(where predicate: @escaping @Sendable (Element) -> Bool) async throws -> Element? {
        for try await element in stream {
            if predicate(element) {
                return element
            }
        }
        return nil
    }

    /// Check if any element matches the predicate
    public func contains(where predicate: @escaping @Sendable (Element) -> Bool) async throws -> Bool {
        for try await element in stream {
            if predicate(element) {
                return true
            }
        }
        return false
    }

    /// Check if all elements match the predicate
    public func allSatisfy(_ predicate: @escaping @Sendable (Element) -> Bool) async throws -> Bool {
        for try await element in stream {
            if !predicate(element) {
                return false
            }
        }
        return true
    }
}

// MARK: - Numeric Reductions

extension AROStream where Element: Numeric {
    /// Sum all elements
    public func sum() async throws -> Element {
        try await reduce(.zero) { $0 + $1 }
    }
}

extension AROStream where Element: Comparable {
    /// Find minimum element
    public func min() async throws -> Element? {
        var result: Element?
        for try await element in stream {
            if let current = result {
                result = Swift.min(current, element)
            } else {
                result = element
            }
        }
        return result
    }

    /// Find maximum element
    public func max() async throws -> Element? {
        var result: Element?
        for try await element in stream {
            if let current = result {
                result = Swift.max(current, element)
            } else {
                result = element
            }
        }
        return result
    }
}

// MARK: - Dictionary Streams (Common in ARO)

extension AROStream where Element == [String: any Sendable] {
    /// Filter rows where a field equals a value
    public func whereField(_ field: String, equals value: any Sendable) -> AROStream<Element> {
        filter { row in
            guard let fieldValue = row[field] else { return false }
            return areEqual(fieldValue, value)
        }
    }

    /// Filter rows where a field matches a predicate
    public func whereField<T>(_ field: String, matches predicate: @escaping @Sendable (T) -> Bool) -> AROStream<Element> {
        filter { row in
            guard let fieldValue = row[field] as? T else { return false }
            return predicate(fieldValue)
        }
    }

    /// Project specific fields
    public func project(_ fields: [String]) -> AROStream<Element> {
        map { row in
            var projected: [String: any Sendable] = [:]
            for field in fields {
                if let value = row[field] {
                    projected[field] = value
                }
            }
            return projected
        }
    }

    /// Extract a single field as a stream
    public func field<T: Sendable>(_ name: String, as type: T.Type = T.self) -> AROStream<T> {
        compactMap { row in
            row[name] as? T
        }
    }
}

// MARK: - Helpers

/// Compare two Sendable values for equality
private func areEqual(_ lhs: any Sendable, _ rhs: any Sendable) -> Bool {
    switch (lhs, rhs) {
    case let (l as String, r as String): return l == r
    case let (l as Int, r as Int): return l == r
    case let (l as Double, r as Double): return l == r
    case let (l as Bool, r as Bool): return l == r
    default: return false
    }
}
