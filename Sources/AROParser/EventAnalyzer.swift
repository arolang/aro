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
        guard activity.hasSuffix(" Handler") else { return nil }

        // Exclude system handlers
        if activity.contains("Socket Event Handler") ||
           activity.contains("File Event Handler") ||
           activity.contains("Application-End") {
            return nil
        }

        let eventType = activity
            .replacingOccurrences(of: " Handler", with: "")
            .trimmingCharacters(in: .whitespaces)

        return eventType.isEmpty ? nil : eventType
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

    /// Detects events that are emitted but have no corresponding handler
    public func detectOrphanedEventEmissions(_ featureSets: [AnalyzedFeatureSet]) {
        // Collect all handled event types
        var handledEvents: Set<String> = []
        for analyzed in featureSets {
            if let eventType = Self.extractEventType(from: analyzed.featureSet.businessActivity) {
                handledEvents.insert(eventType)
            }
        }

        // Collect all emitted events and check for orphans
        for analyzed in featureSets {
            let emittedEvents = Self.findEmittedEventsWithLocations(in: analyzed.featureSet.statements)

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
        var events: [(String, SourceLocation)] = []
        for statement in statements {
            collectEmittedEventsWithLocations(from: statement, into: &events)
        }
        return events
    }

    /// Recursively collects emitted events with locations from a statement
    private static func collectEmittedEventsWithLocations(from statement: Statement, into events: inout [(String, SourceLocation)]) {
        if let aro = statement as? AROStatement {
            if aro.action.verb.lowercased() == "emit" {
                events.append((aro.result.base, aro.span.start))
            }
        }

        if let match = statement as? MatchStatement {
            for caseClause in match.cases {
                for bodyStatement in caseClause.body {
                    collectEmittedEventsWithLocations(from: bodyStatement, into: &events)
                }
            }
            if let otherwise = match.otherwise {
                for bodyStatement in otherwise {
                    collectEmittedEventsWithLocations(from: bodyStatement, into: &events)
                }
            }
        }

        if let forEach = statement as? ForEachLoop {
            for bodyStatement in forEach.body {
                collectEmittedEventsWithLocations(from: bodyStatement, into: &events)
            }
        }
    }
}
