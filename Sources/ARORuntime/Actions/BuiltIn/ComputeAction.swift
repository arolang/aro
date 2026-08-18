// ============================================================
// ComputeAction.swift
// ARO Runtime - Compute and Transform Action Implementations
// ============================================================

import Foundation
import AROParser
import Crypto

// MARK: - Helper Functions

/// Resolves the operation name from a result descriptor.
///
/// This function enables two syntax patterns:
/// 1. **New syntax** `<variable: operation>`: specifier defines the operation, base is the variable name
/// 2. **Legacy syntax** `<operation>`: base is both the variable name and operation (for known operations)
///
/// - Parameters:
///   - result: The result descriptor from the statement
///   - knownOperations: Set of known operation names for backward compatibility
///   - fallback: Default value if no operation can be determined
/// - Returns: The operation name to use
private func resolveOperationName(
    from result: ResultDescriptor,
    knownOperations: Set<String>,
    fallback: String
) -> String {
    // Priority 1: Explicit specifiers (new syntax: <var: operation> or <var: plugin.qualifier>)
    // Join all specifiers with '.' to support namespaced qualifier form (e.g., plugin-name.qualifier)
    if !result.specifiers.isEmpty {
        return result.specifiers.joined(separator: ".")
    }

    // Priority 2: Base name if it's a known operation (legacy syntax: <operation>)
    if knownOperations.contains(result.base.lowercased()) {
        return result.base
    }

    // Priority 3: Fallback default
    return fallback
}

// MARK: - Compute Actions

/// Computes a value from inputs
///
/// The Compute action is an OWN action that performs internal computation.
/// It uses the result specifiers to determine the computation name and
/// the object as input.
///
/// ## Example
/// ```
/// <Compute> the <password: hash> for the <user: credentials>.
/// ```
public struct ComputeAction: SynchronousAction {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["compute", "calculate", "derive"]
    public static let validPrepositions: Set<Preposition> = [.from, .for, .with]

    public init() {}

    // MARK: - #326: table-driven computation dispatch
    //
    // Built-in computations were a 100-line switch keyed by the
    // canonical operation name. Each new operation grew the switch and
    // bumped the cyclomatic complexity of the same method. Move them
    // into a name→closure registry so adding an op is one entry instead
    // of one more branch in the giant switch, and so the operation set
    // can be enumerated for documentation and tests.
    //
    // Each operation receives the resolved input plus the calling
    // ExecutionContext (for `_with_`, `_to_`, `_expression_` and
    // service lookups) and returns the computed value. Operations that
    // need to surface a "use the async path" signal still throw
    // `NeedsAsyncExecution`; everything else throws `ActionError`.

    typealias ComputeOp = @Sendable (any Sendable, any ExecutionContext) throws -> any Sendable

    /// One built-in qualifier: how to run it, and what to say about
    /// it when something asks what exists.
    ///
    /// The metadata rides along with the implementation on purpose
    /// (GitLab #486). It used to live in a hand-written list inside
    /// `QualifierRegistry`, which drifted to 15 entries while this
    /// table grew to 25 — so `aro actions --qualifiers` under-reported
    /// the runtime, and any catalog generated from it inherited the
    /// gap. One table, one truth.
    public struct BuiltInQualifier: Sendable {
        public let name: String
        public let inputTypes: Set<QualifierInputType>
        public let acceptsParameters: Bool
        public let summary: String
        let op: ComputeOp
    }

    /// Every built-in Compute qualifier, in documentation order.
    static let builtInQualifiers: [BuiltInQualifier] = [
        .init(name: "hash", inputTypes: Set(QualifierInputType.allCases),
              acceptsParameters: false,
              summary: "SHA-256 digest, hex-encoded", op: Self.opHash),
        .init(name: "sha256", inputTypes: Set(QualifierInputType.allCases),
              acceptsParameters: false,
              summary: "SHA-256 digest, hex-encoded (alias of hash)",
              op: Self.opHash),
        .init(name: "length", inputTypes: [.string, .list, .object],
              acceptsParameters: false,
              summary: "Count elements or characters", op: Self.opLength),
        .init(name: "count", inputTypes: [.string, .list, .object],
              acceptsParameters: false,
              summary: "Count elements or characters (alias of length)",
              op: Self.opLength),
        .init(name: "uppercase", inputTypes: [.string], acceptsParameters: false,
              summary: "Convert to UPPERCASE", op: Self.opUppercase),
        .init(name: "lowercase", inputTypes: [.string], acceptsParameters: false,
              summary: "Convert to lowercase", op: Self.opLowercase),
        .init(name: "trim", inputTypes: [.string], acceptsParameters: false,
              summary: "Strip leading and trailing whitespace", op: Self.opTrim),
        .init(name: "identity", inputTypes: Set(QualifierInputType.allCases),
              acceptsParameters: false,
              summary: "Pass-through (no-op)", op: Self.opIdentity),
        .init(name: "clip", inputTypes: [.string], acceptsParameters: true,
              summary: "Truncate string to width", op: Self.opClip),
        .init(name: "take", inputTypes: [.string, .list], acceptsParameters: true,
              summary: "First N elements", op: Self.opTake),
        .init(name: "date", inputTypes: [.string], acceptsParameters: false,
              summary: "Parse ISO 8601 string to date", op: Self.opDate),
        .init(name: "format", inputTypes: [.string], acceptsParameters: true,
              summary: "Format date with pattern", op: Self.opFormat),
        .init(name: "distance", inputTypes: [.string], acceptsParameters: true,
              summary: "Date distance between two dates", op: Self.opDistance),
        .init(name: "intersect", inputTypes: [.list, .object], acceptsParameters: true,
              summary: "Set intersection", op: Self.opIntersect),
        .init(name: "difference", inputTypes: [.list, .object], acceptsParameters: true,
              summary: "Set difference", op: Self.opDifference),
        .init(name: "union", inputTypes: [.list, .object], acceptsParameters: true,
              summary: "Set union", op: Self.opUnion),
        .init(name: "markdown", inputTypes: [.string], acceptsParameters: false,
              summary: "Render markdown to HTML", op: Self.opMarkdown),
        // Encoding / escaping primitives (GitLab #482)
        .init(name: "html-escape", inputTypes: [.string], acceptsParameters: false,
              summary: "Escape & < > \" ' for HTML", op: Self.opHTMLEscape),
        .init(name: "url-encode", inputTypes: [.string], acceptsParameters: false,
              summary: "Percent-encode a query value", op: Self.opURLEncode),
        .init(name: "url-decode", inputTypes: [.string], acceptsParameters: false,
              summary: "Decode a percent-encoded value", op: Self.opURLDecode),
        .init(name: "base64-encode", inputTypes: [.string], acceptsParameters: false,
              summary: "Standard Base64 encode", op: Self.opBase64Encode),
        .init(name: "base64-decode", inputTypes: [.string], acceptsParameters: false,
              summary: "Standard Base64 decode", op: Self.opBase64Decode),
        .init(name: "base64url-encode", inputTypes: [.string], acceptsParameters: false,
              summary: "URL-safe Base64 encode (JWTs)", op: Self.opBase64URLEncode),
        .init(name: "base64url-decode", inputTypes: [.string], acceptsParameters: false,
              summary: "URL-safe Base64 decode", op: Self.opBase64URLDecode),
        .init(name: "json-escape", inputTypes: [.string], acceptsParameters: false,
              summary: "Escape for a JSON string literal", op: Self.opJSONEscape),
        .init(name: "replace", inputTypes: [.string], acceptsParameters: true,
              summary: "Substring replacement", op: Self.opReplace),
        // Collection / text primitives (GitLab #486). Each of these
        // was among the names `aro ask` invented most often, which is
        // the strongest evidence there is that the gap was real: the
        // model reached for them because the idiom they replace runs
        // to three statements.
        .init(name: "lines", inputTypes: [.string], acceptsParameters: false,
              summary: "Split text into a list of lines (no phantom "
                     + "trailing element)", op: Self.opLines),
        .init(name: "join", inputTypes: [.list], acceptsParameters: true,
              summary: "Join a collection into a string; "
                     + "with { separator: \", \" }", op: Self.opJoin),
        .init(name: "sum", inputTypes: [.list], acceptsParameters: false,
              summary: "Total of a numeric collection", op: Self.opSum),
        .init(name: "avg", inputTypes: [.list], acceptsParameters: false,
              summary: "Arithmetic mean of a numeric collection", op: Self.opAverage),
        .init(name: "average", inputTypes: [.list], acceptsParameters: false,
              summary: "Arithmetic mean (alias of avg)", op: Self.opAverage),
        .init(name: "unique", inputTypes: [.string, .list], acceptsParameters: false,
              summary: "Remove duplicates, preserving first-seen order",
              op: Self.opUnique),
        .init(name: "random", inputTypes: [.string, .list, .int, .double],
              acceptsParameters: false,
              summary: "A random element, or a random Int below a bound",
              op: Self.opRandom),
    ]

