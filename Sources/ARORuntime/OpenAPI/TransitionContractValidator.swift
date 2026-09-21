// ============================================================
// TransitionContractValidator.swift
// ARO Runtime — the declared transition graph (GitLab #507)
// ============================================================
//
// `Accept the <transition: draft_to_approved> on <order: status>.`
// used to be checked against exactly one thing: the entity's *current*
// state. So a draft order could be approved, shipped or teleported —
// the set of legal moves was whatever transition names the code
// happened to spell, and a typo (`shiped`) was a new state rather than
// a mistake. Chapter 31 drew state diagrams the machine never enforced.
//
// The contract is now the authority. An entity's states are declared as
// a string `enum` on its state property in `openapi.yaml`, and both
// halves of a transition name must be members of it. A state that is
// not declared is a build error — reported by `aro check`, `aro run`
// and `aro build`, before anything runs.
//
// Contract-first is opt-in throughout ARO: no `openapi.yaml` means no
// HTTP server, and here it means no enforcement. A project without a
// contract, or an entity whose state property carries no enum, keeps
// the old behaviour and builds exactly as before. The runtime's
// from-state check is unchanged either way — this gate is in addition
// to it, not instead of it.

import Foundation
import AROParser

/// Checks `Accept` statements against the state enums declared by an
/// OpenAPI contract.
public enum TransitionContractValidator {

    // MARK: - Declared states

    /// One state property the contract declares, e.g.
    /// `components.schemas.Order.status` with its six states.
    public struct DeclaredStates: Sendable, Equatable {
        public let schemaName: String
        public let propertyName: String
        /// The enum members, in declaration order.
        public let states: [String]

        public init(schemaName: String, propertyName: String, states: [String]) {
            self.schemaName = schemaName
            self.propertyName = propertyName
            self.states = states
        }

        /// How the diagnostic names this property to the reader.
        public var contractPath: String {
            "components.schemas.\(schemaName).\(propertyName)"
        }
    }

    /// Every string-enum property declared by the contract's schemas.
    ///
    /// A property counts when its schema — directly, through a `$ref`, or
    /// through an `allOf` member — carries an `enum` whose members are all
    /// strings. `Order.status` in `Examples/OrderService` reaches its enum
    /// through `$ref: '#/components/schemas/OrderStatus'`, which is the
    /// idiomatic spelling, so following refs is not optional.
    public static func declaredStates(in spec: OpenAPISpec) -> [DeclaredStates] {
        guard let schemas = spec.components?.schemas else { return [] }

        var found: [DeclaredStates] = []
        for (schemaName, schemaRef) in schemas {
            guard let properties = schemaRef.value.properties else { continue }
            for (propertyName, propertyRef) in properties {
                guard let states = stringEnum(of: propertyRef.value, schemas: schemas, depth: 0),
                      !states.isEmpty
                else { continue }
                found.append(DeclaredStates(
                    schemaName: schemaName,
                    propertyName: propertyName,
                    states: states
                ))
            }
        }
        return found.sorted {
            $0.schemaName == $1.schemaName
                ? $0.propertyName < $1.propertyName
                : $0.schemaName < $1.schemaName
        }
    }

    /// The string enum a schema declares, following one `$ref` hop at a
    /// time and looking inside `allOf`. Depth-limited so a contract that
    /// refs itself cannot spin.
    private static func stringEnum(
        of schema: Schema,
        schemas: [String: SchemaRef],
        depth: Int
    ) -> [String]? {
        guard depth <= 8 else { return nil }

        if let values = schema.enumValues, !values.isEmpty {
            var strings: [String] = []
            for value in values {
                guard case .string(let s) = value else { return nil }
                strings.append(s)
            }
            return strings
        }

        if let ref = schema.ref,
           let target = componentSchemaName(fromRef: ref),
           let referenced = schemas[target] {
            return stringEnum(of: referenced.value, schemas: schemas, depth: depth + 1)
        }

        for member in schema.allOf ?? [] {
            if let states = stringEnum(of: member.value, schemas: schemas, depth: depth + 1) {
                return states
            }
        }

        return nil
    }

    /// `#/components/schemas/OrderStatus` → `OrderStatus`.
    private static func componentSchemaName(fromRef ref: String) -> String? {
        let parts = ref.split(separator: "/").map(String.init)
        guard parts.count == 4,
              parts[0] == "#",
              parts[1] == "components",
              parts[2] == "schemas"
        else { return nil }
        return parts[3]
    }

    // MARK: - Validation

    /// Errors for every `Accept` statement that names a state the contract
    /// does not declare.
    ///
    /// Returns an empty array when the directory holds no contract — that
    /// is the documented contract-less path, not a failure.
    public static func validate(
        _ featureSets: [FeatureSet],
        inDirectory directory: URL
    ) -> [Diagnostic] {
        guard let contract = OpenAPILoader.findContract(in: directory),
              let spec = try? OpenAPILoader.load(from: contract)
        else { return [] }
        return validate(
            featureSets,
            against: spec,
            contractFilename: contract.lastPathComponent
        )
    }

