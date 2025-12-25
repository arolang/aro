// ============================================================
// EventChainAnalyzer.swift
// ARO Parser - Circular Event Chain Detection
// ============================================================

import Foundation

// MARK: - Event Cycle

/// Represents a detected circular event chain
public struct EventCycle: Sendable, Equatable {
    /// The event types forming the cycle (e.g., ["UserCreated", "FileCreated", "UserCreated"])
    public let events: [String]

    /// The feature set names involved in the cycle
    public let featureSets: [String]

    /// Location of the first handler in the cycle (for error reporting)
    public let location: SourceLocation?

    public init(events: [String], featureSets: [String], location: SourceLocation?) {
        self.events = events
        self.featureSets = featureSets
        self.location = location
    }

    /// Returns a human-readable description of the cycle
    public var description: String {
        events.joined(separator: " → ")
    }
}

// MARK: - Handler Info

/// Information about an event handler
struct HandlerInfo {
    let featureSetName: String
    let handledEventType: String
    let emittedEventTypes: Set<String>
    let location: SourceLocation
}

// MARK: - Event Chain Analyzer

/// Analyzes event flow graphs to detect circular chains
public final class EventChainAnalyzer: Sendable {

    public init() {}

    // MARK: - Public Interface

    /// Detects circular event chains in the given feature sets
    /// - Parameter featureSets: The analyzed feature sets to check
    /// - Returns: Array of detected cycles (empty if none found)
    public func detectCycles(in featureSets: [AnalyzedFeatureSet]) -> [EventCycle] {
        // Step 1: Extract handler information
        let handlers = extractHandlers(from: featureSets)

        // Step 2: Build event flow graph
        // Graph: eventType -> [eventTypes it can trigger]
        // An edge from A to B means: some handler for A emits B
        var graph: [String: Set<String>] = [:]
        var handlerLocations: [String: SourceLocation] = [:]
        var eventToHandler: [String: String] = [:]  // eventType -> handlerName

        for handler in handlers {
            let handled = handler.handledEventType
            handlerLocations[handled] = handler.location
            eventToHandler[handled] = handler.featureSetName

            for emitted in handler.emittedEventTypes {
                graph[handled, default: []].insert(emitted)
            }
        }

        // Step 3: Detect cycles using DFS
        return detectCyclesInGraph(graph, handlerLocations: handlerLocations, eventToHandler: eventToHandler)
    }

    // MARK: - Handler Extraction

    /// Extracts handler information from feature sets
    private func extractHandlers(from featureSets: [AnalyzedFeatureSet]) -> [HandlerInfo] {
        var handlers: [HandlerInfo] = []

        for analyzed in featureSets {
            let featureSet = analyzed.featureSet

            // Check if this is a domain event handler
            guard let eventType = extractHandledEventType(from: featureSet.businessActivity) else {
                continue
            }

            // Find all emit statements in this handler
            let emittedEvents = findEmittedEvents(in: featureSet.statements)

            handlers.append(HandlerInfo(
                featureSetName: featureSet.name,
                handledEventType: eventType,
                emittedEventTypes: emittedEvents,
                location: featureSet.span.start
            ))
        }

        return handlers
    }

    /// Extracts the handled event type from a business activity
    /// - Parameter activity: The business activity string (e.g., "UserCreated Handler")
    /// - Returns: The event type if this is a domain handler, nil otherwise
    private func extractHandledEventType(from activity: String) -> String? {
        // Must end with " Handler"
        guard activity.hasSuffix(" Handler") else {
            return nil
        }

        // Exclude special system handlers
        let specialHandlers = ["Socket Event Handler", "File Event Handler"]
        for special in specialHandlers {
            if activity.contains(special) {
                return nil
            }
        }

        // Exclude Application-End handlers
        if activity.contains("Application-End") {
            return nil
        }

        // Extract event type by removing " Handler" suffix
        let eventType = activity
            .replacingOccurrences(of: " Handler", with: "")
            .trimmingCharacters(in: .whitespaces)

        return eventType.isEmpty ? nil : eventType
    }

    /// Finds all event types emitted by the given statements
    /// - Parameter statements: The statements to search
    /// - Returns: Set of event type names that are emitted
    private func findEmittedEvents(in statements: [Statement]) -> Set<String> {
        var events: Set<String> = []

        for statement in statements {
            collectEmittedEvents(from: statement, into: &events)
        }

        return events
    }

    /// Recursively collects emitted events from a statement
    private func collectEmittedEvents(from statement: Statement, into events: inout Set<String>) {
        // Check AROStatement for Emit action
        if let aro = statement as? AROStatement {
            if aro.action.verb.lowercased() == "emit" {
                // The event type is in the result's base (e.g., "UserCreated" from <UserCreated: event>)
                events.insert(aro.result.base)
            }
        }

        // Check nested statements in Match
        if let match = statement as? MatchStatement {
            for caseClause in match.cases {
                for bodyStatement in caseClause.body {
                    collectEmittedEvents(from: bodyStatement, into: &events)
                }
            }
            if let otherwise = match.otherwise {
                for bodyStatement in otherwise {
                    collectEmittedEvents(from: bodyStatement, into: &events)
                }
            }
        }

        // Check nested statements in ForEach
        if let forEach = statement as? ForEachLoop {
            for bodyStatement in forEach.body {
                collectEmittedEvents(from: bodyStatement, into: &events)
            }
        }
    }

    // MARK: - Cycle Detection

    /// DFS node colors for cycle detection
    private enum Color {
        case white  // Unvisited
        case gray   // In current path (visiting)
        case black  // Fully processed
    }

    /// Detects cycles in the event flow graph using DFS
    private func detectCyclesInGraph(
        _ graph: [String: Set<String>],
        handlerLocations: [String: SourceLocation],
        eventToHandler: [String: String]
    ) -> [EventCycle] {
        var colors: [String: Color] = [:]
        var path: [String] = []
        var cycles: [EventCycle] = []
        var foundCycles: Set<String> = []  // To avoid duplicate cycles

        func dfs(_ node: String) {
            colors[node] = .gray
            path.append(node)

            for neighbor in graph[node] ?? [] {
                if colors[neighbor] == .gray {
                    // Found cycle - extract it from path
                    if let startIndex = path.firstIndex(of: neighbor) {
                        let cycleEvents = Array(path[startIndex...]) + [neighbor]

                        // Create a canonical representation to detect duplicates
                        let canonical = cycleEvents.dropLast().sorted().joined(separator: ",")
                        if !foundCycles.contains(canonical) {
                            foundCycles.insert(canonical)

                            // Build list of feature sets involved
                            let featureSetNames = cycleEvents.dropLast().compactMap { eventToHandler[$0] }

                            // Get location of first handler in cycle
                            let location = handlerLocations[neighbor]

                            cycles.append(EventCycle(
                                events: cycleEvents,
                                featureSets: featureSetNames,
                                location: location
                            ))
                        }
                    }
                } else if colors[neighbor] == nil || colors[neighbor] == .white {
                    dfs(neighbor)
                }
            }

            path.removeLast()
            colors[node] = .black
        }

        // Run DFS from all nodes
        for node in graph.keys {
            if colors[node] != .black {
                dfs(node)
            }
        }

        return cycles
    }
}
