// ============================================================
// SymbolIndex.swift
// SOLARO — project-wide identifier index for go-to-def + find-refs
// ============================================================
//
// Walks every parsed Program in the workspace and indexes:
//   * definitions — every statement whose result.base is a real
//     identifier (i.e. not synthetic _expression_ / _sink_)
//   * references  — every identifier mentioned in an object slot,
//     with/to clause, or value-source expression
//
// Cross-file: a name defined in any file is reachable from any
// other (matches ARO's "all feature sets globally visible" rule
// from CLAUDE.md). Publish-as aliases aren't followed yet —
// that's a follow-up.

import Foundation
import AROParser

struct SymbolHit: Identifiable, Equatable, Hashable {
    var id: String { "\(file.path)#\(line)#\(column)" }
    let name: String
    let file: URL
    let line: Int       // 1-indexed
    let column: Int     // 1-indexed
    /// True for a definition (the statement's result), false for
    /// a reference (the identifier appears in an object / with /
    /// to / valueSource expression).
    let isDefinition: Bool
    /// Verb of the surrounding statement — used to tint rows in
    /// the symbol palette by role.
    let verb: String
}

struct SymbolIndex: Equatable {
    private(set) var definitions: [String: [SymbolHit]] = [:]
    private(set) var references: [String: [SymbolHit]] = [:]

    var allDefinedNames: [String] {
        definitions.keys.sorted()
    }

    /// Build the index from the parsed-programs dictionary kept on
    /// the workspace controller.
    static func build(from programs: [URL: Program]) -> SymbolIndex {
        var defs: [String: [SymbolHit]] = [:]
        var refs: [String: [SymbolHit]] = [:]

        for (url, program) in programs {
            for fs in program.featureSets {
                for statement in fs.statements {
                    guard let aro = statement as? AROStatement else { continue }
                    let resultName = aro.result.base
                    if isRealIdentifier(resultName) {
                        defs[resultName, default: []].append(SymbolHit(
                            name: resultName,
                            file: url,
                            line: aro.span.start.line,
                            column: aro.span.start.column,
                            isDefinition: true,
                            verb: aro.action.verb
                        ))
                    }
                    for referenced in collectReferences(in: aro) {
                        guard isRealIdentifier(referenced) else { continue }
                        refs[referenced, default: []].append(SymbolHit(
                            name: referenced,
                            file: url,
                            line: aro.span.start.line,
                            column: aro.span.start.column,
                            isDefinition: false,
                            verb: aro.action.verb
                        ))
                    }
                }
            }
        }

        return SymbolIndex(definitions: defs, references: refs)
    }

    private static func isRealIdentifier(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("_")
    }

    /// Pull every identifier this statement reads. Mirrors the
    /// CanvasNode.collectReferenced logic, kept local here so the
    /// symbol index doesn't depend on the canvas data model.
    private static func collectReferences(in statement: AROStatement) -> [String] {
        var out: Set<String> = []
        let objectBase = statement.object.noun.base
        if isRealIdentifier(objectBase) { out.insert(objectBase) }
        if case .expression(let expr) = statement.valueSource {
            walk(expr, into: &out)
        }
        if case .sinkExpression(let expr) = statement.valueSource {
            walk(expr, into: &out)
        }
        if let withClause = statement.withClause { walk(withClause, into: &out) }
        if let toClause = statement.toClause { walk(toClause, into: &out) }
        return Array(out)
    }

    private static func walk(_ expression: any AROParser.Expression,
                             into out: inout Set<String>) {
        if let varRef = expression as? VariableRefExpression {
            if isRealIdentifier(varRef.noun.base) {
                out.insert(varRef.noun.base)
            }
        }
        // Composite expressions handled later — for now we catch the
        // overwhelming common case of bare variable references.
    }
}
