// ============================================================
// MetricsCollector.swift
// ARO Runtime - Feature Set Metrics Collection
// ============================================================

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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

/// System-level process metrics from Swift System Metrics
public struct ProcessMetrics: Sendable {
    /// CPU user time in seconds
    public let cpuUserTime: Double

    /// CPU system time in seconds
    public let cpuSystemTime: Double

    /// Total CPU time (user + system) in seconds
    public var cpuTotalTime: Double {
        cpuUserTime + cpuSystemTime
    }

    /// Virtual memory size in bytes
    public let virtualMemoryBytes: Int

    /// Resident memory size in bytes
    public let residentMemoryBytes: Int

    /// Virtual memory in megabytes
    public var virtualMemoryMB: Double {
        Double(virtualMemoryBytes) / 1_048_576.0
    }

    /// Resident memory in megabytes
    public var residentMemoryMB: Double {
        Double(residentMemoryBytes) / 1_048_576.0
    }

    /// Number of open file descriptors
    public let openFileDescriptors: Int

    /// Maximum available file descriptors
    public let maxFileDescriptors: Int

    /// Process start time (Unix timestamp)
    public let processStartTime: Double

    /// Process start time as Date
    public var startDate: Date {
        Date(timeIntervalSince1970: processStartTime)
    }

    public init(
        cpuUserTime: Double,
        cpuSystemTime: Double,
        virtualMemoryBytes: Int,
        residentMemoryBytes: Int,
        openFileDescriptors: Int,
        maxFileDescriptors: Int,
        processStartTime: Double
    ) {
        self.cpuUserTime = cpuUserTime
        self.cpuSystemTime = cpuSystemTime
        self.virtualMemoryBytes = virtualMemoryBytes
        self.residentMemoryBytes = residentMemoryBytes
        self.openFileDescriptors = openFileDescriptors
        self.maxFileDescriptors = maxFileDescriptors
        self.processStartTime = processStartTime
    }

    /// Collect current process metrics using system APIs
    public static func collect() -> ProcessMetrics {
        #if os(macOS)
        return collectDarwin()
        #elseif os(Linux)
        return collectLinux()
        #else
        return ProcessMetrics(
            cpuUserTime: 0,
            cpuSystemTime: 0,
            virtualMemoryBytes: 0,
            residentMemoryBytes: 0,
            openFileDescriptors: 0,
            maxFileDescriptors: 0,
            processStartTime: Date().timeIntervalSince1970
        )
        #endif
    }

    #if os(macOS)
    private static func collectDarwin() -> ProcessMetrics {
        // Get CPU time using getrusage
        var rusage = rusage()
        getrusage(RUSAGE_SELF, &rusage)
        let cpuUserTime = Double(rusage.ru_utime.tv_sec) + Double(rusage.ru_utime.tv_usec) / 1_000_000.0
        let cpuSystemTime = Double(rusage.ru_stime.tv_sec) + Double(rusage.ru_stime.tv_usec) / 1_000_000.0

        // Get memory info using task_info
        var taskInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &taskInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }

        let virtualMemoryBytes: Int
        let residentMemoryBytes: Int
        if result == KERN_SUCCESS {
            virtualMemoryBytes = Int(taskInfo.virtual_size)
            residentMemoryBytes = Int(taskInfo.resident_size)
        } else {
            virtualMemoryBytes = 0
            residentMemoryBytes = 0
        }

        // Get file descriptor counts
        let openFds = getOpenFileDescriptorCount()
        var rlimit = rlimit()
        getrlimit(RLIMIT_NOFILE, &rlimit)
        let maxFds = Int(rlimit.rlim_cur)