    /// Canonical computation name → implementation, derived from
    /// `builtInQualifiers` so the two can never disagree.
    private static let computations: [String: ComputeOp] = Dictionary(
        uniqueKeysWithValues: builtInQualifiers.map { ($0.name, $0.op) }
    )

    /// Names recognised by the fast-path resolver. Derived from the
    /// registry plus the synonym for `count` (which `computations`
    /// already covers via a duplicate entry).
    private static let knownComputationNames: Set<String> = Set(computations.keys)

    // MARK: - Synchronous fast path (no Task.detached overhead in binary mode)

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        try validatePreposition(object.preposition)

        guard let input = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // #326: name set comes from the registry. Markdown is a
        // built-in but explicitly *not* in `knownComputations` because
        // it shouldn't be auto-resolved by qualifier inference — it's
        // only reachable via an explicit `:markdown` qualifier or the
        // result identifier.
        let computationName = resolveOperationName(
            from: result,
            knownOperations: Self.knownComputationNames,
            fallback: "identity"
        )

        // Qualifier chain — e.g., "stats.sort|list.take" evaluated left-to-right
        if computationName.contains("|") {
            let chain = computationName.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if let chainResult = try context.container.qualifierRegistry.resolveChain(chain, value: input) {
                context.bind(result.base, value: chainResult)
                return chainResult
            }
        }

        // Plugin qualifier — synchronous when the qualifier registry is sync
        // Pass with-clause parameters if present (bound as _with_ by FeatureSetExecutor)
        let withParams: [String: any Sendable]? = context.resolveAny("_with_") as? [String: any Sendable]
        if let pluginResult = try context.container.qualifierRegistry.resolve(computationName, value: input, withParams: withParams) {
            return pluginResult
        }

        // Date offset — synchronous
        if DateOffset.isOffsetPattern(computationName) {
            return try computeDateOffset(input: input, offsetPattern: computationName, context: context)
        }

        // Built-in computations — all synchronous except "count" on
        // streaming input, which throws NeedsAsyncExecution from the
        // length op. Markdown is the one entry not in
        // `knownComputationNames` so it stays explicit.
        let canonical = computationName.lowercased()
        if canonical == "markdown" {
            return try Self.opMarkdown(input, context)
        }
        if let op = Self.computations[canonical] {
            // GitLab #475: honour `as <Type>` on the result. Expression-valued
            // statements are already evaluated in the right numeric mode by
            // FeatureSetExecutor; this covers the operation paths, e.g.
            // `Compute the <n: length> as Float from <s>.`
            return ResultTypeCoercion.coerce(try op(input, context), to: result.asType)
        }