    public static func validate(
        _ featureSets: [FeatureSet],
        against spec: OpenAPISpec,
        contractFilename: String = "openapi.yaml"
    ) -> [Diagnostic] {
        let declared = declaredStates(in: spec)
        guard !declared.isEmpty else { return [] }

        var diagnostics: [Diagnostic] = []
        for featureSet in featureSets {
            for statement in acceptStatements(in: featureSet.statements) {
                diagnostics.append(contentsOf: check(
                    statement,
                    declared: declared,
                    contractFilename: contractFilename
                ))
            }
        }
        return diagnostics
    }

    private static func check(
        _ statement: AROStatement,
        declared: [DeclaredStates],
        contractFilename: String
    ) -> [Diagnostic] {
        guard let transition = TransitionName.parse(
            base: statement.result.base,
            specifiers: statement.result.specifiers
        ) else { return [] }

        let entity = statement.object.noun.base
        // `on <order: status>` — the field defaults to `status`, exactly as
        // AcceptAction does at run time.
        let field = statement.object.noun.specifiers.first ?? "status"

        guard let target = resolve(entity: entity, field: field, in: declared) else {
            // The contract says nothing about this entity's state property.
            // Contract-first is opt-in: say nothing rather than guess.
            return []
        }

        let allowed = Set(target.states)
        var diagnostics: [Diagnostic] = []

        // Report both halves when both are wrong — the author wrote one
        // token and deserves to see everything wrong with it at once.
        for state in [transition.from, transition.to] where !allowed.contains(state) {
            var hints = [
                "Checked against \(target.contractPath) in \(contractFilename)",
                "Declared states: \(target.states.joined(separator: ", "))",
            ]
            let near = closest(to: state, in: target.states)
            if !near.isEmpty {
                hints.append("Closest declared state\(near.count == 1 ? "" : "s"): \(near.joined(separator: ", "))")
            }
            hints.append("Add '\(state)' to that enum, or transition to a declared state")

            diagnostics.append(Diagnostic(
                severity: .error,
                message: "State '\(state)' is not declared by the contract "
                    + "(transition '\(transition.raw)' on <\(entity): \(field)>)",
                location: statement.result.span.start,
                hints: hints
            ))
        }
        return diagnostics
    }

    // MARK: - Which schema declares this entity's states

    /// Picks the schema an `Accept` statement is talking about.
    ///
    /// Three rules, tried in order, all of which fail safe to "no
    /// enforcement" rather than to a guess:
    ///
    /// 1. **By name.** The entity name, or one of its `-`/`_` segments,
    ///    matches a schema name (case- and plural-insensitive): `order`,
    ///    `orders` and `picked-order` all reach `Order`.
    /// 2. **By field, unambiguously.** No name matched, but exactly one
    ///    schema in the whole contract declares an enum on that field — a
    ///    contract with one `status` enum *is* the state machine.
    /// 3. **Otherwise nothing.** Zero candidates, or several that the two
    ///    rules above cannot separate, means the contract does not say —
    ///    and a build error nobody can act on is worse than no check.
    static func resolve(
        entity: String,
        field: String,
        in declared: [DeclaredStates]
    ) -> DeclaredStates? {
        let candidates = declared.filter { same($0.propertyName, field) }
        guard !candidates.isEmpty else { return nil }

        let segments = entity
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)

        let byName = candidates.filter { candidate in
            same(candidate.schemaName, entity)
                || segments.contains { same(candidate.schemaName, $0) }
        }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { return nil }

        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Case-, separator- and plural-insensitive name comparison.
    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalize(lhs)
        let b = normalize(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a == b + "s" || a + "s" == b
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Traversal

    /// Every `Accept` statement in a feature set, including the ones
    /// nested inside `match` cases and `for each` bodies.
    private static func acceptStatements(in statements: [Statement]) -> [AROStatement] {
        var found: [AROStatement] = []
        for statement in statements {
            if let aro = statement as? AROStatement {
                if aro.action.verb.lowercased() == "accept" { found.append(aro) }
            } else if let match = statement as? MatchStatement {
                for matchCase in match.cases {
                    found.append(contentsOf: acceptStatements(in: matchCase.body))
                }
                found.append(contentsOf: acceptStatements(in: match.otherwise ?? []))
            } else if let loop = statement as? ForEachLoop {
                found.append(contentsOf: acceptStatements(in: loop.body))
            }
        }
        return found
    }

    // MARK: - Closest match

    /// Declared states within edit distance 2 of `state`, nearest first —
    /// the same "did you mean" shape `ComputeQualifierCatalog` uses for
    /// unknown qualifiers.
    static func closest(to state: String, in states: [String], limit: Int = 3) -> [String] {
        let needle = state.lowercased()
        var scored: [(name: String, distance: Int)] = []
        for candidate in states {
            let distance = EditDistance.levenshtein(candidate.lowercased(), needle)
            if distance <= 2 { scored.append((candidate, distance)) }
        }
        scored.sort { $0.distance == $1.distance ? $0.name < $1.name : $0.distance < $1.distance }
        return scored.prefix(limit).map(\.name)
    }
}
