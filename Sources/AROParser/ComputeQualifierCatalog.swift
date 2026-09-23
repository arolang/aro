// ============================================================
// ComputeQualifierCatalog.swift
// AROParser — the closed set of built-in Compute qualifiers
// ============================================================
//
// GitLab #486 closed the Compute qualifier namespace at run time:
// an explicit qualifier that resolves to nothing is an error
// rather than a silent pass-through. GitLab #465 is the other
// half — `aro check` still accepted every one of those names, so
// a program could check clean and then die on its first
// statement. A gate that green-lights code the runtime rejects is
// worse than no gate, because it is trusted.
//
// The names live here rather than in ARORuntime because the check
// path (`aro check` → `Compiler` → `SemanticAnalyzer`) never loads
// the runtime. Same reasoning as `ActionCatalog`: AROParser is the
// module every other module imports, so a catalog shared between
// analysis and execution has to live in it.
//
// The implementations stay in `ComputeAction.builtInQualifiers`,
// which is the only place that can carry them. Two lists means
// drift, so a runtime test asserts the two sets are equal — adding
// a qualifier without listing it here fails the suite.

import Foundation

/// Every built-in Compute qualifier name, and the rules for deciding
/// whether a written qualifier could resolve at run time.
public enum ComputeQualifierCatalog {

    /// Verbs that dispatch to the Compute action.
    public static let computeVerbs: Set<String> = ["compute", "calculate", "derive"]

    /// Canonical names of the built-in qualifiers, lowercase.
    ///
    /// Mirrors `ComputeAction.builtInQualifiers` one-for-one. Order is
    /// the documentation order used there.
    public static let builtIns: Set<String> = [
        // Digests
        "hash", "sha256",
        // Size
        "length", "count",
        // Text
        "uppercase", "lowercase", "trim", "replace", "identity", "clip", "take",
        // Dates
        "date", "format", "distance",
        // Sets (ARO-0042)
        "intersect", "difference", "union",
        // Rendering
        "markdown",
        // Encoding / escaping (GitLab #482)
        "html-escape", "url-encode", "url-decode",
        "base64-encode", "base64-decode",
        "base64url-encode", "base64url-decode",
        "json-escape",
        // Collections / text (GitLab #486)
        "lines", "join", "sum", "avg", "average", "unique", "random",
        // Money (GitLab #517)
        "fixed",
    ]

    /// Qualifiers people reach for that are real operations in ARO but
    /// are spelled as *actions*, not as Compute qualifiers.
    ///
    /// These are the three from GitLab #465 plus their near neighbours.
    /// Pointing at the working spelling is the whole value of the
    /// diagnostic — "unknown qualifier" alone leaves the user guessing
    /// that the capability is missing, when it is one word away.
    public static func redirect(for qualifier: String, result: String, object: String) -> String? {
        switch qualifier.lowercased() {
        case "sort", "sorted", "order", "arrange":
            return "Sorting is an action: Sort the <\(result)> for the <\(object)>."
        case "reverse", "reversed", "flip":
            return "Reversing is an action: Reverse the <\(result)> for the <\(object)>."
        case "first", "last":
            return "Element access is an Extract qualifier: "
                 + "Extract the <\(result): \(qualifier.lowercased())> from the <\(object)>."
        case "filter", "where":
            return "Filtering is an action: Filter the <\(result)> from the <\(object)> where …"
        case "map", "select":
            return "Projection is an action: Map the <\(result)> from the <\(object)> with <field>."
        case "group":
            return "Grouping is an action: Group the <\(result)> from the <\(object)> by <field>."
        case "min", "max":
            return "Use the Reduce action: "
                 + "Reduce the <\(result)> from the <\(object)> with \(qualifier.lowercased())()."
        case "split":
            return "Splitting is an action: Split the <\(result)> from the <\(object)> with \",\"."
        case "timezone", "tz", "zone", "localtime", "local-time":
            // GitLab #865. Every other date operation — `date`, `format`,
            // `distance` — is a Compute qualifier, so this is the first place
            // people look. Timezone conversion is an Extract because it reads
            // one rendering of an instant out of another (ARO-0041 §7).
            return "Timezone conversion is an Extract: "
                 + "Extract the <\(result): timezone> from the <\(object)> "
                 + "with \"Europe/Berlin\"."
        case "round", "rounded", "money", "currency", "precision":
            // GitLab #517: these are the names people reach for when a
            // price prints as 7.199999999999999. `fixed` is one word
            // away, and edit distance will never find it from "money".
            //
            // `Money` written PascalCase is the *other* thing — a domain
            // type from ARO-0014 — and belongs in the `as` clause, so
            // capitalisation decides which advice is right.
            if looksLikeTypeName(qualifier) {
                return "For a result type, use `as`: "
                     + "Compute the <\(result)> as \(qualifier) from the <\(object)>."
            }
            return "Rounding to decimal places is the `fixed` qualifier: "
                 + "Compute the <\(result): fixed> from the <\(object)> "
                 + "(2 places; `with { places: 3 }` for more)."
        default:
            // A type name in the qualifier slot is the other common
            // confusion. The two are different things and GitLab #475
            // separated them for exactly that reason: the qualifier
            // picks an *operation*, `as` requests a *result type*.
            if looksLikeTypeName(qualifier) {
                return "For a result type, use `as`: "
                     + "Compute the <\(result)> as \(qualifier) from the <\(object)>."
            }
            return nil
        }
    }

