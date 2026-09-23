// ============================================================
// ResponseStatusValidator.swift
// AROParser — status names that only look like they work
// ============================================================
//
// GitLab #830 item 15. `Return a <TooManyRequests: status> with <retry>.`
// parsed, checked, ran, and answered **200**. So did
// `<Unprocessable: status>`, `<MethodNotAllowed: status>`,
// `<Unavailable: status>` — and so did `<NotFoudn: status>`, because the
// status name was never looked up at all: two hard-coded switches mapped
// a handful of names and fell through to 200 for everything else.
//
// The names themselves are fixed in `HTTPStatusCatalog`, so those four
// now mean what they say. What is left is the typo, and it is reported
// here rather than at run time.
//
// Only the typo. An unrecognised name mapping to 200 is *specified*
// behaviour, not a bug: ARO-0002 §7 writes `Return a
// <PendingVerification: status>` and means a domain status that is a 200
// on the wire. Warning about every one of those would be the noise
// GitLab #823 is about. So the rule is narrow — warn when the name is
// within a typo's distance of a real status name, since `NotFoudn` is
// not a domain vocabulary, it is `NotFound` misspelt, and it answers 200
// to a request that was not found.

import Foundation

/// Warns when a `Return`/`Throw` status name is a near-miss of a real one.
public struct ResponseStatusValidator {

    private let diagnostics: DiagnosticCollector

    public init(diagnostics: DiagnosticCollector) {
        self.diagnostics = diagnostics
    }

    /// Verbs whose result slot carries an HTTP status.
    static let statusVerbs: Set<String> = ["return", "throw"]

    public func validate(_ featureSet: FeatureSet) {
        for statement in collectAROStatements(featureSet.statements) {
            validateStatusName(statement)
        }
    }

    private func validateStatusName(_ statement: AROStatement) {
        guard Self.statusVerbs.contains(statement.action.verb.lowercased()) else { return }

        let result = statement.result

        // `<OK: status>` — the qualifier says this slot is a status, and
        // the base is the name. Anything without that qualifier is a
        // plain value being returned and is none of this check's business.
        guard let qualifier = result.typeAnnotation?.lowercased(),
              qualifier == "status" else { return }

        // A quoted base is a literal, not a name we can look up.
        guard !result.isLiteralQualifier else { return }

        let name = result.base
        guard !name.isEmpty, !HTTPStatusCatalog.isKnown(name) else { return }

        // A name built from a variable cannot be judged statically.
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return }

        // No near neighbour means this is a domain status, which is a
        // legitimate 200. Nothing to say.
        guard let near = HTTPStatusCatalog.closestMatch(to: name) else { return }

        diagnostics.warning(
            "Status name '\(name)' is not a known status — it will be answered 200",
            at: result.span.start,
            hints: [
                "Did you mean <\(near): status>?",
                "If '\(name)' is a domain status of your own, 200 is correct and this warning is noise — "
                  + "spell it so it is not one letter from '\(near)'.",
            ]
        )
    }

    /// Flatten nested statements so a status inside a `match` case or a
    /// loop is checked too — same walk as `CollectionOpValidator`.
    private func collectAROStatements(_ statements: [Statement]) -> [AROStatement] {
        var out: [AROStatement] = []
        for statement in statements {
            if let aro = statement as? AROStatement {
                out.append(aro)
            } else if let match = statement as? MatchStatement {
                for matchCase in match.cases {
                    out.append(contentsOf: collectAROStatements(matchCase.body))
                }
                out.append(contentsOf: collectAROStatements(match.otherwise ?? []))
            } else if let loop = statement as? ForEachLoop {
                out.append(contentsOf: collectAROStatements(loop.body))
            }
        }
        return out
    }
}
