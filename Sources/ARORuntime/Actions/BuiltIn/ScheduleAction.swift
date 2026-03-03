// ============================================================
// ScheduleAction.swift
// ARO Runtime - Periodic Event Scheduling
// ============================================================

import Foundation
import AROParser

/// Schedules a periodic domain event emission at a fixed interval.
///
/// The Schedule action starts a background timer that emits a named
/// `DomainEvent` on every tick. Any feature set declared as
/// `(Name: tick-name Handler)` will be triggered on each tick.
///
/// The application keeps running (Keepalive stays in service mode) as
/// long as the schedule is active.
///
/// ## Syntax
/// ```
/// Schedule the <tick-name> with 2.           (* every 2 seconds *)
/// Schedule the <tick-name> with 2 seconds.   (* every 2 seconds *)
/// Schedule the <refresh> with 30 seconds.    (* every 30 seconds *)
/// Schedule the <hourly> with 1 hour.         (* every hour *)
/// ```
///
/// ## Example
/// ```aro
/// (Application-Start: My App) {
///     Schedule the <metrics-tick> with 2 seconds.
///     Keepalive the <application> for the <events>.
///     Return an <OK: status> for the <startup>.
/// }
///
/// (Collect Data: metrics-tick Handler) {
///     (* This runs every 2 seconds *)
///     Return an <OK: status> for the <collection>.
/// }
/// ```
public struct ScheduleAction: ActionImplementation {
    public static let role: ActionRole = .export
    public static let verbs: Set<String> = ["schedule"]
    public static let validPrepositions: Set<Preposition> = [.with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Resolve the numeric interval value.
        // When a time-unit suffix is present ("with 2 seconds."), the parser sets
        // object.base = "seconds" instead of "_expression_", which means the
        // FeatureSetExecutor skips the _with_ binding. Fall back to _expression_.
        let rawValue: Double
        if let v = context.resolveAny("_with_") as? Int {
            rawValue = Double(v)
        } else if let v = context.resolveAny("_with_") as? Double {
            rawValue = v
        } else if let v = context.resolveAny("_expression_") as? Int {
            rawValue = Double(v)
        } else if let v = context.resolveAny("_expression_") as? Double {
            rawValue = v
        } else if let v = context.resolveAny("_literal_") as? Int {
            rawValue = Double(v)
        } else if let v = context.resolveAny("_literal_") as? Double {
            rawValue = v
        } else {
            rawValue = 1.0
        }

        // Apply time-unit multiplier set by the parser for "with N unit" syntax
        let multipliers: [String: Double] = [
            "second": 1, "seconds": 1,
            "minute": 60, "minutes": 60,
            "hour": 3600, "hours": 3600
        ]
        let multiplier = multipliers[object.base] ?? 1.0
        let intervalSeconds = rawValue * multiplier

        let eventName = result.base

        // Register as an active event source so Keepalive stays in service mode
        // (waits for SIGINT/SIGTERM rather than the 2-second idle exit)
        await EventBus.shared.registerEventSource()

        // Start the timer in a detached task (not tied to the current feature set)
        let timerTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                EventBus.shared.publish(DomainEvent(eventType: eventName, payload: [:]))
            }
        }

        // Watch for shutdown and cancel the timer when it arrives
        Task.detached {
            await ShutdownCoordinator.shared.waitForShutdown()
            timerTask.cancel()
            await EventBus.shared.unregisterEventSource()
        }

        let intervalInt = Int(intervalSeconds)
        context.bind(result.base, value: intervalInt)
        return intervalInt
    }
}
