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

        // Collect all emitted events and check for orphans.
        //
        // #339: consume the cached flattened statement walk built during
        // data-flow analysis instead of re-traversing the tree. Filtering the
        // cache for `emit` verbs yields the identical (eventType, location)
        // sequence `findEmittedEventsWithLocations` would produce — the cache is
        // every AROStatement in the same source order — so diagnostics are
        // unchanged. Feature sets analyzed without the cache (empty list) fall
        // back to a fresh walk to preserve behaviour for any external caller.
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
        let collector = EmittedEventLocationCollector()
        for statement in statements {
            statement.accept(collector)
        }
        return collector.events
    }

    /// Collects `(eventName, location)` for each `Emit` action, descending into
    /// match cases/otherwise and for-each bodies in source order. Replaces the
    /// old three-way `as?`-chain (#434) with `StatementVisitor` dispatch;
    /// statement kinds the chain ignored — including while / range loop bodies,
    /// which it never traversed — collect nothing here, preserving the original
    /// behaviour and ordering exactly.
    private final class EmittedEventLocationCollector: StatementVisitor {
        typealias Result = Void
        var events: [(String, SourceLocation)] = []

        func visit(_ node: AROStatement) {
            if node.action.verb.lowercased() == "emit" {
                events.append((node.result.base, node.span.start))
            }
        }

        func visit(_ node: MatchStatement) {
            for caseClause in node.cases {
                for bodyStatement in caseClause.body {
                    bodyStatement.accept(self)
                }
            }
            if let otherwise = node.otherwise {
                for bodyStatement in otherwise {
                    bodyStatement.accept(self)
                }
            }
        }

        func visit(_ node: ForEachLoop) {
            for bodyStatement in node.body {
                bodyStatement.accept(self)
            }
        }

        // Nodes the original chain matched no case for — no emitted events.
        func visit(_ node: PublishStatement) {}
        func visit(_ node: RequireStatement) {}
        func visit(_ node: WhileLoop) {}
        func visit(_ node: BreakStatement) {}
        func visit(_ node: RangeLoop) {}
        func visit(_ node: PipelineStatement) {}
        func visit(_ node: ErrorStatement) {}
    }
}