        // GitLab #486: an explicit qualifier that resolves to nothing
        // is a bug, and until now it silently returned the input
        // unchanged. That made every hallucinated qualifier —
        // `<total: lines>`, `<n: sum>`, 202 distinct names across the
        // training corpus — compile, check clean, run green, and
        // print the wrong answer. The namespace is closed (built-ins
        // + registered plugin qualifiers + date offsets), so there is
        // no case where an unrecognised name is correct.
        //
        // Only *explicit* qualifiers reach here. A result with no
        // specifiers resolves to `identity`, which is registered, so
        // plain `Compute the <total> from <a> + <b>` is untouched.
        if !result.specifiers.isEmpty {
            throw ActionError.unknownComputation(
                name: computationName,
                known: Self.knownComputationNames)
        }
        return ResultTypeCoercion.coerce(input, to: result.asType)
    }

    // MARK: - #326: extracted computation implementations
    //
    // Each method is reachable from `computations` and from a fast
    // path above (when the operation name needs explicit handling).
    // Signatures are uniform so the registry's `ComputeOp` typealias
    // can store all of them. Prefix is `op` to avoid shadowing the
    // existing instance helpers (`computeIntersect`, `computeUnion`,
    // …) that take their operands directly.

    private static func opHash(_ input: any Sendable, _ context: any ExecutionContext) throws -> any Sendable {
        let stringToHash: String
        if let str = input as? String {
            stringToHash = str
        } else if JSONSerialization.isValidJSONObject(input),
                  let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) {
            stringToHash = json
        } else {
            stringToHash = "\(input)"
        }
        guard let data = stringToHash.data(using: .utf8) else {
            throw ActionError.ioError("Failed to encode string as UTF-8")
        }
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Implements both `length` and `count` (registry has two entries
    /// pointing at this method).
    private static func opLength(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        if let str = input as? String { return str.count }
        if let arr = input as? [any Sendable] { return arr.count }
        if let dict = input as? [String: any Sendable] { return dict.count }
        // Streaming inputs need async — fall back to Task path
        if input is AnyStreamingValue { throw NeedsAsyncExecution() }
        return input
    }

    private static func opUppercase(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        if let str = input as? String { return str.uppercased() }
        return String(describing: input).uppercased()
    }

    private static func opLowercase(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        if let str = input as? String { return str.lowercased() }
        return String(describing: input).lowercased()
    }

    private static func opTrim(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        let str = input as? String ?? String(describing: input)
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func opIdentity(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        input
    }

    // MARK: - Encoding / escaping (GitLab #482)

    /// Coerces the operand to a String the same way `opTrim`/`opUppercase` do,
    /// so encoding a number or a bool works rather than erroring.
    private static func asText(_ input: any Sendable) -> String {
        input as? String ?? String(describing: input)
    }

    private static func opHTMLEscape(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        StringEncoding.htmlEscape(asText(input))
    }

    private static func opURLEncode(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        StringEncoding.urlEncode(asText(input))
    }

    private static func opURLDecode(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        StringEncoding.urlDecode(asText(input))
    }

    private static func opBase64Encode(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        StringEncoding.base64Encode(asText(input))
    }

    private static func opBase64Decode(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        let text = asText(input)
        guard let decoded = StringEncoding.base64Decode(text) else {
            throw ActionError.runtimeError("Cannot base64-decode the value: not valid Base64 UTF-8")
        }
        return decoded
    }

    private static func opBase64URLEncode(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        StringEncoding.base64URLEncode(asText(input))
    }

    private static func opBase64URLDecode(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        let text = asText(input)
        guard let decoded = StringEncoding.base64URLDecode(text) else {
            throw ActionError.runtimeError("Cannot base64url-decode the value: not valid Base64URL UTF-8")
        }
        return decoded
    }

    private static func opJSONEscape(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        StringEncoding.jsonEscape(asText(input))
    }

    /// `Compute the <out: replace> from <text> with { find: "-", replace: "_" }.`
    ///
    /// Takes its arguments from the `with` clause because it needs two of them,
    /// which the single-qualifier shape cannot express. `find` may not be empty —
    /// replacing the empty string is a no-op at best and ambiguous at worst, so
    /// it is reported rather than silently ignored.
    private static func opReplace(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        let text = asText(input)
        guard let config = context.resolveAny("_with_") as? [String: any Sendable] else {
            throw ActionError.missingRequiredField(
                "replace requires 'with { find: \"…\", replace: \"…\" }'"
            )
        }
        guard let find = config["find"] as? String, !find.isEmpty else {
            throw ActionError.missingRequiredField("replace requires a non-empty 'find'")
        }
        let replacement = config["replace"] as? String ?? ""
        return text.replacingOccurrences(of: find, with: replacement)
    }

    // MARK: - Collection / text primitives (GitLab #486)

    /// Numeric value of one element, for the aggregate operations.
    /// Accepts the numeric types the runtime actually produces plus
    /// numeric strings, so `sum` works on a list parsed out of CSV
    /// without a conversion step first.
    private static func numeric(_ value: any Sendable) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let f = value as? Float { return Double(f) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Every element of `input` as a list, for the collection ops.
    /// A bare scalar counts as a one-element list — `sum` of a single
    /// number is that number, which is less surprising than an error.
    private static func elements(_ input: any Sendable) -> [any Sendable] {
        if let arr = input as? [any Sendable] { return arr }
        if let arr = input as? [Int] { return arr }
        if let arr = input as? [Double] { return arr }
        if let arr = input as? [String] { return arr }
        return [input]
    }

    /// Total of a numeric collection. Returns an `Int` when every
    /// element was integral, so `sum` of `[1, 2, 3]` logs as `6`
    /// rather than `6.0`.
    private static func opSum(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        if input is AnyStreamingValue { throw NeedsAsyncExecution() }
        let items = elements(input)
        guard !items.isEmpty else { return 0 }
        var total = 0.0
        var allIntegral = true
        for item in items {
            guard let value = numeric(item) else {
                throw ActionError.typeMismatch(
                    expected: "Number",
                    actual: String(describing: type(of: item)),
                    variable: "sum")
            }
            if !(item is Int) { allIntegral = false }
            total += value
        }
        return allIntegral ? Int(total) : total
    }

    /// Arithmetic mean. Always a `Double` — averaging integers rarely
    /// gives an integer, and silently truncating would be worse than
    /// a decimal point.
    private static func opAverage(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        if input is AnyStreamingValue { throw NeedsAsyncExecution() }
        let items = elements(input)
        guard !items.isEmpty else {
            throw ActionError.validationFailed("avg of an empty collection is undefined")
        }
        var total = 0.0
        for item in items {
            guard let value = numeric(item) else {
                throw ActionError.typeMismatch(
                    expected: "Number",
                    actual: String(describing: type(of: item)),
                    variable: "avg")
            }
            total += value
        }
        return total / Double(items.count)
    }

    /// Duplicates removed, first occurrence wins so the original
    /// order survives. On a string this dedupes characters.
    private static func opUnique(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        if input is AnyStreamingValue { throw NeedsAsyncExecution() }
        if let str = input as? String {
            var seen = Set<Character>()
            return String(str.filter { seen.insert($0).inserted })
        }
        guard let items = input as? [any Sendable] else { return input }
        var seen = Set<String>()
        var out: [any Sendable] = []
        for item in items {
            // Key on the rendered form: the element type is `any
            // Sendable`, which is not Hashable, and every value the
            // runtime carries renders stably.
            let key = identityKey(item)
            if seen.insert(key).inserted { out.append(item) }
        }
        return out
    }

    /// Stable string key for an arbitrary runtime value.
    private static func identityKey(_ value: any Sendable) -> String {
        if let str = value as? String { return "s:\(str)" }
        if let int = value as? Int { return "n:\(Double(int))" }
        if let dbl = value as? Double { return "n:\(dbl)" }
        if let bool = value as? Bool { return "b:\(bool)" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value,
                                                  options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return "j:\(json)"
        }
        return "d:\(String(describing: value))"
    }

    /// The lines of a text, as a list.
    ///
    /// The trailing newline does *not* produce a phantom empty last
    /// element — that subtlety is exactly what made the hand-rolled
    /// `trim` → `Split` → `length` idiom easy to get wrong (it
    /// answers 4 for a 3-line file if you forget the trim). Counting
    /// lines is `lines` then `length`.
    ///
    /// `\r\n` is treated as one terminator, so a CRLF file counts the
    /// same as a LF one and no line comes back with a stray `\r`.
    ///
    /// The split is over `Character`s, not over the `"\n"` substring.
    /// Swift treats `\r\n` as a single grapheme cluster, and
    /// `components(separatedBy: "\n")` is grapheme-aware on
    /// swift-corelibs-foundation — it finds no separator at all inside
    /// a CRLF document and hands back the whole text as one line. On
    /// Darwin the same call bridges to NSString and splits on UTF-16
    /// units, so it does the expected thing. That divergence is why
    /// this passed locally and failed on the Linux runner.
    /// `Character.isNewline` matches `\n`, `\r`, `\r\n` and the
    /// Unicode line/paragraph separators identically on both.
    private static func opLines(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        let text = asText(input)
        guard !text.isEmpty else { return [any Sendable]() }
        var lines = text.split(omittingEmptySubsequences: false,
                               whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0 as any Sendable }
    }

    /// Collection → string. `with { separator: ", " }` interleaves;
    /// without it the elements are concatenated.
    private static func opJoin(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        if input is AnyStreamingValue { throw NeedsAsyncExecution() }
        var separator = ""
        if let config = context.resolveAny("_with_") as? [String: any Sendable],
           let value = config["separator"] as? String {
            separator = value
        } else if let value = context.resolveAny("_with_") as? String {
            // `with ", "` — the bare form reads fine for a single
            // obvious parameter, so accept it too.
            separator = value
        }
        return elements(input).map { asText($0) }.joined(separator: separator)
    }

    /// One element picked at random.
    ///
    /// On a collection: a random element. On a whole number `n`: a
    /// random integer in `0..<n`, which is what "random" means when
    /// there is nothing to pick *from*. Empty collections have no
    /// element to return, so they are an error rather than a silent
    /// nil.
    private static func opRandom(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        if input is AnyStreamingValue { throw NeedsAsyncExecution() }
        if let items = input as? [any Sendable] {
            guard let pick = items.randomElement() else {
                throw ActionError.validationFailed("random of an empty collection")
            }
            return pick
        }
        if let str = input as? String {
            guard let pick = str.randomElement() else {
                throw ActionError.validationFailed("random of an empty string")
            }
            return String(pick)
        }
        if let bound = input as? Int {
            guard bound > 0 else {
                throw ActionError.validationFailed("random requires a positive bound")
            }
            return Int.random(in: 0..<bound)
        }
        if let bound = input as? Double, bound > 0 {
            return Double.random(in: 0..<bound)
        }
        throw ActionError.typeMismatch(
            expected: "List, String, or positive Number",
            actual: String(describing: type(of: input)),
            variable: "random")
    }

    private static func opClip(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        let str = input as? String ?? String(describing: input)
        var width = 80
        if let w = context.resolveAny("_with_") as? Int { width = w }
        else if let w = context.resolveAny("_with_") as? Double { width = Int(w) }
        if str.count <= width { return str }
        return String(str.prefix(width))
    }

    private static func opTake(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        var n = 0
        if let w = context.resolveAny("_with_") as? Int { n = w }
        else if let w = context.resolveAny("_with_") as? Double { n = Int(w) }
        if let arr = input as? [any Sendable] { return Array(arr.prefix(n)) }
        if let str = input as? String { return String(str.prefix(n)) }
        return input
    }

    private static func opDate(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        if let str = input as? String { return try ARODate.parse(str) }
        if let date = input as? ARODate { return date }
        throw ActionError.typeMismatch(expected: "String (ISO 8601)", actual: String(describing: type(of: input)))
    }

    private static func opFormat(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        // ComputeAction is a stateless `struct`, so a fresh instance
        // is essentially free and lets the existing instance helpers
        // (`getARODate`, `computeIntersect`, …) stay where they are.
        guard let date = ComputeAction().getARODate(from: input) else {
            throw ActionError.typeMismatch(expected: "ARODate or ISO 8601 String", actual: String(describing: type(of: input)))
        }
        let pattern = context.resolveAny("_expression_") as? String ?? DateFormatPattern.fullDate
        let dateService = context.service(DateService.self) ?? DefaultDateService()
        return dateService.format(date, pattern: pattern)
    }

    private static func opDistance(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        let helper = ComputeAction()
        guard let fromDate = helper.getARODate(from: input) else {
            throw ActionError.typeMismatch(expected: "ARODate", actual: String(describing: type(of: input)))
        }
        guard let toValue = context.resolveAny("_to_"),
              let toDate = helper.getARODate(from: toValue) else {
            throw ActionError.missingRequiredField(field: "a 'to' clause", action: "Compute distance")
        }
        let dateService = context.service(DateService.self) ?? DefaultDateService()
        return dateService.distance(from: fromDate, to: toDate)
    }

    private static func opIntersect(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        guard let secondOperand = context.resolveAny("_with_") else {
            throw ActionError.missingRequiredField(field: "a 'with' clause", action: "Compute intersect")
        }
        return try ComputeAction().computeIntersect(input, with: secondOperand)
    }

    private static func opDifference(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        guard let secondOperand = context.resolveAny("_with_") else {
            throw ActionError.missingRequiredField(field: "a 'with' clause", action: "Compute difference")
        }
        return try ComputeAction().computeDifference(input, minus: secondOperand)
    }

    private static func opUnion(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        guard let secondOperand = context.resolveAny("_with_") else {
            throw ActionError.missingRequiredField(field: "a 'with' clause", action: "Compute union")
        }
        return try ComputeAction().computeUnion(input, with: secondOperand)
    }

    /// Built-in markdown → HTML so apps don't need a plugin for
    /// routine CMS-style content. Subset is intentionally small
    /// (ATX headings, paragraphs, fenced code, **bold**, *italic*,
    /// `code`, [text](url)); plug a richer renderer in via a Swift
    /// / Rust plugin if you outgrow it.
    private static func opMarkdown(_ input: any Sendable, _ context: ExecutionContext) throws -> any Sendable {
        let md = input as? String ?? String(describing: input)
        return MinimalMarkdown.toHTML(md)
    }

    // MARK: - Async path (handles computeService plugins and streaming inputs)

    /// Override the default `SynchronousAction.execute` to handle the two cases
    /// that genuinely need `await`: plugin compute services and streaming count.
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        do {
            return try executeSynchronously(result: result, object: object, context: context)
        } catch is NeedsAsyncExecution {
            // Fall through to async-only paths
        }

        try validatePreposition(object.preposition)
        guard let input = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }
        // ARO-0051: Streaming count — materialize and rebind
        if let anyStreaming = input as? AnyStreamingValue {
            let materialized = try await anyStreaming.materialize()
            context.bind(object.base, value: materialized, allowRebind: true)
            return materialized.count
        }

        return input
    }

    /// Get an ARODate from various input types
    private func getARODate(from input: any Sendable) -> ARODate? {
        if let date = input as? ARODate {
            return date
        }
        if let str = input as? String {
            return try? ARODate.parse(str)
        }
        return nil
    }

    /// Compute a date offset (e.g., +1h, -3d from a date)
    private func computeDateOffset(input: any Sendable, offsetPattern: String, context: ExecutionContext) throws -> ARODate {
        guard let date = getARODate(from: input) else {
            throw ActionError.typeMismatch(expected: "ARODate or ISO 8601 String", actual: String(describing: type(of: input)))
        }

        let offset = try DateOffset.parse(offsetPattern)
        let dateService = context.service(DateService.self) ?? DefaultDateService()
        return dateService.offset(date, by: offset)
    }

    // MARK: - Set Operations (ARO-0042)

    /// Compute intersection of two collections (multiset semantics for arrays)
    /// - Lists: Elements in both, preserving duplicates up to minimum count
    /// - Strings: Characters in both, preserving order from first string
    /// - Objects: Keys with matching values (deep recursive)
    private func computeIntersect(_ a: any Sendable, with b: any Sendable) throws -> any Sendable {
        // Arrays - multiset intersection
        if let arrA = a as? [any Sendable], let arrB = b as? [any Sendable] {
            return multisetIntersect(arrA, arrB)
        }

        // Strings - character intersection preserving order
        if let strA = a as? String, let strB = b as? String {
            var bCounts = characterCounts(strB)
            var result = ""
            for char in strA {
                if let count = bCounts[char], count > 0 {
                    result.append(char)
                    bCounts[char] = count - 1
                }
            }
            return result
        }

        // Dictionaries - deep recursive intersection
        if let dictA = a as? [String: any Sendable],
           let dictB = b as? [String: any Sendable] {
            return intersectDictionaries(dictA, dictB)
        }

        throw ActionError.typeMismatch(
            expected: "Array, String, or Object",
            actual: String(describing: type(of: a))
        )
    }

    /// Compute difference of two collections (A - B, multiset semantics for arrays)
    /// - Lists: Elements in A but not in B, with multiset subtraction
    /// - Strings: Characters in A but not in B, preserving order
    /// - Objects: Keys/values in A that are not matching in B
    private func computeDifference(_ a: any Sendable, minus b: any Sendable) throws -> any Sendable {
        // Arrays - multiset difference
        if let arrA = a as? [any Sendable], let arrB = b as? [any Sendable] {
            return multisetDifference(arrA, arrB)
        }

        // Strings - character difference preserving order
        if let strA = a as? String, let strB = b as? String {
            var bCounts = characterCounts(strB)
            var result = ""
            for char in strA {
                if let count = bCounts[char], count > 0 {
                    bCounts[char] = count - 1
                } else {
                    result.append(char)
                }
            }
            return result
        }

        // Dictionaries - deep recursive difference
        if let dictA = a as? [String: any Sendable],
           let dictB = b as? [String: any Sendable] {
            return differenceDictionaries(dictA, dictB)
        }

        throw ActionError.typeMismatch(
            expected: "Array, String, or Object",
            actual: String(describing: type(of: a))
        )
    }

    /// Compute union of two collections (deduplicated for arrays)
    /// - Lists: All unique elements from both (A wins for duplicates)
    /// - Strings: All unique characters from both, preserving order from A
    /// - Objects: Merge keys (A wins for conflicts)
    private func computeUnion(_ a: any Sendable, with b: any Sendable) throws -> any Sendable {
        // Arrays - deduplicated union
        if let arrA = a as? [any Sendable], let arrB = b as? [any Sendable] {
            var result = arrA
            var seen = Set(arrA.map { hashKey(for: $0) })
            for item in arrB {
                let key = hashKey(for: item)
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(item)
                }
            }
            return result
        }

        // Strings - character union (preserves A, adds unique chars from B)
        // Consistent with list union: start with A, add chars from B not in A's set
        if let strA = a as? String, let strB = b as? String {
            var seen = Set(strA)  // Characters already in A
            var result = strA     // Start with all of A (including duplicates)

            // Add characters from B that aren't in A's character set
            for char in strB {
                if !seen.contains(char) {
                    seen.insert(char)
                    result.append(char)
                }
            }
            return result
        }

        // Dictionaries - merge with A winning conflicts
        // Start with B's keys, then overwrite with all of A's keys (A wins)
        if let dictA = a as? [String: any Sendable],
           let dictB = b as? [String: any Sendable] {
            var result = dictB
            for (key, value) in dictA {
                result[key] = value
            }
            return result
        }

        throw ActionError.typeMismatch(
            expected: "Array, String, or Object",
            actual: String(describing: type(of: a))
        )
    }

    // MARK: - Set Operation Helpers

    /// Multiset intersection: elements in both, preserving duplicates up to min count
    private func multisetIntersect(_ a: [any Sendable], _ b: [any Sendable]) -> [any Sendable] {
        var bCounts: [String: Int] = [:]
        for item in b {
            let key = hashKey(for: item)
            bCounts[key, default: 0] += 1
        }

        var result: [any Sendable] = []
        for item in a {
            let key = hashKey(for: item)
            if let count = bCounts[key], count > 0 {
                result.append(item)
                bCounts[key] = count - 1
            }
        }
        return result
    }

    /// Multiset difference: elements in A minus occurrences in B
    private func multisetDifference(_ a: [any Sendable], _ b: [any Sendable]) -> [any Sendable] {
        var bCounts: [String: Int] = [:]
        for item in b {
            let key = hashKey(for: item)
            bCounts[key, default: 0] += 1
        }

        var result: [any Sendable] = []
        for item in a {
            let key = hashKey(for: item)
            if let count = bCounts[key], count > 0 {
                bCounts[key] = count - 1
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// Deep recursive dictionary intersection
    private func intersectDictionaries(
        _ a: [String: any Sendable],
        _ b: [String: any Sendable]
    ) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, valueA) in a {
            guard let valueB = b[key] else { continue }

            // Recursive for nested objects
            if let nestedA = valueA as? [String: any Sendable],
               let nestedB = valueB as? [String: any Sendable] {
                let nested = intersectDictionaries(nestedA, nestedB)
                if !nested.isEmpty {
                    result[key] = nested
                }
            }
            // Arrays within objects
            else if let arrA = valueA as? [any Sendable],
                    let arrB = valueB as? [any Sendable] {
                let intersected = multisetIntersect(arrA, arrB)
                if !intersected.isEmpty {
                    result[key] = intersected
                }
            }
            // Primitive equality
            else if areStrictlyEqual(valueA, valueB) {
                result[key] = valueA
            }
        }
        return result
    }

    /// Deep recursive dictionary difference
    private func differenceDictionaries(
        _ a: [String: any Sendable],
        _ b: [String: any Sendable]
    ) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, valueA) in a {
            guard let valueB = b[key] else {
                // Key not in B - include it
                result[key] = valueA
                continue
            }

            // Recursive for nested objects
            if let nestedA = valueA as? [String: any Sendable],
               let nestedB = valueB as? [String: any Sendable] {
                let diff = differenceDictionaries(nestedA, nestedB)
                if !diff.isEmpty {
                    result[key] = diff
                }
            }
            // Arrays within objects
            else if let arrA = valueA as? [any Sendable],
                    let arrB = valueB as? [any Sendable] {
                let diffArr = multisetDifference(arrA, arrB)
                if !diffArr.isEmpty {
                    result[key] = diffArr
                }
            }
            // Values differ - include A's value
            else if !areStrictlyEqual(valueA, valueB) {
                result[key] = valueA
            }
        }
        return result
    }

    /// Count occurrences of each character in a string
    private func characterCounts(_ str: String) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for char in str {
            counts[char, default: 0] += 1
        }
        return counts
    }

    /// Create a hash key for any Sendable value (for multiset counting)
    private func hashKey(for value: any Sendable) -> String {
        if let dict = value as? [String: any Sendable] {
            // Sort keys for consistent hashing
            let sorted = dict.keys.sorted().map { key -> String in
                let v = dict[key]!
                return "\(key):\(hashKey(for: v))"
            }
            return "{\(sorted.joined(separator: ","))}"
        }
        if let arr = value as? [any Sendable] {
            return "[\(arr.map { hashKey(for: $0) }.joined(separator: ","))]"
        }
        return String(describing: value)
    }

    /// Strict equality check for two values
    private func areStrictlyEqual(_ a: any Sendable, _ b: any Sendable) -> Bool {
        // Same type checks
        if let aInt = a as? Int, let bInt = b as? Int {
            return aInt == bInt
        }
        if let aDouble = a as? Double, let bDouble = b as? Double {
            return aDouble == bDouble
        }
        if let aStr = a as? String, let bStr = b as? String {
            return aStr == bStr
        }
        if let aBool = a as? Bool, let bBool = b as? Bool {
            return aBool == bBool
        }
        if let aDict = a as? [String: any Sendable],
           let bDict = b as? [String: any Sendable] {
            guard aDict.count == bDict.count else { return false }
            for (key, valueA) in aDict {
                guard let valueB = bDict[key] else { return false }
                if !areStrictlyEqual(valueA, valueB) { return false }
            }
            return true
        }
        if let aArr = a as? [any Sendable], let bArr = b as? [any Sendable] {
            guard aArr.count == bArr.count else { return false }
            for (itemA, itemB) in zip(aArr, bArr) {
                if !areStrictlyEqual(itemA, itemB) { return false }
            }
            return true
        }
        // Fallback to string comparison
        return String(describing: a) == String(describing: b)
    }
}

