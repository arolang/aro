// ============================================================
// NumberFormatCatalog.swift
// ARO Parser - what `as <Type>` asks of the arithmetic (GitLab #906)
// ============================================================

/// How a result annotation asks for its arithmetic to be done.
public enum AroNumberFormat: String, Sendable, CaseIterable {
    /// No numeric annotation. `Int ⊕ Int` stays `Int`; `/` truncates.
    case natural
    /// `as Float` / `as Double`: binary floating point, and `7 / 2` is `3.5`.
    case float
    /// `as Integer` / `as Int`: a whole number.
    case integer
    /// `as Currency` / `as Decimal`: exact base-10 arithmetic.
    case exact
}

/// The one table mapping an `as <Type>` name to the arithmetic it asks for.
///
/// It lives in `AROParser` because three places need the same answer and only
/// one of them can load the runtime:
///
///   - `aro check` (this module) decides whether to constant-fold and what to
///     say about a misspelling,
///   - `AROCompiler` decides whether a literal subtree may be folded at build
///     time — `3 * 2.40` folded to a `Double` bakes `7.199999999999999` into
///     the binary before the runtime can be exact about it,
///   - `ARORuntime`'s `ResultTypeCoercion` picks the evaluator and coerces the
///     result, in the interpreter and in a compiled binary alike.
///
/// Two copies of this mapping is how `as Decimal` came to promise exactness
/// and deliver `Double` (GitLab #906), and how the compiled path came to drop
/// the annotation entirely.
public enum NumberFormatCatalog {

    /// `as Float`, `as Double`.
    ///
    /// `number` is deliberately absent: it was never in this set, and adding
    /// it here would change the arithmetic of programs that already write it.
    public static let floatNames: Set<String> = ["float", "double"]

    /// `as Integer`, `as Int`.
    public static let integerNames: Set<String> = ["integer", "int"]

    /// `as Currency`, `as Decimal`.
    ///
    /// They are the same format. `Decimal` was accepted before #906 and
    /// quietly meant `Double` — the word that promises exactness delivering
    /// binary floating point. Making it mean what it says fixes that without
    /// breaking the programs that already wrote it; `Currency` is the spelling
    /// to prefer, because it says *why* the exactness is wanted and is what a
    /// reader looks for when the subject is money.
    public static let exactNames: Set<String> = ["currency", "decimal"]

    /// What `asType` asks for. `.natural` when there is no annotation, or when
    /// the annotation names something other than a number — an OpenAPI schema,
    /// say, which the arithmetic has no opinion about.
    public static func format(for asType: String?) -> AroNumberFormat {
        guard let asType else { return .natural }
        let name = asType.lowercased()
        if exactNames.contains(name) { return .exact }
        if floatNames.contains(name) { return .float }
        if integerNames.contains(name) { return .integer }
        return .natural
    }

    /// Whether an expression carrying this annotation may be folded to a
    /// literal at build time.
    ///
    /// Only `.natural` may. A numeric annotation *changes the arithmetic*, and
    /// the folder only knows natural-mode semantics, so folding pre-empts the
    /// annotation with the answer it was written to avoid:
    ///
    ///   - `as Currency from 3 * 2.40` folds to `7.199999999999999`, and no
    ///     later coercion recovers `7.20` from it (GitLab #906).
    ///   - `as Float from 7 / 2` folds to `3`, because Int/Int division
    ///     truncates in natural mode — which is exactly the divergence
    ///     GitLab #475 fixed for the interpreter and the compiled path kept,
    ///     since it dropped the annotation entirely.
    ///
    /// The cost is one unfolded expression per annotated statement, evaluated
    /// at run time like any other. The alternative is a compiled binary that
    /// disagrees with `aro run` about a literal.
    public static func allowsConstantFolding(_ asType: String?) -> Bool {
        format(for: asType) == .natural
    }

    /// Every numeric annotation spelling, for diagnostics.
    public static var allNames: [String] {
        (floatNames.union(integerNames).union(exactNames)).sorted()
    }
}
