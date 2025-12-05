// ============================================================
// OutputContext.swift
// ARO Runtime - Output Context for Response Formatting
// ============================================================

import Foundation

/// Output context determines how responses and logs are formatted
///
/// ARO automatically detects the execution context and formats output appropriately:
/// - **machine**: JSON/structured data for API responses and event handlers
/// - **human**: Readable formatted text for CLI and console output
/// - **developer**: Detailed diagnostics for tests and debugging
public enum OutputContext: String, Sendable, Equatable, CaseIterable {
    /// Machine context - JSON output for APIs and events
    case machine

    /// Human context - readable text for CLI and console
    case human

    /// Developer context - diagnostic output for tests and debugging
    case developer
}
