// StreamPrefetch.swift
// ARO Streaming Execution Engine — bounded producer/consumer overlap
//
// ARO-0088 §6: a stream's producer runs ahead of its consumer by a bounded
// number of elements, so the next batch is being prepared while the current one
// is processed, without the producer running away with memory.

import Foundation

/// A bounded hand-off channel between one producer and one consumer.
///
/// `AsyncThrowingStream`'s default buffering policy is `.unbounded`, and the
/// alternatives (`bufferingOldest` / `bufferingNewest`) *drop* elements when
/// full — neither is backpressure. A pipeline stage built on the default keeps
/// pulling as fast as the source allows and buffers the difference, which is
/// exactly the unbounded growth streaming exists to avoid.
///
/// This channel makes the producer wait instead: `send` suspends while the
/// buffer is full and resumes when the consumer takes an element. Capacity is
/// the number of elements the producer may run ahead by.
/// Allocation whose address identifies one channel to the
/// backpressure monitor. An actor can't take `ObjectIdentifier` of
/// `self` before `init` completes, so identity comes from this.
private final class BoundedChannelToken: Sendable {}

actor BoundedChannel<Element: Sendable> {
    private var buffer: [Element] = []
    private var finished = false
    private var failure: Error?

    private var consumers: [CheckedContinuation<Element?, Error>] = []
    private var producers: [CheckedContinuation<Void, Never>] = []

    private let capacity: Int
    /// Identity under which this channel reports occupancy
    /// (GitLab #444). Backpressure happening here is the mechanism
    /// working correctly, and completely invisible without this.
    /// Held for the channel's lifetime — the monitor keys on this
    /// object's address, so letting it deallocate would let a later
    /// allocation reuse the address and collide with this entry.
    private nonisolated let monitorAnchor = BoundedChannelToken()
    private nonisolated var monitorToken: ObjectIdentifier {
        ObjectIdentifier(monitorAnchor)
    }
    private let monitorLabel: String

    init(capacity: Int, label: String = "stream") {
        self.capacity = max(1, capacity)
        self.monitorLabel = label
        BackpressureMonitor.shared.register(
            ObjectIdentifier(monitorAnchor), label: label, capacity: self.capacity)
    }

    deinit {
        BackpressureMonitor.shared.unregister(monitorToken)
    }

    /// Offer an element, suspending while the buffer is full.
    func send(_ element: Element) async {
        // Hand straight to a waiting consumer, but ONLY when nothing is queued.
        // Skipping that check lets a fresh element overtake buffered ones and
        // the stream delivers out of order — caught by the ordering test, which
        // saw 1,2,3,4,6,5,…
        if buffer.isEmpty, let consumer = consumers.first {
            consumers.removeFirst()
            consumer.resume(returning: element)
            return
        }
        while buffer.count >= capacity && !finished {
            // This suspension *is* the backpressure. Time it, so a
            // canvas can show which stage is holding its producer
            // back rather than leaving the stall invisible (#444).
            let parkedAt = DispatchTime.now().uptimeNanoseconds
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                producers.append(continuation)
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- parkedAt
            BackpressureMonitor.shared.recordStall(
                monitorToken, seconds: Double(elapsed) / 1_000_000_000)
        }
        guard !finished else { return }
        buffer.append(element)
        BackpressureMonitor.shared.recordDepth(monitorToken, depth: buffer.count)

        // Wake a parked consumer with the *head* of the buffer, not the element
        // just appended — order matters, and a consumer can be parked while the
        // buffer is non-empty. Omitting this loses every element still buffered
        // when the producer finishes: StreamExample dropped exactly its last
        // `capacity` lines.
        if let consumer = consumers.first, !buffer.isEmpty {
            consumers.removeFirst()
            consumer.resume(returning: buffer.removeFirst())
        }
    }

    /// Signal end of stream, optionally with a failure.
    func finish(throwing error: Error? = nil) {
        guard !finished else { return }
        finished = true
        failure = error
        let waiting = consumers
        consumers.removeAll()
        for consumer in waiting {
            // Hand over anything still buffered before reporting the end —
            // finishing is not a reason to discard elements already produced.
            if !buffer.isEmpty, error == nil {
                consumer.resume(returning: buffer.removeFirst())
            } else if let error {
                consumer.resume(throwing: error)
            } else {
                consumer.resume(returning: nil)
            }
        }
        let blocked = producers
        producers.removeAll()
        for producer in blocked { producer.resume() }
    }

    /// Take the next element, or nil once the producer has finished.
    func next() async throws -> Element? {
        if !buffer.isEmpty {
            let element = buffer.removeFirst()
            BackpressureMonitor.shared.recordDepth(monitorToken, depth: buffer.count)
            if let producer = producers.first {
                producers.removeFirst()
                producer.resume()
            }
            return element
        }
        if finished {
            if let failure { throw failure }
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            consumers.append(continuation)
        }
    }
}

public extension AROStream {

    /// Run this stream's producer up to `capacity` elements ahead of its consumer.
    ///
    /// Without this, a pipeline alternates: the consumer processes an element
    /// while the source sits idle, then the source produces while the consumer
    /// sits idle. With it, the two overlap — the next element (or micro-batch) is
    /// already being read or parsed while the current one is still being
    /// processed — and `capacity` bounds how far ahead that can get, so memory
    /// stays O(capacity) rather than O(input).
    /// `label` names the channel in backpressure readings (#444) —
    /// pass the binding the elements flow through so a canvas wire
    /// can be matched to its buffer.
    func prefetch(_ capacity: Int = RuntimeDefaults.streamPrefetchCapacity,
                  label: String = "stream") -> AROStream<Element> {
        let upstream = self
        return AROStream {
            AsyncThrowingStream { continuation in
                let channel = BoundedChannel<Element>(capacity: capacity, label: label)

                // Producer: pull from upstream into the bounded channel.
                let producer = Task {
                    do {
                        for try await element in upstream.stream {
                            await channel.send(element)
                        }
                        await channel.finish()
                    } catch {
                        await channel.finish(throwing: error)
                    }
                }

                // Consumer: drain the channel into the downstream continuation.
                let consumer = Task {
                    do {
                        while let element = try await channel.next() {
                            continuation.yield(element)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { _ in
                    producer.cancel()
                    consumer.cancel()
                }
            }
        }
    }
}
