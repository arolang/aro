// ============================================================
// MetricsCollector.swift
// ARO Runtime - Feature Set Metrics Collection
// ============================================================

import Foundation

/// Metrics for a single feature set
public struct FeatureSetMetrics: Sendable, Equatable {
    /// Feature set name
    public let name: String

    /// Business activity (e.g., "User API")
    public let businessActivity: String

    /// Total number of executions
    public private(set) var executionCount: Int = 0

    /// Number of successful executions
    public private(set) var successCount: Int = 0

    /// Number of failed executions
    public private(set) var failureCount: Int = 0

    /// Total duration of all executions in milliseconds
    public private(set) var totalDurationMs: Double = 0

    /// Minimum execution duration in milliseconds
    public private(set) var minDurationMs: Double = .infinity

    /// Maximum execution duration in milliseconds
    public private(set) var maxDurationMs: Double = 0

    /// Average execution duration in milliseconds
    public var averageDurationMs: Double {
        executionCount > 0 ? totalDurationMs / Double(executionCount) : 0
    }

    /// Success rate as a percentage (0-100)
    public var successRate: Double {
        executionCount > 0 ? Double(successCount) / Double(executionCount) * 100 : 0
    }

    public init(name: String, businessActivity: String) {
        self.name = name
        self.businessActivity = businessActivity
    }

    /// Record an execution
    mutating func recordExecution(success: Bool, durationMs: Double) {
        executionCount += 1
        if success {
            successCount += 1
        } else {
            failureCount += 1
        }
        totalDurationMs += durationMs
        minDurationMs = min(minDurationMs, durationMs)
        maxDurationMs = max(maxDurationMs, durationMs)
    }
}

/// Snapshot of all metrics at a point in time
public struct MetricsSnapshot: Sendable {
    /// Metrics for all feature sets
    public let featureSets: [FeatureSetMetrics]

    /// When this snapshot was taken
    public let collectedAt: Date

    /// When the application started
    public let applicationStartTime: Date

    /// Total executions across all feature sets
    public var totalExecutions: Int {
        featureSets.reduce(0) { $0 + $1.executionCount }
    }

    /// Total successes across all feature sets
    public var totalSuccesses: Int {
        featureSets.reduce(0) { $0 + $1.successCount }
    }

    /// Total failures across all feature sets
    public var totalFailures: Int {
        featureSets.reduce(0) { $0 + $1.failureCount }
    }

    /// Application uptime in seconds
    public var uptimeSeconds: Double {
        collectedAt.timeIntervalSince(applicationStartTime)
    }

    /// Overall average duration in milliseconds
    public var averageDurationMs: Double {
        let totalDuration = featureSets.reduce(0.0) { $0 + $1.totalDurationMs }
        let totalCount = totalExecutions
        return totalCount > 0 ? totalDuration / Double(totalCount) : 0
    }

    /// Overall maximum duration in milliseconds
    public var maxDurationMs: Double {
        featureSets.map(\.maxDurationMs).max() ?? 0
    }

    public init(
        featureSets: [FeatureSetMetrics],
        collectedAt: Date,
        applicationStartTime: Date
    ) {
        self.featureSets = featureSets
        self.collectedAt = collectedAt
        self.applicationStartTime = applicationStartTime
    }
}

/// Thread-safe metrics collector that subscribes to feature set events
///
/// Usage:
/// ```swift
/// // Start collecting (usually called from Runtime.init)
/// MetricsCollector.shared.start(eventBus: eventBus)
///
/// // Get current metrics snapshot
/// let snapshot = MetricsCollector.shared.snapshot()
/// ```
public final class MetricsCollector: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = MetricsCollector()

    /// Lock for thread-safe access
    private let lock = NSLock()

    /// Per-feature-set metrics storage
    private var metrics: [String: FeatureSetMetrics] = [:]

    /// When the collector started (application start time)
    private let startTime: Date

    /// Whether the collector has been started
    private var isStarted = false

    /// Subscription ID for cleanup
    private var subscriptionId: UUID?

    public init() {
        self.startTime = Date()
    }

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Start collecting metrics by subscribing to feature set completion events
    /// - Parameter eventBus: The event bus to subscribe to
    public func start(eventBus: EventBus) {
        let shouldStart = withLock {
            if isStarted { return false }
            isStarted = true
            return true
        }

        guard shouldStart else { return }

        subscriptionId = eventBus.subscribe(to: FeatureSetCompletedEvent.self) { [weak self] event in
            self?.recordExecution(event)
        }
    }

    /// Record a feature set execution from a completion event
    private func recordExecution(_ event: FeatureSetCompletedEvent) {
        withLock {
            let key = event.featureSetName

            if metrics[key] == nil {
                metrics[key] = FeatureSetMetrics(
                    name: event.featureSetName,
                    businessActivity: event.businessActivity
                )
            }

            metrics[key]?.recordExecution(
                success: event.success,
                durationMs: event.durationMs
            )
        }
    }

    /// Get a snapshot of current metrics
    /// - Returns: Immutable snapshot of all collected metrics
    public func snapshot() -> MetricsSnapshot {
        withLock {
            // Sort by name for consistent ordering
            let sortedMetrics = metrics.values.sorted { $0.name < $1.name }

            return MetricsSnapshot(
                featureSets: sortedMetrics,
                collectedAt: Date(),
                applicationStartTime: startTime
            )
        }
    }

    /// Reset all metrics (primarily for testing)
    public func reset() {
        withLock {
            metrics.removeAll()
        }
    }

    /// Get the number of tracked feature sets
    public var featureSetCount: Int {
        withLock { metrics.count }
    }
}