/// Validates input against rules
public struct ValidateAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["validate", "verify", "check"]
    public static let validPrepositions: Set<Preposition> = [.for, .against, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get value to validate
        guard let value = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Validation rule from result specifiers or base (for backward compatibility)
        let knownRules: Set<String> = ["required", "exists", "nonempty", "email", "numeric"]
        let ruleName = resolveOperationName(from: result, knownOperations: knownRules, fallback: "required")

        // Built-in validations
        let isValid: Bool
        switch ruleName.lowercased() {
        case "required", "exists":
            isValid = !isNilOrEmpty(value)

        case "nonempty":
            if let str = value as? String {
                isValid = !str.isEmpty
            } else if let arr = value as? [Any] {
                isValid = !arr.isEmpty
            } else {
                isValid = true
            }

        case "email":
            if let str = value as? String {
                isValid = str.contains("@") && str.contains(".")
            } else {
                isValid = false
            }

        case "numeric":
            if value is Int || value is Double || value is Float {
                isValid = true
            } else if let str = value as? String {
                isValid = Double(str) != nil
            } else {
                isValid = false
            }

        default:
            // Unknown rule - assume valid
            isValid = true
        }

        return ValidationResult(isValid: isValid, rule: ruleName)
    }

    private func isNilOrEmpty(_ value: Any) -> Bool {
        // Note: value is Any, so it can't be nil - check for NSNull instead
        if value is NSNull {
            return true
        }
        if let str = value as? String, str.isEmpty {
            return true
        }
        if let arr = value as? [Any], arr.isEmpty {
            return true
        }
        return false
    }
}

