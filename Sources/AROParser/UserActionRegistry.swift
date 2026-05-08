// ============================================================
// UserActionRegistry.swift
// AROParser - User-Defined Action Catalogue (ARO-0081)
// ============================================================
//
// User-defined actions are feature sets whose business activity is exactly
// `Action`. They are callable application-wide as `Application.<Name>` using
// the same call-site syntax as plugin actions. This registry indexes them
// during semantic analysis so:
//
// - The runtime can look up a name → feature set mapping at registration time.
// - The semantic analyser can flag duplicate-name and unknown-call diagnostics
//   before the program ever runs.

import Foundation

// MARK: - UserActionInfo

/// Metadata for a user-defined action discovered during semantic analysis.
public struct UserActionInfo: Sendable, Equatable {
    /// Action name as written in the feature set header (e.g. "DoubleValue").
    /// Callers invoke as `Application.<name>` (case-sensitive).
    public let name: String

    /// Sugar slot field declared via `takes <field>` in the header, if any.
    /// When non-nil, callers may use `from <value>` to bind `<value>` to this
    /// field on `<input>`.
    public let takesField: String?

    /// Optional type annotation for the takes field (e.g. "Integer").
    public let takesType: String?

    /// Source location of the action's declaration, for duplicate-name diagnostics.
    public let span: SourceSpan

    public init(name: String, takesField: String?, takesType: String?, span: SourceSpan) {
        self.name = name
        self.takesField = takesField
        self.takesType = takesType
        self.span = span
    }
}

// MARK: - UserActionRegistry

/// Application-wide registry of user-defined actions.
///
/// Built once per `analyze()` pass and exposed on `AnalyzedProgram` so both
/// further analysis passes and the runtime registration step can consult it
/// without re-walking the AST.
public struct UserActionRegistry: Sendable, Equatable {
    /// Action name → metadata. Keys are case-sensitive, matching the header.
    public let actions: [String: UserActionInfo]

    public init(actions: [String: UserActionInfo] = [:]) {
        self.actions = actions
    }

    /// Look up an action by its bare name (e.g. `"DoubleValue"`).
    public func info(for name: String) -> UserActionInfo? {
        actions[name]
    }

    /// Look up an action via the call-site verb (e.g. `"Application.DoubleValue"`).
    public func info(forCallVerb verb: String) -> UserActionInfo? {
        guard let bare = Self.actionName(fromCallVerb: verb) else { return nil }
        return actions[bare]
    }

    /// Decompose a call verb. Returns the bare action name when `verb` matches
    /// `Application.<Name>`, otherwise nil.
    public static func actionName(fromCallVerb verb: String) -> String? {
        let prefix = "Application."
        guard verb.hasPrefix(prefix) else { return nil }
        let bare = String(verb.dropFirst(prefix.count))
        return bare.isEmpty ? nil : bare
    }

    /// Sorted list of all known action names (used in diagnostic hints).
    public var allNames: [String] {
        actions.keys.sorted()
    }

    public var isEmpty: Bool { actions.isEmpty }
}

// MARK: - Framework Variables

/// Variable names that are *only* available inside event handlers, HTTP routes,
/// and lifecycle feature sets. Referencing them from inside an `Action` body is
/// a compile error because user-defined actions are synchronous transformations
/// with no event/request context.
public enum UserActionFrameworkVariables {
    /// The set the analyser checks against. Lower-cased for case-insensitive
    /// comparison against object/specifier identifiers.
    public static let names: Set<String> = [
        "request",
        "response",
        "event",
        "pathparameters",
        "queryparameters",
    ]

    /// True if the given identifier is a framework variable.
    public static func contains(_ identifier: String) -> Bool {
        names.contains(identifier.lowercased())
    }
}