        // Get process start time
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &kinfo, &size, nil, 0)
        let startTimeSec = Double(kinfo.kp_proc.p_starttime.tv_sec) +
                          Double(kinfo.kp_proc.p_starttime.tv_usec) / 1_000_000.0

        return ProcessMetrics(
            cpuUserTime: cpuUserTime,
            cpuSystemTime: cpuSystemTime,
            virtualMemoryBytes: virtualMemoryBytes,
            residentMemoryBytes: residentMemoryBytes,
            openFileDescriptors: openFds,
            maxFileDescriptors: maxFds,
            processStartTime: startTimeSec
        )
    }

    private static func getOpenFileDescriptorCount() -> Int {
        // Count open file descriptors by iterating through possible FDs
        var count = 0
        var rlimit = rlimit()
        getrlimit(RLIMIT_NOFILE, &rlimit)
        let maxCheck = min(Int(rlimit.rlim_cur), 4096) // Cap at 4096 for performance

        for fd in 0..<maxCheck {
            var statbuf = stat()
            if fstat(Int32(fd), &statbuf) == 0 {
                count += 1
            }
        }
        return count
    }
    #endif

    #if os(Linux)
    private static func collectLinux() -> ProcessMetrics {
        // Get CPU time using getrusage
        var rusage = rusage()
        getrusage(RUSAGE_SELF, &rusage)
        let cpuUserTime = Double(rusage.ru_utime.tv_sec) + Double(rusage.ru_utime.tv_usec) / 1_000_000.0
        let cpuSystemTime = Double(rusage.ru_stime.tv_sec) + Double(rusage.ru_stime.tv_usec) / 1_000_000.0

        // Get memory info from /proc/self/statm
        var virtualMemoryBytes = 0
        var residentMemoryBytes = 0
        if let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) {
            let parts = statm.split(separator: " ")
            if parts.count >= 2 {
                let pageSize = sysconf(_SC_PAGESIZE)
                virtualMemoryBytes = (Int(parts[0]) ?? 0) * pageSize
                residentMemoryBytes = (Int(parts[1]) ?? 0) * pageSize
            }
        }

        // Get file descriptor counts from /proc/self/fd
        var openFds = 0
        if let fdDir = try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd") {
            openFds = fdDir.count
        }

        var rlimit = rlimit()
        getrlimit(Int32(RLIMIT_NOFILE), &rlimit)
        let maxFds = Int(rlimit.rlim_cur)

        // Get process start time from /proc/self/stat
        var startTimeSec: Double = Date().timeIntervalSince1970
        if let stat = try? String(contentsOfFile: "/proc/self/stat", encoding: .utf8) {
            // Field 22 is starttime (in clock ticks since boot)
            let parts = stat.split(separator: " ")
            if parts.count >= 22, let startTicks = UInt64(parts[21]) {
                // Get system boot time and clock ticks per second
                let ticksPerSecond = Double(sysconf(_SC_CLK_TCK))
                if let uptime = try? String(contentsOfFile: "/proc/uptime", encoding: .utf8) {
                    let uptimeParts = uptime.split(separator: " ")
                    if let uptimeSec = Double(uptimeParts[0]) {
                        let bootTime = Date().timeIntervalSince1970 - uptimeSec
                        startTimeSec = bootTime + Double(startTicks) / ticksPerSecond
                    }
                }
            }
        }

        return ProcessMetrics(
            cpuUserTime: cpuUserTime,
            cpuSystemTime: cpuSystemTime,
            virtualMemoryBytes: virtualMemoryBytes,
            residentMemoryBytes: residentMemoryBytes,
            openFileDescriptors: openFds,
            maxFileDescriptors: maxFds,
            processStartTime: startTimeSec
        )
    }
    #endif
}

/// Snapshot of all metrics at a point in time
public struct MetricsSnapshot: Sendable {
    /// Metrics for all feature sets
    public let featureSets: [FeatureSetMetrics]

    /// System-level process metrics
    public let processMetrics: ProcessMetrics

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
        processMetrics: ProcessMetrics,
        collectedAt: Date,
        applicationStartTime: Date
    ) {
        self.featureSets = featureSets
        self.processMetrics = processMetrics
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
                processMetrics: ProcessMetrics.collect(),
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
