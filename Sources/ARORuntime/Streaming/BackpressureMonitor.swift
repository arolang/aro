// ============================================================
// BackpressureMonitor.swift
// ARO Runtime — per-stream buffer occupancy (GitLab #444)
// ============================================================
//
// `BoundedChannel` is where a pipeline's backpressure physically
// happens: `send` suspends while the buffer is full, so a slow
// consumer stops its producer. That's the mechanism working
// correctly — and it is completely invisible. A pipeline that
// spends 90% of its time with a producer parked looks, from the
// outside, exactly like one that doesn't.
//
// This records what the channels are doing so a canvas can draw
// it: how full each buffer is, and how long producers have been
// parked on it. Bottlenecks then identify themselves — the wire
// that stays amber is the stage to fix.
//
// Cost when nobody is looking: one atomic-ish dictionary write per
// send/receive under a lock. Sampling is off until a client calls
// `enable()`, so `aro run` pays nothing.

import Foundation

/// A point-in-time reading for one bounded channel.
public struct BackpressureSample: Sendable, Hashable {
    /// Which stream this channel belongs to — the binding name the
    /// elements flow through, when the pipeline knows it.
    public let label: String
    /// Elements currently buffered.
    public let depth: Int
    /// Buffer capacity.
    public let capacity: Int
    /// How many times a producer had to park because the buffer
    /// was full. Zero means this stage never lagged.
    public let stallCount: Int
    /// Total seconds producers spent parked on this channel.
    public let stalledSeconds: Double

    public init(label: String, depth: Int, capacity: Int,
                stallCount: Int, stalledSeconds: Double) {
        self.label = label
        self.depth = depth
        self.capacity = capacity
        self.stallCount = stallCount
        self.stalledSeconds = stalledSeconds
    }

    /// 0…1 buffer occupancy. This is what a wire's thickness and
    /// tint are driven from.
    public var fill: Double {
        guard capacity > 0 else { return 0 }
        return min(1.0, Double(depth) / Double(capacity))
    }

    /// True when this stage is holding its producer back often
    /// enough to be worth showing. A buffer that is briefly full is
    /// normal; one that is full *and* has parked producers is the
    /// bottleneck.
    public var isBackpressured: Bool {
        fill >= 0.75 && stallCount > 0
    }
}

/// Process-wide registry of channel occupancy.
///
/// A final class behind a lock rather than an actor: `send` and
/// `next` are already on the hot path of every streamed element,
/// and an actor hop per element would cost more than the feature
/// is worth.
public final class BackpressureMonitor: @unchecked Sendable {
    public static let shared = BackpressureMonitor()

    private let lock = NSLock()
    private var enabled = false
    private var entries: [ObjectIdentifier: Entry] = [:]

    private struct Entry {
        var label: String
        var depth: Int
        var capacity: Int
        var stallCount: Int
        var stalledSeconds: Double
    }

    private init() {}

    /// Start recording. Off by default — a plain `aro run` should
    /// not pay for a UI feature nobody is watching.
    public func enable() {
        lock.lock()
        enabled = true
        lock.unlock()
    }

    public func disable() {
        lock.lock()
        enabled = false
        entries.removeAll()
        lock.unlock()
    }

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    /// Current readings, deepest first — the head of this list is
    /// the pipeline's tightest point.
    public func snapshot() -> [BackpressureSample] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values
            .map {
                BackpressureSample(
                    label: $0.label, depth: $0.depth, capacity: $0.capacity,
                    stallCount: $0.stallCount, stalledSeconds: $0.stalledSeconds)
            }
            .sorted {
                if $0.fill != $1.fill { return $0.fill > $1.fill }
                return $0.label < $1.label
            }
    }

    /// Drop every reading. Called when a run starts so the canvas
    /// doesn't show the previous run's bottleneck.
    public func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    // MARK: - Reporting hooks (called by BoundedChannel)

    func register(_ token: ObjectIdentifier, label: String, capacity: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        entries[token] = Entry(label: label, depth: 0, capacity: capacity,
                               stallCount: 0, stalledSeconds: 0)
    }

    func recordDepth(_ token: ObjectIdentifier, depth: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, var entry = entries[token] else { return }
        entry.depth = depth
        entries[token] = entry
    }

    func recordStall(_ token: ObjectIdentifier, seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, var entry = entries[token] else { return }
        entry.stallCount += 1
        entry.stalledSeconds += seconds
        entries[token] = entry
    }

    func unregister(_ token: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        // The reading is kept, not deleted: a finished stage's
        // stall total is exactly what a post-run review wants. Only
        // the live depth drops to zero.
        guard var entry = entries[token] else { return }
        entry.depth = 0
        entries[token] = entry
    }
}