/// Compares two values
public struct CompareAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["compare", "match"]
    // `from` is the operand slot in the #469 shape; `against` stays
    // valid so the old spelling still parses and gets a message
    // that names the new one rather than a rebind error.
    public static let validPrepositions: Set<Preposition> = [.from, .against, .with, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // `Compare the <same> from the <a> against the <b>.`
        // (GitLab #469). The old shape read its left operand out of
        // the *result* slot, so the statement both read and wrote
        // the same immutable binding and every documented example
        // died on "Cannot rebind variable 'a'" before it ever ran.
        //
        // Operands are now both inputs and the result is a fresh
        // binding, which is the only shape immutability allows.
        guard let lhs = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        guard let rhs = context.resolveAny("_against_") else {
            throw ActionError.missingRequiredField(
                "against <value> — Compare takes both operands as inputs: "
                + "`Compare the <\(result.base)> from the <\(object.base)> "
                + "against the <other>.`")
        }

        let outcome = compare(lhs, rhs)

        // A dictionary rather than an opaque struct so the outcome
        // is actually readable: `<same: matches>` / `<same: result>`.
        // Nothing in the codebase consumed the old `ComparisonResult`
        // — there was no way to get at it.
        let value: [String: any Sendable] = [
            "matches": outcome == .equal,
            "result": outcome.rawValue,
        ]
        context.bind(result.base, value: value)
        return value
    }

    private func compare(_ lhs: Any, _ rhs: Any) -> ComparisonOutcome {
        // String comparison
        if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
            if lhsStr == rhsStr { return .equal }
            if lhsStr < rhsStr { return .less }
            return .greater
        }

        // Numeric comparison
        if let lhsNum = asDouble(lhs), let rhsNum = asDouble(rhs) {
            if lhsNum == rhsNum { return .equal }
            if lhsNum < rhsNum { return .less }
            return .greater
        }

        // Bool comparison
        if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool {
            return lhsBool == rhsBool ? .equal : .notEqual
        }

        // Fallback to string representation
        let lhsDesc = String(describing: lhs)
        let rhsDesc = String(describing: rhs)
        return lhsDesc == rhsDesc ? .equal : .notEqual
    }

    private func asDouble(_ value: Any) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let f = value as? Float { return Double(f) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

/// Transforms a value or renders a template (ARO-0050)
public struct TransformAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["transform", "convert", "map"]
    public static let validPrepositions: Set<Preposition> = [.from, .into, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // ARO-0050: Check for template rendering
        // Syntax: <Transform> the <result> from the <template: path>.
        if object.base.lowercased() == "template" {
            return try await renderTemplate(object: object, result: result, context: context)
        }

        // Get value to transform
        guard let value = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Transformation type from result specifiers or base (for backward compatibility)
        let knownTransforms: Set<String> = ["string", "int", "integer", "double", "float", "bool", "boolean", "json", "identity"]
        let transformType = resolveOperationName(from: result, knownOperations: knownTransforms, fallback: "identity")

        switch transformType.lowercased() {
        case "string":
            return String(describing: value)

        case "int", "integer":
            if let i = value as? Int { return i }
            if let d = value as? Double { return Int(d) }
            if let s = value as? String, let i = Int(s) { return i }
            throw ActionError.typeMismatch(expected: "Int", actual: String(describing: type(of: value)))

        case "double", "float":
            if let d = value as? Double { return d }
            if let i = value as? Int { return Double(i) }
            if let s = value as? String, let d = Double(s) { return d }
            throw ActionError.typeMismatch(expected: "Double", actual: String(describing: type(of: value)))

        case "bool", "boolean":
            if let b = value as? Bool { return b }
            if let s = value as? String { return s.lowercased() == "true" || s == "1" }
            if let i = value as? Int { return i != 0 }
            return false

        case "json":
            if let dict = value as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: dict)
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            return "{}"

        case "identity":
            // value is already `any Sendable`
            return value

        default:
            // value is already `any Sendable`
            return value
        }
    }

    /// Render a template (ARO-0050) and track variable positions for reactive updates
    private func renderTemplate(
        object: ObjectDescriptor,
        result: ResultDescriptor,
        context: ExecutionContext
    ) async throws -> String {
        // Get template path from specifiers
        // Specifiers are split by ':' and '.', so "foo.tpl" becomes ["foo", "tpl"]
        // and "emails/welcome.tpl" becomes ["emails/welcome", "tpl"]
        // We join with '.' to reconstruct the original path with extension
        guard !object.specifiers.isEmpty else {
            throw ActionError.missingRequiredField(field: "a template path", action: "Render")
        }

        // Join specifiers with '.' to reconstruct path with extension
        let rawPath = object.specifiers.joined(separator: ".")

        // Check if this is a variable reference that should be resolved
        let templatePath: String
        if object.specifiers.count == 1, let resolved: String = context.resolve(object.specifiers[0]) {
            templatePath = resolved
        } else {
            templatePath = rawPath
        }

        // Get template service
        guard let templateService = context.service(TemplateService.self) else {
            throw ActionError.missingService("TemplateService not registered. Templates require the template service to be configured.")
        }

        // Render with position tracking for reactive Repaint action
        let (rendered, positions) = try await templateService.renderAndTrack(path: templatePath, context: context)

        // Store positions under "_positions_<resultName>_" for RenderAction to pick up
        if !positions.isEmpty {
            context.bind("_positions_\(result.base)_", value: positions, allowRebind: true)
        }

        return rendered
    }
}

