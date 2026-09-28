// ============================================================
// EventAnalyzer.swift
// ARO Parser - Event Analysis (Cycles, Orphans, Helpers)
// ============================================================

import Foundation

// MARK: - Event Analyzer

/// Analyzes event flow: circular chains, orphaned emissions, and event type extraction
public struct EventAnalyzer {

    private let diagnostics: DiagnosticCollector

    public init(diagnostics: DiagnosticCollector) {
        self.diagnostics = diagnostics
    }

    // MARK: - Shared Helper

    /// Extracts the event type from a handler's business activity string.
    ///
    /// Returns the event type (e.g. "UserCreated" from "UserCreated Handler"),
    /// or nil if the activity is not a domain event handler.
    public static func extractEventType(from activity: String) -> String? {
        // One classifier, in `ActivityKind` (GitLab #724). The hand-written
        // exclusion list here named Socket, File and Application-End but not
        // WebSocket, KeyPress, StateTransition, StateObserver or
        // NotificationSent — so a `WebSocket Event Handler` was reported as a
        // domain event called "WebSocket Event", and four more like it.
        return ActivityKind.parse(activity).handledDomainEvent
    }

    // MARK: - Circular Event Chain Detection

    /// Detects circular event chains that would cause infinite loops at runtime
    public func detectCircularEventChains(_ featureSets: [AnalyzedFeatureSet]) {
        let analyzer = EventChainAnalyzer()
        let cycles = analyzer.detectCycles(in: featureSets)

        for cycle in cycles {
            diagnostics.error(
                "Circular event chain detected: \(cycle.description)",
                at: cycle.location,
                hints: [
                    "Event handlers form an infinite loop that will exhaust resources",
                    "Consider breaking the chain by using different event types or adding termination conditions"
                ]
            )
        }
    }

    // MARK: - Orphaned Event Detection

    /// Event types handled by the feature sets in `program`.
    ///
    /// An ARO application has no imports — every feature set is visible to
    /// every other one — so "is this event handled?" can only be answered
    /// across the whole application. A caller that analyses one file at a
    /// time must collect this from all of them first and pass the union to
    /// `detectOrphanedEventEmissions(_:externallyHandled:)`.
    public static func handledEventTypes(in program: Program) -> Set<String> {
        var handled: Set<String> = []
        for featureSet in program.featureSets {
            if let eventType = extractEventType(from: featureSet.businessActivity) {
                handled.insert(eventType)
            }
        }
        return handled
    }

    /// Detects events that are emitted but have no corresponding handler
    ///
    /// - Parameter externallyHandled: event types handled elsewhere in the
    ///   application — outside the feature sets given here. Empty when the
    ///   whole program is in `featureSets`, which is the case for `aro run`
    ///   and `aro build`; `aro check` compiles a file at a time and supplies
    ///   the rest of the application's handlers through this.
    public func detectOrphanedEventEmissions(
        _ featureSets: [AnalyzedFeatureSet],
        externallyHandled: Set<String> = []
    ) {
        // Collect all handled event types
        var handledEvents: Set<String> = externallyHandled
        for analyzed in featureSets {
            if let eventType = Self.extractEventType(from: analyzed.featureSet.businessActivity) {
                handledEvents.insert(eventType)
            }
        }

        // Collect all emitted events and check for orphans.
        //
        // #339: consume the cached flattened statement walk built during
        // data-flow analysis instead of re-traversing the tree. Feature sets
        // analyzed without the cache (empty list) fall back to a fresh walk.
        //
        // The two really are the same sequence now. The cache is
        // `AROStatementWalk.flatten`, and the fallback used to be a private
        // visitor that stopped at while loops, range loops and pipelines — so
        // an `Emit` inside a `while` body was an orphan-event warning or not
        // depending on which caller asked (GitLab #723). Both are the walker.
        for analyzed in featureSets {
            let emittedEvents: [(String, SourceLocation)]
            if !analyzed.flattenedAROStatements.isEmpty {
                emittedEvents = analyzed.flattenedAROStatements
                    .filter { $0.action.verb.lowercased() == "emit" }
                    .map { ($0.result.base, $0.span.start) }
            } else {
                emittedEvents = Self.findEmittedEventsWithLocations(in: analyzed.featureSet.statements)
            }

            for (eventType, location) in emittedEvents {
                if !handledEvents.contains(eventType) {
                    diagnostics.warning(
                        "Event '\(eventType)' is emitted but no handler exists",
                        at: location,
                        hints: [
                            "Create a handler with business activity '\(eventType) Handler'",
                            "Or remove this Emit statement if the event is not needed"
                        ]
                    )
                }
            }
        }
    }

    // MARK: - Emit Statement Collection

    /// Finds all emitted events with their source locations
    public static func findEmittedEventsWithLocations(in statements: [Statement]) -> [(String, SourceLocation)] {
        AROStatementWalk.flatten(statements)
            .filter { $0.action.verb.lowercased() == "emit" }
            .map { ($0.result.base, $0.span.start) }
    }
}
