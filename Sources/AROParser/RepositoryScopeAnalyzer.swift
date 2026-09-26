// ============================================================
// RepositoryScopeAnalyzer.swift
// AROParser — scope mistakes that are visible before the program runs
// ARO-0094 §7.2, GitLab #885
// ============================================================
//
// Scope resolution is partly static. A feature set's trigger is known from its
// business activity, and a trigger decides what kind of caller can exist: an
// `Application-Start` never has one, a file watcher never has one, an HTTP
// route has a session but no connection the program can see. So a whole class
// of scope error is a check-time finding rather than a runtime surprise on the
// first request that happens to reach the statement.
//
// The one case deliberately left to run time is a socket handler touching a
// session-scoped repository: promotion (`Attach`) may have happened, and the
// analyzer cannot know whether it did. That is a runtime error when it has not.
//
// This lives in AROParser because `aro check` never loads the runtime.

import Foundation

public enum RepositoryScopeAnalyzer {

    /// The three scopes, spelled here rather than imported: the runtime's
    /// `RepositoryScope` is in ARORuntime, and the check path must not depend
    /// on it. `RepositoryScopeCatalogTests` pins the two lists together, the
    /// way `ComputeQualifierCatalog` is pinned to `ComputeAction`.
    public static let scopeNames = ["application", "connection", "session"]

    /// One `Declare the <x-repository> with { scope: "…" }.` statement.
    public struct Declaration: Sendable, Equatable {
        public let repository: String
        public let scope: String
        public let location: SourceLocation?
    }

    // MARK: - Collecting declarations

    /// Every scope declaration in one file.
    ///
    /// Declarations are collected across the whole application before any file
    /// is checked, because `Declare` lives in `Application-Start` while the
    /// statements it governs are in the handler files — the same shape as
    /// `handledEventTypes`.
    public static func declarations(in program: Program) -> [Declaration] {
        var found: [Declaration] = []
        for featureSet in program.featureSets {
            for statement in featureSet.statements {
                guard let aro = statement as? AROStatement,
                      aro.action.verb.lowercased() == "declare" else { continue }
                guard let scope = scopeText(of: aro) else { continue }
                found.append(Declaration(repository: aro.result.base,
                                         scope: scope,
                                         location: aro.span.start))
            }
        }
        return found
    }

    /// The `scope:` field of a `Declare … with { … }`.
    ///
    /// `with { … }` reaches the statement as an expression rather than a
    /// literal — the object clause is `with the <_expression_>` and the map is
    /// the value — so this reads the map node rather than `valueSource.asLiteral`.
    private static func scopeText(of statement: AROStatement) -> String? {
        let map: MapLiteralExpression?
        if case .expression(let expression) = statement.valueSource {
            map = expression as? MapLiteralExpression
        } else if let with = statement.rangeModifiers.withClause {
            map = with as? MapLiteralExpression
        } else {
            map = nil
        }
        guard let entry = map?.entries.first(where: { $0.key == "scope" }) else { return nil }

        // `{ scope: "session" }`. A bare word is a *variable reference* in ARO
        // (ARO-0094 §3.1.1), so it arrives as a VariableRefExpression and the
        // program would fail at run time with "Undefined variable: session".
        // Reporting the name here is what makes that a check-time diagnostic
        // naming a scope rather than a runtime one naming a variable.
        if let literal = entry.value as? LiteralExpression,
           case .string(let text) = literal.value {
            return text
        }
        if let reference = entry.value as? VariableRefExpression {
            return reference.noun.base
        }
        return entry.value.description
    }

    /// Reduce declarations to a lookup, reporting the ones that disagree.
    ///
    /// A repository declared twice with different scopes means one of the two
    /// statements is wrong; picking either silently would make the wrong one
    /// look correct, and if the wrong one is the wider scope that is the leak.
    public static func resolve(_ declarations: [Declaration],
                               diagnostics: DiagnosticCollector? = nil) -> [String: String] {
        var scopes: [String: String] = [:]
        for declaration in declarations {
            guard scopeNames.contains(declaration.scope) else {
                diagnostics?.add(Diagnostic(
                    severity: .error,
                    message: "'\(declaration.scope)' is not a scope for \(declaration.repository)",
                    location: declaration.location,
                    hints: ["The scopes are \(scopeNames.joined(separator: ", "))",
                            "Write the scope as a string: with { scope: \"session\" } — "
                            + "a bare word is a variable reference"]))
                continue
            }
            if let existing = scopes[declaration.repository], existing != declaration.scope {
                diagnostics?.add(Diagnostic(
                    severity: .error,
                    message: "\(declaration.repository) is declared \(existing)-scoped and "
                           + "\(declaration.scope)-scoped",
                    location: declaration.location,
                    hints: ["One of the two Declare statements is wrong",
                            "A repository has one scope for the whole application"]))
                continue
            }
            scopes[declaration.repository] = declaration.scope
        }
        return scopes
    }