/// Creates a new entity
public struct CreateAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["create", "build", "construct"]
    public static let validPrepositions: Set<Preposition> = [.with, .from, .for, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Check for special types in result.specifiers (ARO-0041)
        if let typeSpecifier = result.specifiers.first?.lowercased() {
            switch typeSpecifier {
            case "date-range", "daterange":
                return try createDateRange(object: object, context: context)

            case "recurrence":
                return try createRecurrence(object: object, context: context)

            default:
                break  // Fall through to regular entity creation
            }
        }

        // Get the source value - check _expression_ first (binary mode), then _literal_, then object.base
        // In binary mode, variable references in expressions are resolved and bound to _expression_
        // In interpreter mode, variables may be directly resolvable via object.base
        let sourceValue: (any Sendable)?
        if let expr = context.resolveAny("_expression_") {
            sourceValue = expr
        } else if let literal = context.resolveAny("_literal_") {
            sourceValue = literal
        } else {
            sourceValue = context.resolveAny(object.base)
        }

        if let value = sourceValue {
            // Check if we're creating a typed entity (e.g., <order: Order>)
            // In this case, we should generate an ID if not present
            if !result.specifiers.isEmpty {
                // Creating a typed entity - ensure it has an ID
                if var dict = value as? [String: any Sendable] {
                    if dict["id"] == nil {
                        dict["id"] = generateEntityId()
                    }
                    return dict
                }
            }
            // Return the actual value directly - this gets bound to result.base
            // by the FeatureSetExecutor
            return value
        }

        // If no source found, return empty string as default
        return ""
    }

    /// Generate a unique entity ID
    private func generateEntityId() -> String {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        let random = UInt32.random(in: 0..<UInt32.max)
        return String(format: "%llx%08x", timestamp, random)
    }

    /// Create a date range from start to end (ARO-0041)
    /// Syntax: <Create> the <range: date-range> from <start> to <end>.
    private func createDateRange(object: ObjectDescriptor, context: ExecutionContext) throws -> ARODateRange {
        // Get start date from object.base (the 'from' clause)
        guard let startValue = context.resolveAny(object.base),
              let startDate = getARODate(from: startValue) else {
            throw ActionError.typeMismatch(expected: "ARODate (start)", actual: object.base)
        }

        // Get end date from _to_ (the 'to' clause)
        // Debug: Log _to_ resolution for ARO-0041 diagnostics (enable with ARO_DEBUG=1)
        let endValue = context.resolveAny("_to_")
        if endValue == nil && ProcessInfo.processInfo.environment["ARO_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[CreateAction] DEBUG: _to_ is nil - date range 'to' clause not bound\n".utf8))
        }
        guard let endValue, let endDate = getARODate(from: endValue) else {
            throw ActionError.missingRequiredField(field: "a 'to' clause", action: "Create date-range")
        }

        let dateService = context.service(DateService.self) ?? DefaultDateService()
        return dateService.createRange(from: startDate, to: endDate)
    }

    /// Create a recurrence pattern (ARO-0041)
    /// Syntax: <Create> the <schedule: recurrence> with "every monday".
    private func createRecurrence(object: ObjectDescriptor, context: ExecutionContext) throws -> ARORecurrence {
        // Get pattern from _expression_ (the 'with' clause) or object.base
        let pattern: String
        if let expr = context.resolveAny("_expression_") as? String {
            pattern = expr
        } else if let literal = context.resolveAny("_literal_") as? String {
            pattern = literal
        } else if let resolved = context.resolveAny(object.base) as? String {
            pattern = resolved
        } else {
            pattern = object.base
        }

        // Get optional start date from _from_ clause
        let startDate: ARODate?
        if let fromValue = context.resolveAny("_from_") {
            startDate = getARODate(from: fromValue)
        } else {
            startDate = nil
        }

        let dateService = context.service(DateService.self) ?? DefaultDateService()
        return try dateService.createRecurrence(pattern: pattern, from: startDate)
    }

    /// Get an ARODate from various input types
    private func getARODate(from input: any Sendable) -> ARODate? {
        if let date = input as? ARODate {
            return date
        }
        if let str = input as? String {
            return try? ARODate.parse(str)
        }
        return nil
    }
}

/// Updates an existing entity
public struct UpdateAction: SynchronousAction {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["update", "modify", "change", "set", "configure"]
    public static let validPrepositions: Set<Preposition> = [.with, .to, .for, .from]

    public init() {}

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Repository configuration path needs async — fall back to Task path
        if InMemoryRepositoryStorage.isRepositoryName(result.base), result.specifiers.first != nil {
            throw NeedsAsyncExecution()
        }

        // For "configure" verb, allow creating new configuration if it doesn't exist
        // This enables: <Configure> the <validation: timeout> with <value>.
        let entity: any Sendable
        if let existingEntity = context.resolveAny(result.base) {
            entity = existingEntity
        } else {
            // Create empty dictionary for new configuration
            entity = [String: any Sendable]()
        }

        // Get update value - check _literal_ first (for "draft"), then resolve from object
        let updateValue: any Sendable
        if let literal = context.resolveAny("_literal_") {
            updateValue = literal
        } else if let resolved = context.resolveAny(object.base) {
            // If object has specifiers, extract the nested property
            if !object.specifiers.isEmpty {
                if let dict = resolved as? [String: any Sendable] {
                    // Extract nested property from the source object
                    var current: any Sendable = dict
                    for specifier in object.specifiers {
                        if let currentDict = current as? [String: any Sendable],
                           let nested = currentDict[specifier] {
                            current = nested
                        } else {
                            throw ActionError.propertyNotFound(property: specifier, on: object.base)
                        }
                    }
                    updateValue = current
                } else {
                    throw ActionError.propertyNotFound(property: object.specifiers.first ?? "", on: object.base)
                }
            } else {
                updateValue = resolved
            }
        } else {
            // Treat as literal value
            updateValue = object.base
        }

        // Check if we're updating a specific field (e.g., <order: status>)
        if let fieldName = result.specifiers.first {
            // Update specific field in the entity
            var updatedEntity: [String: any Sendable]

            if let dict = entity as? [String: any Sendable] {
                updatedEntity = dict
            } else if let dict = entity as? [String: Any] {
                // Convert to Sendable dictionary
                updatedEntity = [:]
                for (key, value) in dict {
                    updatedEntity[key] = convertToSendable(value)
                }
            } else {
                // Create dictionary from entity using reflection
                updatedEntity = [:]
                let mirror = Mirror(reflecting: entity)
                for child in mirror.children {
                    if let label = child.label {
                        updatedEntity[label] = convertToSendable(child.value)
                    }
                }
            }

            // Update the field
            updatedEntity[fieldName] = updateValue

            // Bind the updated entity with allowRebind: true
            // Update action is allowed to rebind for state transitions
            context.bind(result.base, value: updatedEntity, allowRebind: true)
            return updatedEntity
        }

