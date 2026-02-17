// StreamTee.swift
// ARO Streaming Execution Engine
//
// Splits a single stream into multiple consumers using a bounded buffer.

import Foundation

/// Splits a single stream into multiple independent consumers.
///
/// When a variable is used by multiple consumers in ARO:
/// ```aro
/// <Filter> the <active> from <orders> where status = "active".
/// <Reduce> the <total> from <active> with sum(amount).  // consumer 1
/// <Log> <active> to the <Console>.                       // consumer 2
/// ```
///
/// The StreamTee allows both consumers to read from the same stream independently,
/// using a bounded ring buffer to minimize memory usage.
///
/// Memory: O(buffer_size) - bounded regardless of stream length.
/// The buffer only holds elements between the fastest and slowest consumer.
public actor StreamTee<Element: Sendable> {

    /// The source stream (consumed once)
    private let source: AROStream<Element>

    /// Shared buffer for multi-consumer access
    private let buffer: RingBuffer<Element>

    /// Consumer read positions (consumer ID → logical index)
    private var consumers: [Int: Int] = [:]

    /// Next consumer ID to assign
    private var nextConsumerId: Int = 0

    /// Whether the source stream has been fully consumed
    private var sourceExhausted: Bool = false

    /// Error from source stream (if any)
    private var sourceError: Error?

    /// Task that reads from source into buffer
    private var readerTask: Task<Void, Never>?

    /// Continuations waiting for more data
    private var waiters: [Int: CheckedContinuation<Element?, Error>] = [:]

    /// Create a StreamTee from a source stream
    ///
    /// - Parameters:
    ///   - source: The source stream to tee
    ///   - bufferCapacity: Maximum elements to buffer (default: 1024)
    public init(source: AROStream<Element>, bufferCapacity: Int = RingBuffer<Element>.defaultCapacity) {
        self.source = source
        self.buffer = RingBuffer(capacity: bufferCapacity)
    }

    /// Create a new consumer stream
    ///
    /// Each call creates an independent consumer that can read the entire
    /// stream from the beginning (or from wherever it was when created).
    public func createConsumer() async -> AROStream<Element> {
        let consumerId = nextConsumerId
        nextConsumerId += 1
        consumers[consumerId] = await buffer.firstIndex

        // Start the reader task if this is the first consumer
        if readerTask == nil {
            startReading()
        }

        // Capture self strongly - StreamTee must outlive its consumers
        let tee = self
        return AROStream {
            AsyncThrowingStream { continuation in
                Task {
                    do {
                        while true {
                            guard let element = try await tee.next(for: consumerId) else {
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

    /// Get the next element for a specific consumer
    private func next(for consumerId: Int) async throws -> Element? {
        guard let position = consumers[consumerId] else {
            throw StreamTeeError.invalidConsumer(consumerId)
        }

        // Check if element is already buffered
        if let element = await buffer.element(at: position) {
            consumers[consumerId] = position + 1
            await trimBufferIfNeeded()
            return element
        }

        // Check if element was evicted (consumer too slow)
        if await buffer.wasEvicted(at: position) {
            throw StreamTeeError.consumerTooSlow(consumerId, position)
        }

        // Check if source is exhausted
        if sourceExhausted {
            if let error = sourceError {
                throw error
            }
            return nil
        }

        // Wait for more data
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.registerWaiter(consumerId, continuation: continuation)
            }
        }
    }

    /// Register a continuation waiting for data
    private func registerWaiter(_ consumerId: Int, continuation: CheckedContinuation<Element?, Error>) {
        waiters[consumerId] = continuation
    }

    /// Start reading from the source stream
    private func startReading() {
        readerTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                for try await element in self.source.stream {
                    await self.buffer.append(element)
                    await self.notifyWaiters()
                }
                await self.markSourceExhausted(error: nil)
            } catch {
                await self.markSourceExhausted(error: error)
            }
        }
    }

    /// Mark the source as exhausted
    private func markSourceExhausted(error: Error?) {
        sourceExhausted = true
        sourceError = error

        // Wake up all waiters
        for (_, continuation) in waiters {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: nil)
            }
        }
        waiters.removeAll()
    }

    /// Notify waiters that new data is available
    private func notifyWaiters() async {
        var toNotify: [(Int, CheckedContinuation<Element?, Error>)] = []

        for (consumerId, continuation) in waiters {
            guard let position = consumers[consumerId] else { continue }
            if await buffer.isAvailable(at: position) {
                toNotify.append((consumerId, continuation))
            }
        }

        for (consumerId, continuation) in toNotify {
            waiters.removeValue(forKey: consumerId)

            if let position = consumers[consumerId],
               let element = await buffer.element(at: position) {
                consumers[consumerId] = position + 1
                continuation.resume(returning: element)
            } else if sourceExhausted {
                if let error = sourceError {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Trim buffer elements that all consumers have passed
    private func trimBufferIfNeeded() async {
        guard !consumers.isEmpty else { return }

        let minPosition = consumers.values.min() ?? 0
        await buffer.trimTo(minimumIndex: minPosition)
    }

    /// Get the number of active consumers
    public var consumerCount: Int {
        consumers.count
    }

    /// Get the current buffer size
    public var bufferedCount: Int {
        get async { await buffer.count }
    }

    /// Remove a consumer (when it's done)
    public func removeConsumer(_ consumerId: Int) {
        consumers.removeValue(forKey: consumerId)
        waiters.removeValue(forKey: consumerId)
    }
}

// MARK: - Errors

/// Errors that can occur during stream teeing
public enum StreamTeeError: Error, LocalizedError {
    /// Consumer ID is not valid
    case invalidConsumer(Int)

    /// Consumer fell too far behind and data was evicted
    case consumerTooSlow(Int, Int)

    public var errorDescription: String? {
        switch self {
        case .invalidConsumer(let id):
            return "Invalid consumer ID: \(id)"
        case .consumerTooSlow(let id, let position):
            return "Consumer \(id) too slow: data at position \(position) was evicted"
        }
    }
}

// MARK: - Convenience Factory

extension AROStream {
    /// Create a tee from this stream that supports multiple consumers
    ///
    /// Example:
    /// ```swift
    /// let streams = await stream.tee(consumers: 2)
    /// let consumer1 = streams[0]  // First consumer stream
    /// let consumer2 = streams[1]  // Second consumer stream
    /// ```
    public func tee(consumers count: Int = 2, bufferCapacity: Int = RingBuffer<Element>.defaultCapacity) async -> [AROStream<Element>] {
        let tee = StreamTee(source: self, bufferCapacity: bufferCapacity)
        var streams: [AROStream<Element>] = []
        for _ in 0..<count {
            let consumer = await tee.createConsumer()
            streams.append(consumer)
        }
        return streams
    }
}