    /// Report the declarations in one file: unknown scopes, and disagreement
    /// with any declaration elsewhere in the application.
    ///
    /// Reported per file rather than once for the application so the
    /// diagnostic lands on a line the developer can open.
    public static func checkDeclarations(_ program: Program,
                                         applicationScopes: [String: String],
                                         diagnostics: DiagnosticCollector) {
        let local = declarations(in: program)
        guard !local.isEmpty else { return }

        // Unknown scopes and same-file conflicts.
        let resolvedLocally = resolve(local, diagnostics: diagnostics)

        // A declaration that disagrees with one in a sibling file. Only the
        // repositories that survived the local pass, so a name already
        // reported above is not reported twice.
        for (repository, scope) in resolvedLocally {
            guard let elsewhere = applicationScopes[repository], elsewhere != scope else { continue }
            let location = local.first { $0.repository == repository }?.location
            diagnostics.add(Diagnostic(
                severity: .error,
                message: "\(repository) is declared \(scope)-scoped here and "
                       + "\(elsewhere)-scoped elsewhere in the application",
                location: location,
                hints: ["A repository has one scope for the whole application",
                        "Feature sets are globally visible in ARO, so there is one "
                        + "\(repository) and it cannot be two things"]))
        }
    }

    // MARK: - Checking uses

    /// What kind of caller a feature set can possibly have.
    enum CallerAvailability {
        case none               // Application-Start, a file watcher, an observer
        case sessionOnly        // an HTTP route: a session, no visible connection
        case connectionOnly     // a TCP socket handler, until `Attach` promotes it
        case both               // a WebSocket: a connection, and a session if the upgrade carried one
        case unknown            // a user-defined action: runs as whoever called it
    }

    static func availability(for activity: String) -> CallerAvailability {
        switch ActivityKind.parse(activity) {
        case .fileEvent, .applicationEnd, .repositoryObserver, .repositoryEviction,
             .keyPress, .stateTransition, .stateObserver, .notification, .watch:
            return .none
        case .socketEvent:
            return .connectionOnly
        case .webSocketEvent:
            return .both
        case .userAction:
            // Called from anywhere, so it inherits its caller. Nothing static
            // to say, and warning here would fire on every shared helper.
            return .unknown
        case .domainEvent:
            // An event handler runs on the emitting caller's behalf in the
            // interpreter, but an event can also be emitted from a scheduled
            // job. Not decidable here.
            return .unknown
        case .plain:
            return .sessionOnly     // an OpenAPI operationId, or documentation
        }
    }

    /// Report scope mistakes that are visible statically.
    public static func check(_ program: Program,
                             scopes: [String: String],
                             diagnostics: DiagnosticCollector) {
        guard !scopes.isEmpty else { return }

        for featureSet in program.featureSets {
            let isStart = featureSet.name == "Application-Start"
            let availability: CallerAvailability = isStart
                ? .none
                : self.availability(for: featureSet.businessActivity)
            if case .unknown = availability { continue }

            for statement in featureSet.statements {
                guard let aro = statement as? AROStatement else { continue }
                let verb = aro.action.verb.lowercased()
                guard verb != "declare" else { continue }

                // A repository appears as the object of a read and as the
                // object of a write alike, and as the result of nothing, so
                // one place to look.
                let repository = aro.object.noun.base
                guard let scope = scopes[repository], scope != "application" else { continue }

                switch (scope, availability) {
                case ("session", .none):
                    diagnostics.add(Diagnostic(
                        severity: .error,
                        message: "\(repository) is session-scoped, and \(featureSet.name) "
                               + "can never have a session",
                        location: aro.span.start,
                        hints: ["\(featureSet.businessActivity) is not triggered by a caller",
                                "Declare it application-scoped, or move this statement to a route"]))

                case ("connection", .none):
                    diagnostics.add(Diagnostic(
                        severity: .error,
                        message: "\(repository) is connection-scoped, and \(featureSet.name) "
                               + "can never have a connection",
                        location: aro.span.start,
                        hints: ["\(featureSet.businessActivity) is not triggered by a connection",
                                "Declare it application-scoped, or move this statement to a "
                                + "Socket or WebSocket Event Handler"]))

                case ("connection", .sessionOnly):
                    diagnostics.add(Diagnostic(
                        severity: .error,
                        message: "\(repository) is connection-scoped, and an HTTP request has no "
                               + "connection the program can see",
                        location: aro.span.start,
                        hints: ["HTTP callers are identified by session, not by connection",
                                "Declare \(repository) with { scope: \"session\" }"]))

                default:
                    // A socket handler touching a session repository is not an
                    // error here: `Attach` may have promoted the connection.
                    // It is a runtime error when it has not.
                    break
                }
            }
        }
    }
}