        // No field specifier - merge updates into entity or replace
        if let entityDict = entity as? [String: any Sendable],
           let updateDict = updateValue as? [String: any Sendable] {
            var merged = entityDict
            for (key, value) in updateDict {
                merged[key] = value
            }
            context.bind(result.base, value: merged, allowRebind: true)
            return merged
        }

        // Fallback: return the update value
        return updateValue
    }

    /// Override to handle the repository-configuration path that needs `await`.
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        do {
            return try executeSynchronously(result: result, object: object, context: context)
        } catch is NeedsAsyncExecution {
            // Fall through to async repository-configuration path
        }

        // Repository configuration: Configure the <repo: ttl> with <value>.
        try validatePreposition(object.preposition)
        let entity: any Sendable = context.resolveAny(result.base) ?? [String: any Sendable]()

        let updateValue: any Sendable
        if let literal = context.resolveAny("_literal_") {
            updateValue = literal
        } else if let resolved = context.resolveAny(object.base) {
            updateValue = resolved
        } else {
            updateValue = object.base
        }

        guard let fieldName = result.specifiers.first else { return entity }
        let storage = context.service(RepositoryStorageService.self) ?? context.container.repositoryStorage

        var currentTTL: TimeInterval? = nil
        var currentMaxSize: Int? = nil
        if let existing = context.resolveAny(result.base) as? [String: any Sendable] {
            if let t = existing["ttl"] as? TimeInterval { currentTTL = t }
            else if let t = existing["ttl"] as? Double { currentTTL = t }
            else if let t = existing["ttl"] as? Int { currentTTL = TimeInterval(t) }
            if let m = existing["maxSize"] as? Int { currentMaxSize = m }
            else if let m = existing["maxSize"] as? Double { currentMaxSize = Int(m) }
        }
        switch fieldName {
        case "ttl":
            if let v = updateValue as? Double { currentTTL = v }
            else if let v = updateValue as? Int { currentTTL = TimeInterval(v) }
        case "maxSize":
            if let v = updateValue as? Int { currentMaxSize = v }
            else if let v = updateValue as? Double { currentMaxSize = Int(v) }
        default: break
        }
        await storage.configure(repository: result.base, ttl: currentTTL, maxSize: currentMaxSize)
        var configDict = context.resolveAny(result.base) as? [String: any Sendable] ?? [:]
        configDict[fieldName] = updateValue
        context.bind(result.base, value: configDict, allowRebind: true)
        return configDict
    }

    private func convertToSendable(_ value: Any) -> any Sendable {
        SendableConverter.fromJSON(value)
    }
}

// MARK: - Supporting Types

/// Result of a validation operation
public struct ValidationResult: Sendable, Equatable {
    public let isValid: Bool
    public let rule: String
    public let message: String?

    public init(isValid: Bool, rule: String, message: String? = nil) {
        self.isValid = isValid
        self.rule = rule
        self.message = message
    }
}

/// Result of a comparison operation
public struct ComparisonResult: Sendable, Equatable {
    public let matches: Bool
    public let result: ComparisonOutcome

    public init(matches: Bool, result: ComparisonOutcome) {
        self.matches = matches
        self.result = result
    }
}

/// Outcome of a comparison
public enum ComparisonOutcome: String, Sendable {
    case equal
    case notEqual
    case less
    case greater
}

/// Entity created by CreateAction
public struct CreatedEntity: Sendable {
    public let type: String
    public let data: [String: any Sendable]

    public init(type: String, data: [String: any Sendable]) {
        self.type = type
        self.data = data
    }
}

extension CreatedEntity: Equatable {
    public static func == (lhs: CreatedEntity, rhs: CreatedEntity) -> Bool {
        lhs.type == rhs.type
    }
}

// MARK: - Additional OWN Actions (ARO-0001)

// Note: FilterAction with ARO-0018 where clause support is now in QueryActions.swift

/// Sorts a collection
public struct SortAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["sort", "order", "arrange"]
    public static let validPrepositions: Set<Preposition> = [.for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get collection to sort
        guard let collection = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        // Sort order from result specifiers or base (for backward compatibility)
        let knownOrders: Set<String> = ["ascending", "descending"]
        let order = resolveOperationName(from: result, knownOperations: knownOrders, fallback: "ascending")
        let ascending = order.lowercased() != "descending"

        // `Array(...)` around the descending branch is load-bearing
        // (GitLab #466): `sorted().reversed()` is a lazy
        // `ReversedCollection`, and binding it meant `Log` printed
        // `ReversedCollection<Array<Int>>(_base: [1, 2, 3])` — a
        // Swift internal leaking into user-facing output where a
        // list belonged.
        if let array = collection as? [String] {
            return ascending ? array.sorted() : Array(array.sorted().reversed())
        }

        if let array = collection as? [Int] {
            return ascending ? array.sorted() : Array(array.sorted().reversed())
        }

        if let array = collection as? [Double] {
            return ascending ? array.sorted() : Array(array.sorted().reversed())
        }

        // A list built by ARO literal syntax arrives as
        // `[any Sendable]`, which none of the casts above match —
        // so the most common shape in real code was silently
        // returned unsorted. Sort it when the elements are
        // uniformly comparable.
        if let array = collection as? [any Sendable] {
            if let strings = array as? [String] {
                return ascending ? strings.sorted() : Array(strings.sorted().reversed())
            }
            if let ints = array.asHomogeneousInts() {
                let sorted = ints.sorted()
                return (ascending ? sorted : Array(sorted.reversed()))
                    .map { $0 as any Sendable }
            }
            if let doubles = array.asHomogeneousDoubles() {
                let sorted = doubles.sorted()
                return (ascending ? sorted : Array(sorted.reversed()))
                    .map { $0 as any Sendable }
            }
        }

        // Return original if not sortable
        return collection
    }
}

private extension Array where Element == any Sendable {
    /// The elements as Ints, or nil when any element isn't one.
    func asHomogeneousInts() -> [Int]? {
        var out: [Int] = []
        out.reserveCapacity(count)
        for element in self {
            guard let value = element as? Int else { return nil }
            out.append(value)
        }
        return out
    }

    /// The elements as Doubles, accepting Ints so a mixed numeric
    /// list still sorts rather than silently coming back untouched.
    func asHomogeneousDoubles() -> [Double]? {
        var out: [Double] = []
        out.reserveCapacity(count)
        for element in self {
            if let value = element as? Double { out.append(value) }
            else if let value = element as? Int { out.append(Double(value)) }
            else { return nil }
        }
        return out
    }
}

/// Reverses a collection or string (GitLab #466).
///
/// Distinct from `Sort … descending`, which the issue's repro
/// reached for as a substitute: sorting descending orders the
/// elements, reversing preserves the order they were in and flips
/// it. `[3, 1, 2]` reversed is `[2, 1, 3]`, not `[3, 2, 1]`.
public struct ReverseAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["reverse", "flip"]
    public static let validPrepositions: Set<Preposition> = [.for, .from, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        guard let value = context.resolveAny(object.base) else {
            throw ActionError.undefinedVariable(object.base)
        }

        let reversed: any Sendable
        if let text = value as? String {
            reversed = String(text.reversed())
        } else if let array = value as? [any Sendable] {
            reversed = Array(array.reversed())
        } else if let array = value as? [String] {
            reversed = Array(array.reversed())
        } else if let array = value as? [Int] {
            reversed = Array(array.reversed())
        } else if let array = value as? [Double] {
            reversed = Array(array.reversed())
        } else {
            throw ActionError.typeMismatch(
                expected: "List or String",
                actual: String(describing: type(of: value)))
        }

        context.bind(result.base, value: reversed)
        return reversed
    }
}