    /// PascalCase, or a known primitive spelling — the shapes users
    /// write when they mean a type rather than an operation.
    private static func looksLikeTypeName(_ qualifier: String) -> Bool {
        let primitives: Set<String> = [
            "string", "int", "integer", "float", "double", "number",
            "bool", "boolean", "list", "array", "set", "object", "dictionary",
        ]
        if primitives.contains(qualifier.lowercased()) { return true }
        guard let first = qualifier.first else { return false }
        return first.isUppercase && !qualifier.contains(" ")
    }

    /// True when the qualifier cannot be judged at check time.
    ///
    /// Deliberately generous. `aro check` does not load plugins, so a
    /// namespaced name (`collections.reverse`) and any chain that
    /// mentions one are unknowable here — treating "cannot check" as
    /// "invalid" would flag correct programs, which is the failure mode
    /// this whole change exists to avoid.
    public static func isUncheckable(_ qualifier: String) -> Bool {
        // Plugin namespace: `handle.qualifier`. Registration is
        // exclusively namespaced (QualifierRegistry.register), so a dot
        // is the reliable marker.
        if qualifier.contains(".") { return true }
        // Qualifier chain — `a|b`. Not judgeable *as a unit*; callers
        // that can judge stages individually should split first via
        // `chainStages` (GitLab #492) and apply these rules per stage.
        if qualifier.contains("|") { return true }
        // Generic type annotation, e.g. `List<UserSummary>`.
        if qualifier.contains("<") { return true }
        // Date offsets: `-7d`, `+1M`, `+24h`, `+2 weeks`.
        if isDateOffset(qualifier) { return true }
        return false
    }

    /// Matches `DateOffset.isOffsetPattern` in ARORuntime. Duplicated
    /// rather than shared because the pattern is three lines and the
    /// dependency would run the wrong way (runtime → parser is the only
    /// legal direction).
    public static func isDateOffset(_ string: String) -> Bool {
        let pattern = #"^[+-]?\d+(?:[smhdwMy]|seconds?|minutes?|min|hours?|days?|weeks?|months?|years?)$"#
        return string.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether a written qualifier names a built-in.
    public static func isBuiltIn(_ qualifier: String) -> Bool {
        builtIns.contains(qualifier.lowercased())
    }

    /// The stages of a chain qualifier (`a|b`), or nil when the
    /// qualifier is not a chain (GitLab #492).
    ///
    /// An empty stage (`trim|`, `a||b`) comes back as an empty string
    /// rather than being dropped, so the caller can report the mistake
    /// instead of validating a chain the author did not write.
    public static func chainStages(_ qualifier: String) -> [String]? {
        guard qualifier.contains("|") else { return nil }
        return qualifier.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Built-in names within edit distance 2 of `qualifier`, nearest
    /// first. Catches the typo case (`uppecase`) that the redirect
    /// table cannot.
    public static func closestBuiltIns(to qualifier: String, limit: Int = 3) -> [String] {
        let needle = qualifier.lowercased()
        var scored: [(name: String, distance: Int)] = []
        for name in builtIns {
            let distance = EditDistance.levenshtein(name, needle)
            if distance <= 2 {
                scored.append((name, distance))
            }
        }
        scored.sort { lhs, rhs in
            lhs.distance == rhs.distance ? lhs.name < rhs.name : lhs.distance < rhs.distance
        }
        return scored.prefix(limit).map(\.name)
    }
}
