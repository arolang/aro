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

    // MARK: - Application-Wide Discovery (GitLab #587)

    /// Union of two registries. Entries in `self` win on a name collision,
    /// because `self` is the file being analysed and it carries the spans the
    /// diagnostics point at.
    public func merging(_ other: UserActionRegistry) -> UserActionRegistry {
        guard !other.isEmpty else { return self }
        guard !isEmpty else { return other }
        var merged = other.actions
        for (name, info) in actions { merged[name] = info }
        return UserActionRegistry(actions: merged)
    }

    /// Actions declared by these feature sets, without running semantic
    /// analysis. Duplicates are *not* reported here — that is
    /// `UserActionAnalyzer.buildRegistry`'s job, and reporting them twice
    /// would double every duplicate-name error.
    public static func declared(in featureSets: [FeatureSet]) -> UserActionRegistry {
        var actions: [String: UserActionInfo] = [:]
        for fs in featureSets where fs.isUserAction {
            if actions[fs.name] != nil { continue }
            actions[fs.name] = UserActionInfo(
                name: fs.name,
                takesField: fs.userActionTakesField,
                takesType: fs.userActionTakesType,
                span: fs.span
            )
        }
        return UserActionRegistry(actions: actions)
    }

    /// Actions declared anywhere in `program`.
    public static func declared(in program: Program) -> UserActionRegistry {
        declared(in: program.featureSets)
    }

    /// Actions declared anywhere in an application, given all of its sources.
    ///
    /// An ARO application has no imports — every feature set is visible to
    /// every other one (ARO-0005) — so "does this action exist?" can only be
    /// answered across the whole application. A caller that compiles one file
    /// at a time collects this from all of them first and hands the union to
    /// `Compiler.compile(_:externallyHandledEvents:declaredUserActions:)`.
    ///
    /// Parse-only: an `Action` header carries everything this needs, so no
    /// semantic analysis runs here, and a source that does not parse simply
    /// contributes nothing — its own errors are reported when it is compiled.
    public static func declared(inSources sources: [String]) -> UserActionRegistry {
        var actions: [String: UserActionInfo] = [:]
        for source in sources {
            guard let tokens = try? Lexer.tokenize(source),
                  let program = try? Parser(tokens: tokens).parse()
            else { continue }
            for (name, info) in declared(in: program).actions where actions[name] == nil {
                actions[name] = info
            }
        }
        return UserActionRegistry(actions: actions)
    }

    /// Actions declared anywhere in an application, given its source files.
    /// A file that cannot be read contributes nothing, for the same reason a
    /// file that cannot be parsed does.
    public static func declared(inFiles files: [URL]) -> UserActionRegistry {
        declared(inSources: files.compactMap { try? String(contentsOf: $0, encoding: .utf8) })
    }

    /// The known names closest to `name`, for "did you mean" hints.
    /// Same shape as `ComputeQualifierCatalog.closestBuiltIns(to:)`: plain
    /// Levenshtein, distance ≤ 2, best three.
    public func closestNames(to name: String, limit: Int = 3) -> [String] {
        var scored: [(name: String, distance: Int)] = []
        for candidate in actions.keys {
            let distance = Self.editDistance(candidate.lowercased(), name.lowercased())
            if distance <= 2 { scored.append((candidate, distance)) }
        }
        scored.sort { lhs, rhs in
            lhs.distance == rhs.distance ? lhs.name < rhs.name : lhs.distance < rhs.distance
        }
        return scored.prefix(limit).map(\.name)
    }

    /// Plain Levenshtein distance over Characters.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let substitution = previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}

// MARK: - Analysis Scope

/// How much of the application the analyser was given.
///
/// A user-defined action is visible application-wide, so an unknown-call
/// diagnostic can only say "no actions are declared in this application" when
/// it has actually seen the application. `aro check`, `aro run` and `aro build`
/// scan every `.aro` file first and analyse with `.application`; the LSP, the
/// REPL and a one-off `Compiler.compile(source)` see a single file and analyse
/// with `.file`, where a declaration next door is genuinely out of sight.
public enum UserActionScope: Sendable, Equatable {
    case application
    case file
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