/// Merges two or more values into a NEW variable (immutable design)
///
/// The Merge action creates a new variable containing the merged result,
/// preserving ARO's immutability principle. The original variables remain unchanged.
///
/// ## Syntax
/// ```aro
/// (* Merge source into base, creating new variable 'result' *)
/// <Merge> the <result> from <base> with <source>.
///
/// (* Alternative: merge with preposition *)
/// <Merge> the <result> from <base> with <updates>.
/// ```
///
/// ## Examples
/// ```aro
/// (* Merge user data with updates *)
/// <Retrieve> the <existing-user> from the <user-repository> where id = <id>.
/// <Extract> the <updates> from the <request: body>.
/// <Merge> the <updated-user> from <existing-user> with <updates>.
/// <Store> the <updated-user> into the <user-repository>.
///
/// (* Merge arrays *)
/// <Merge> the <all-items> from <list-a> with <list-b>.
///
/// (* Merge strings *)
/// <Merge> the <full-name> from <first-name> with <last-name>.
/// ```
///
/// ## Merge Rules
/// - Dictionaries: Source keys overwrite base keys (shallow merge)
/// - Arrays: Source elements are appended to base
/// - Strings: Source is concatenated to base
public struct MergeAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["merge", "combine"]
    public static let validPrepositions: Set<Preposition> = [.with, .from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // New immutable design:
        // <Merge> the <result> from <base> with <source>.
        // - result.base = new variable name to create
        // - result.specifiers[0] = base variable (from clause)
        // - object.base = source variable (with clause)

        // Get base variable name from specifiers or object
        let baseName: String
        let sourceName: String

        if !result.specifiers.isEmpty {
            // New syntax: <Merge> the <result> from <base> with <source>.
            baseName = result.specifiers[0]
            sourceName = object.base
        } else if object.preposition == .from {
            // Alternative: <Merge> the <result> from <source>.
            // In this case, result is the target and object is the source
            // We need a base to merge into - check if result already exists
            if let existing = context.resolveAny(result.base) {
                // Merge source into existing result
                guard let source = context.resolveAny(object.base) else {
                    throw ActionError.undefinedVariable(object.base)
                }
                return mergeValues(base: existing, source: source, resultName: result.base, context: context)
            }
            throw ActionError.missingRequiredField(field: "a base value", action: "Merge")
        } else {
            // Legacy syntax: <Merge> the <target> with <source>.
            // For backwards compatibility, use result as both base and target
            baseName = result.base
            sourceName = object.base
        }

        // Get base value
        guard let base = context.resolveAny(baseName) else {
            throw ActionError.undefinedVariable(baseName)
        }

        // Get source value
        guard let source = context.resolveAny(sourceName) else {
            throw ActionError.undefinedVariable(sourceName)
        }

        // Perform merge and bind to NEW result variable
        return mergeValues(base: base, source: source, resultName: result.base, context: context)
    }

    private func mergeValues(
        base: any Sendable,
        source: any Sendable,
        resultName: String,
        context: ExecutionContext
    ) -> any Sendable {
        // Merge dictionaries (shallow merge, source overwrites base)
        if let baseDict = base as? [String: any Sendable],
           let sourceDict = source as? [String: any Sendable] {
            var merged = baseDict
            for (key, value) in sourceDict {
                merged[key] = value
            }
            // Bind to NEW variable (immutable design)
            context.bind(resultName, value: merged)
            return merged
        }

        // Merge arrays (append source to base)
        if let baseArray = base as? [any Sendable],
           let sourceArray = source as? [any Sendable] {
            var merged = baseArray
            merged.append(contentsOf: sourceArray)
            // Bind to NEW variable (immutable design)
            context.bind(resultName, value: merged)
            return merged
        }

        // Merge strings (concatenate)
        if let baseStr = base as? String,
           let sourceStr = source as? String {
            let merged = baseStr + sourceStr
            // Bind to NEW variable (immutable design)
            context.bind(resultName, value: merged)
            return merged
        }

        // Types don't match - return base unchanged
        context.bind(resultName, value: base)
        return base
    }
}

/// Deletes an entity or value
///
/// Supports deleting from:
/// - Dictionaries: removes the key
/// - Arrays: removes by index
/// - Repositories: removes items matching the where clause
///
/// ## Examples
/// ```
/// <Delete> the <key> from the <dictionary>.
/// <Delete> the <0> from the <array>.
/// <Delete> the <user> from the <user-repository> where id = <userId>.
/// ```
public struct DeleteAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["delete", "remove", "destroy", "clear"]
    public static let validPrepositions: Set<Preposition> = [.from, .for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        let targetName = object.base

        // Check if this is a repository (ends with -repository)
        if InMemoryRepositoryStorage.isRepositoryName(targetName) {
            return try await deleteFromRepository(
                result: result,
                repositoryName: targetName,
                context: context
            )
        }

        // Get the source containing the item to delete
        guard let source = context.resolveAny(targetName) else {
            throw ActionError.undefinedVariable(targetName)
        }

        // Key to delete from result specifiers
        let keyToDelete = result.specifiers.first ?? result.base

        // Delete from dictionary
        if var dict = source as? [String: any Sendable] {
            dict.removeValue(forKey: keyToDelete)
            return dict
        }

        // Delete from array by index (0 = most recent element)
        if var array = source as? [any Sendable], let index = Int(keyToDelete), index >= 0, index < array.count {
            array.remove(at: array.count - 1 - index)
            return array
        }

        // Emit delete event
        context.emit(DataDeletedEvent(target: result.base, source: targetName))

        return DeleteResult(target: result.base, success: true)
    }

    private func deleteFromRepository(
        result: ResultDescriptor,
        repositoryName: String,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Check for where clause (bound by FeatureSetExecutor)
        let whereField: String? = context.resolve("_where_field_")
        let whereValue = context.resolveAny("_where_value_")

        // If no where clause, clear the entire repository
        // This supports: <Clear> the <all> from the <message-repository>.
        if whereField == nil || whereValue == nil {
            if let storage = context.service(RepositoryStorageService.self) {
                await storage.clear(repository: repositoryName, businessActivity: context.businessActivity)
            } else {
                await context.container.repositoryStorage.clear(repository: repositoryName, businessActivity: context.businessActivity)
            }
            // Emit repository cleared event
            context.emit(RepositoryChangedEvent(
                repositoryName: repositoryName,
                changeType: .deleted,
                entityId: nil,
                newValue: nil,
                oldValue: nil
            ))
            return DeleteResult(target: result.base, success: true)
        }

        guard let field = whereField, let matchValue = whereValue else {
            throw ActionError.missingRequiredField(field: "a 'where' clause", action: "Delete from \(repositoryName)")
        }

        // Delete from repository storage service
        let deleteResult: RepositoryDeleteResult
        if let storage = context.service(RepositoryStorageService.self) {
            deleteResult = await storage.delete(
                from: repositoryName,
                businessActivity: context.businessActivity,
                where: field,
                equals: matchValue
            )
        } else {
            // Fallback to container storage
            deleteResult = await context.container.repositoryStorage.delete(
                from: repositoryName,
                businessActivity: context.businessActivity,
                where: field,
                equals: matchValue
            )
        }

        // Emit repository change events for each deleted item
        for deletedItem in deleteResult.deletedItems {
            let entityId: String?
            if let dict = deletedItem as? [String: any Sendable] {
                entityId = dict["id"] as? String
            } else {
                entityId = nil
            }

            context.emit(RepositoryChangedEvent(
                repositoryName: repositoryName,
                changeType: .deleted,
                entityId: entityId,
                newValue: nil,
                oldValue: deletedItem
            ))
        }

        // Emit legacy delete event
        context.emit(DataDeletedEvent(target: result.base, source: repositoryName))

        // Bind the deleted items to the result variable
        if deleteResult.deletedItems.count == 1 {
            context.bind(result.base, value: deleteResult.deletedItems[0])
        } else {
            context.bind(result.base, value: deleteResult.deletedItems)
        }

        return DeleteResult(target: result.base, success: deleteResult.count > 0)
    }
}

/// Result of a delete operation
public struct DeleteResult: Sendable, Equatable {
    public let target: String
    public let success: Bool
}

/// Event emitted when data is deleted
public struct DataDeletedEvent: RuntimeEvent {
    public static var eventType: String { "data.deleted" }
    public let timestamp: Date
    public let target: String
    public let source: String

    public init(target: String, source: String) {
        self.timestamp = Date()
        self.target = target
        self.source = source
    }
}
