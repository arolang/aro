// ============================================================
// BodyMaterialization.swift
// AROParser - Does this feature set read its request body? (GitLab #477)
// ============================================================
//
// Streams don't have a size. Values do.
//
// A feature set that only *moves* its request body — to a file, a
// socket, the response — never builds it in memory, so its size
// is bounded by the sink rather than by RAM. A feature set that
// *reads* it turns it into a value, and that is the only thing
// with a limit.
//
// Which of the two a route is, is a property of its source, so it
// is answered here rather than discovered under load. The server
// uses the answer to pick a body policy before it binds a port:
// a reading route buffers under its limit and refuses an
// oversized `Content-Length` at the request head; a moving route
// buffers nothing at all.
//
// The analysis is deliberately conservative. Anything it cannot
// see through — a plugin action, an unknown verb — counts as
// reading, because assuming the opposite is the assumption that
// loses memory.

import Foundation

// MARK: - Consumption classification

/// How an action consumes the value it is given.
public enum StreamConsumption: String, Sendable, Equatable {
    /// Needs the whole value: a field access, a parse, a fold.
    case wholeValue
    /// Consumes element by element and never holds the whole: a file write,
    /// a socket send, a chunked response.
    case elementWise
    /// Moves the binding without reading it.
    case passThrough
}

/// Which verbs can consume a value without building it in memory.
///
/// An allowlist with reasons, in the shape of `LazyActionPolicy.deferrableVerbs`
/// (ARO-0088) and for the same reason: semantic role is too coarse to decide
/// this. `Log` and `Write` are both EXPORT actions, but one renders a value for
/// a human — which needs the value — and the other copies bytes to a file,
/// which does not.
public enum StreamConsumptionPolicy {

    /// Verbs that consume element by element.
    ///
    /// Deliberately absent, with reasons:
    ///   - `log` — renders a value for a human to read. A four-gigabyte render
    ///     is not a log line, and the bounded error that says so is more useful
    ///     than a terminal full of chunks. `for each` is the streaming spelling.
    ///   - `store` — a repository holds values that can be queried later; a
    ///     stream cannot be queried, and it is gone once read.
    ///   - `compute`, `validate`, `compare`, `transform` — every one of them
    ///     looks inside. Some qualifiers (`length`, `sum`, `sha256`) are folds
    ///     that could stream; that is a later refinement, not a default.
    public static let elementWiseVerbs: Set<String> = [
        "write", "append", "send", "return", "broadcast", "respond",
        // `emit` and `publish` hand the value to something that outlives the
        // statement, so the runtime anchors it — drains it to a file one chunk
        // at a time and passes on something any number of readers can open.
        // That consumes element by element too, so the route still needs no
        // buffer; what it needs is disk, which is the sink's business.
        "emit", "publish",
    ]

    /// Verbs that move a binding without reading it. `extract` qualifies only
    /// when it names no field — see `AROStatement.readsWholeValue`.
    public static let passThroughVerbs: Set<String> = [
        "extract",
    ]

    /// Qualifiers that answer their question while the bytes go past, so
    /// `Compute the <d: sha256> from <upload>.` needs no more memory than a
    /// chunk (GitLab #477, #486).
    ///
    /// A fold sees the raw bytes, which on a route that never reads its body
    /// is all there is — hashing an upload hashes the upload. Collection folds
    /// (`sum`, `avg`, `join`) are deliberately absent: they are questions about
    /// records, and a body is bytes until something parses it.
    public static let foldingQualifiers: Set<String> = [
        "sha256", "hash",      // incremental digest
        "length", "count", "size",  // byte count
        "lines",               // lazily, one line at a time
    ]

    public static func consumption(ofVerb verb: String) -> StreamConsumption {
        let canonical = verb.lowercased()
        if elementWiseVerbs.contains(canonical) { return .elementWise }
        if passThroughVerbs.contains(canonical) { return .passThrough }
        return .wholeValue
    }

    /// Consumption for a statement whose result carries a qualifier.
    ///
    /// `Compute` normally needs the whole value; with a folding qualifier it
    /// does not, and that is the difference between a 4 GB upload you can hash
    /// and a 4 GB upload you cannot.
    public static func consumption(
        ofVerb verb: String,
        resultQualifiers: [String]
    ) -> StreamConsumption {
        let base = consumption(ofVerb: verb)
        guard base == .wholeValue else { return base }
        guard let qualifier = resultQualifiers.first?.lowercased() else { return base }
        // A chain (`lines|length`) folds only if every step does.
        let steps = qualifier.split(separator: "|").map(String.init)
        guard !steps.isEmpty, steps.allSatisfy({ foldingQualifiers.contains($0) }) else { return base }
        return .elementWise
    }
}

// MARK: - Result

/// What the analysis concluded about one feature set.
public struct BodyMaterialization: Sendable, Equatable {
    /// The feature set this describes.
    public let featureSet: String

    /// True when some statement needs the body as a value.
    public let materializes: Bool

    /// The statement that first needs it, for `aro check` and for the error
    /// message a limit produces. Nil when nothing does.
    public let statement: String?

    /// Line of that statement in its source file.
    public let line: Int?

    /// Full span of that statement, for tools that place something at it —
    /// the LSP's inlay hint sits at its end.
    public let span: SourceSpan?

    public init(
        featureSet: String,
        materializes: Bool,
        statement: String? = nil,
        line: Int? = nil,
        span: SourceSpan? = nil
    ) {
        self.featureSet = featureSet
        self.materializes = materializes
        self.statement = statement
        self.line = line
        self.span = span
    }

    /// A feature set that reads its body but whose source is unavailable.
    public static func conservative(_ name: String) -> BodyMaterialization {
        BodyMaterialization(featureSet: name, materializes: true, statement: nil, line: nil)
    }
}

// MARK: - Analyzer

/// Computes, per feature set, whether the request body is ever read as a value.
///
/// Taint analysis over the statement list: `<request: body>` is the source, the
/// pass-through verbs propagate it, and the first whole-value read of a tainted
/// binding is the answer. Calls to user-defined actions (ARO-0081) propagate to
/// the callee's own summary, computed to a fixpoint so mutual recursion
/// terminates.
public struct BodyMaterializationAnalyzer {

    /// System bindings that hold the request body.
    ///
    /// `Application` binds the parsed body under `body` as well as under
    /// `request.body`, and both spellings appear in real programs.
    private static let bodySources: Set<String> = ["request", "body"]

    public init() {}

    /// Analyze every feature set in a program.
    /// - Returns: summaries keyed by feature set name.
    public static func analyze(_ featureSets: [FeatureSet]) -> [String: BodyMaterialization] {
        let analyzer = BodyMaterializationAnalyzer()
        return analyzer.run(featureSets)
    }

    private func run(_ featureSets: [FeatureSet]) -> [String: BodyMaterialization] {
        let byName = Dictionary(featureSets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        // Which user-defined actions materialize the value passed to them.
        // Start optimistic and iterate: a cycle that never reads its input
        // settles at "does not materialize" instead of spinning.
        var actionMaterializes: [String: Bool] = [:]
        for featureSet in featureSets where featureSet.businessActivity == "Action" {
            actionMaterializes[featureSet.name] = false
        }

        var changed = true
        var rounds = 0
        while changed && rounds < byName.count + 2 {
            changed = false
            rounds += 1
            for (name, _) in actionMaterializes {
                guard let featureSet = byName[name] else { continue }
                let reads = readsItsInput(featureSet, actionMaterializes: actionMaterializes)
                if actionMaterializes[name] != reads {
                    actionMaterializes[name] = reads
                    changed = true
                }
            }
        }

        var results: [String: BodyMaterialization] = [:]
        for featureSet in featureSets {
            results[featureSet.name] = summarize(featureSet, actionMaterializes: actionMaterializes)
        }
        return results
    }

    // MARK: - Per feature set

    private func summarize(
        _ featureSet: FeatureSet,
        actionMaterializes: [String: Bool]
    ) -> BodyMaterialization {
        var tainted: Set<String> = []
        var seenBody = false

        if let finding = walk(
            featureSet.statements,
            tainted: &tainted,
            seenBody: &seenBody,
            actionMaterializes: actionMaterializes
        ) {
            return BodyMaterialization(
                featureSet: featureSet.name,
                materializes: true,
                statement: finding.statement,
                line: finding.line,
                span: finding.span
            )
        }

        // A feature set that never mentions the body doesn't stream it either;
        // it simply has no body. Reporting that as "streams" would tell the
        // server to skip a limit it should keep, so it counts as buffered —
        // the buffer is empty, and the default limit costs nothing.
        return BodyMaterialization(
            featureSet: featureSet.name,
            materializes: !seenBody,
            statement: nil,
            line: nil
        )
    }

    private struct Finding {
        let statement: String
        let line: Int
        let span: SourceSpan
    }

    private func walk(
        _ statements: [Statement],
        tainted: inout Set<String>,
        seenBody: inout Bool,
        actionMaterializes: [String: Bool]
    ) -> Finding? {
        for statement in statements {
            if let aro = statement as? AROStatement {
                if let finding = inspect(aro, tainted: &tainted, seenBody: &seenBody, actionMaterializes: actionMaterializes) {
                    return finding
                }
            } else if let pipeline = statement as? PipelineStatement {
                for stage in pipeline.stages {
                    if let finding = inspect(stage, tainted: &tainted, seenBody: &seenBody, actionMaterializes: actionMaterializes) {
                        return finding
                    }
                }
            } else if let loop = statement as? ForEachLoop {
                // Iterating a stream is the element-wise shape: the loop pulls
                // one element at a time and never holds the collection. A
                // specifier on the collection is a field access, which does.
                if tainted.contains(loop.collection.base), !loop.collection.specifiers.isEmpty {
                    return Finding(statement: "For each <\(loop.itemVariable)> in <\(loop.collection.base): \(loop.collection.specifiers.joined(separator: "."))>", line: loop.span.start.line, span: loop.span)
                }
                if let finding = walk(loop.body, tainted: &tainted, seenBody: &seenBody, actionMaterializes: actionMaterializes) {
                    return finding
                }
            } else if let match = statement as? MatchStatement {
                // Matching on a binding compares it, which needs its value.
                if tainted.contains(match.subject.base) {
                    return Finding(statement: match.description, line: match.span.start.line, span: match.span)
                }
                for clause in match.cases {
                    if let finding = walk(clause.body, tainted: &tainted, seenBody: &seenBody, actionMaterializes: actionMaterializes) {
                        return finding
                    }
                }
                if let otherwise = match.otherwise,
                   let finding = walk(otherwise, tainted: &tainted, seenBody: &seenBody, actionMaterializes: actionMaterializes) {
                    return finding
                }
            } else if let loop = statement as? WhileLoop {
                if let finding = walk(loop.body, tainted: &tainted, seenBody: &seenBody, actionMaterializes: actionMaterializes) {
                    return finding
                }
            } else if let publish = statement as? PublishStatement {
                // A published binding outlives the feature set, so it cannot
                // stay a stream tied to this connection.
                if tainted.contains(publish.internalVariable) {
                    return Finding(statement: publish.description, line: publish.span.start.line, span: publish.span)
                }
            }
        }
        return nil
    }

    private func inspect(
        _ statement: AROStatement,
        tainted: inout Set<String>,
        seenBody: inout Bool,
        actionMaterializes: [String: Bool]
    ) -> Finding? {
        let verb = statement.action.verb
        let objectNoun = statement.object.noun
        let consumption = StreamConsumptionPolicy.consumption(
            ofVerb: verb,
            resultQualifiers: statement.result.specifiers
        )

        // The source: the request body itself.
        if Self.isBodyReference(objectNoun) {
            seenBody = true
            if Self.namesFieldInsideBody(objectNoun) {
                return Finding(statement: describe(statement), line: statement.span.start.line, span: statement.span)
            }
            switch consumption {
            case .passThrough:
                tainted.insert(statement.result.base)
                return nil
            case .elementWise:
                return nil
            case .wholeValue:
                return Finding(statement: describe(statement), line: statement.span.start.line, span: statement.span)
            }
        }

        // A user-defined action receives the value as its input; whether that
        // reads it is the callee's business (ARO-0081).
        if verb.hasPrefix("Application.") {
            guard touchesTainted(statement, tainted: tainted) else { return nil }
            let callee = String(verb.dropFirst("Application.".count))
            if actionMaterializes[callee] ?? true {
                return Finding(statement: describe(statement), line: statement.span.start.line, span: statement.span)
            }
            tainted.insert(statement.result.base)
            return nil
        }

        // A guard inspects. `… when <upload> is not empty` asks a question about
        // the body, and a question needs the answer — so it reads, even when
        // the statement it guards would only have moved it.
        if let condition = statement.statementGuard.condition {
            let referenced = condition.accept(VariableNameCollector())
            if !referenced.isDisjoint(with: tainted) {
                return Finding(statement: describe(statement), line: statement.span.start.line, span: statement.span)
            }
        }

        guard touchesTainted(statement, tainted: tainted) else { return nil }

        // A field access needs the value the field lives in, whichever slot it
        // appears in: `Log <upload: name>` reads as surely as
        // `Extract the <n> from the <upload: name>`.
        if tainted.contains(objectNoun.base), !objectNoun.specifiers.isEmpty {
            return Finding(statement: describe(statement), line: statement.span.start.line, span: statement.span)
        }
        if tainted.contains(statement.result.base), !statement.result.specifiers.isEmpty,
           consumption != .elementWise {
            return Finding(statement: describe(statement), line: statement.span.start.line, span: statement.span)
        }

        switch consumption {
        case .elementWise:
            // Moving it: `Write the <upload> to the <file: …>`,
            // `Return an <OK: status> with <upload>`.
            return nil
        case .passThrough:
            tainted.insert(statement.result.base)
            return nil
        case .wholeValue:
            return Finding(statement: describe(statement), line: statement.span.start.line, span: statement.span)
        }
    }

    /// Whether a statement mentions a tainted binding at all — in the object
    /// slot, in the result slot (where a sink puts it), or in a clause.
    private func touchesTainted(_ statement: AROStatement, tainted: Set<String>) -> Bool {
        if tainted.contains(statement.object.noun.base) { return true }
        if tainted.contains(statement.result.base) { return true }
        return referencesTaintedInClauses(statement, tainted: tainted)
    }

    // MARK: - Input-reading summary for user-defined actions

    /// Whether a user-defined action reads the value passed to it.
    ///
    /// `takes <field>` is sugar: the caller passes one value and the runtime
    /// wraps it as `{ field: value }`, so `Extract the <x> from the <input:
    /// field>` unwraps the sugar rather than reading the value. What the
    /// action then does with `<x>` is the real question.
    private func readsItsInput(_ featureSet: FeatureSet, actionMaterializes: [String: Bool]) -> Bool {
        var tainted: Set<String> = ["input"]
        var seenBody = true  // `input` is the source here, not `request.body`.
        var statements = featureSet.statements

        if let takesField = featureSet.userActionTakesField {
            var remaining: [Statement] = []
            for statement in statements {
                if let aro = statement as? AROStatement,
                   aro.object.noun.base == "input",
                   aro.object.noun.specifiers == [takesField],
                   StreamConsumptionPolicy.consumption(ofVerb: aro.action.verb) == .passThrough {
                    tainted.insert(aro.result.base)
                    continue
                }
                remaining.append(statement)
            }
            statements = remaining
        }

        return walk(statements, tainted: &tainted, seenBody: &seenBody, actionMaterializes: actionMaterializes) != nil
    }

    // MARK: - Reference helpers

    /// `<request: body>`, or the convenience binding `<body>`.
    private static func isBodyReference(_ noun: QualifiedNoun) -> Bool {
        if noun.base == "request" { return noun.specifiers.first == "body" }
        if noun.base == "body" { return true }
        return false
    }

    /// `<request: body.name>` or `<body: name>` — a field *inside* the body,
    /// which needs the body to exist as a value first.
    private static func namesFieldInsideBody(_ noun: QualifiedNoun) -> Bool {
        if noun.base == "request" { return noun.specifiers.count > 1 }
        if noun.base == "body" { return !noun.specifiers.isEmpty }
        return false
    }

    private func referencesTaintedInClauses(_ statement: AROStatement, tainted: Set<String>) -> Bool {
        var referenced: Set<String> = []
        let collector = VariableNameCollector()
        if let expression = statement.rangeModifiers.withClause {
            referenced.formUnion(expression.accept(collector))
        }
        if let expression = statement.rangeModifiers.toClause {
            referenced.formUnion(expression.accept(collector))
        }
        if let expression = statement.statementGuard.condition {
            referenced.formUnion(expression.accept(collector))
        }
        if let expression = statement.valueSource.asExpression {
            referenced.formUnion(expression.accept(collector))
        }
        return !referenced.isDisjoint(with: tainted)
    }

    /// The statement, as the programmer wrote it, for a message they will read.
    ///
    /// Framework bindings are hidden: a `with` clause parses into
    /// `_expression_`, and `Create the <user> with the <_expression_>` names an
    /// internal that appears nowhere in the source.
    private func describe(_ statement: AROStatement) -> String {
        let noun = statement.object.noun
        guard !Self.frameworkBindings.contains(noun.base) else {
            return "\(statement.action.verb) the <\(statement.result.base)> "
                + "\(statement.object.preposition.rawValue) the request body"
        }
        let object = noun.specifiers.isEmpty
            ? "<\(noun.base)>"
            : "<\(noun.base): \(noun.specifiers.joined(separator: "."))>"
        return "\(statement.action.verb) the <\(statement.result.base)> \(statement.object.preposition.rawValue) the \(object)"
    }

    /// Names the parser introduces that no programmer typed.
    private static let frameworkBindings: Set<String> = [
        "_expression_", "_literal_", "_with_", "_to_", "_against_", "_result_expression_",
    ]
}

// MARK: - Variable collection

/// Collects the base names referenced anywhere in an expression tree.
struct VariableNameCollector: ExpressionVisitor {
    typealias Result = Set<String>

    func visit(_ node: LiteralExpression) -> Set<String> { [] }

    func visit(_ node: VariableRefExpression) -> Set<String> { [node.noun.base] }

    func visit(_ node: BinaryExpression) -> Set<String> {
        node.left.accept(self).union(node.right.accept(self))
    }

    func visit(_ node: UnaryExpression) -> Set<String> { node.operand.accept(self) }

    func visit(_ node: MemberAccessExpression) -> Set<String> { node.base.accept(self) }

    func visit(_ node: SubscriptExpression) -> Set<String> {
        node.base.accept(self).union(node.index.accept(self))
    }

    func visit(_ node: GroupedExpression) -> Set<String> { node.expression.accept(self) }

    func visit(_ node: ExistenceExpression) -> Set<String> { node.expression.accept(self) }

    func visit(_ node: TypeCheckExpression) -> Set<String> { node.expression.accept(self) }

    func visit(_ node: EmptinessCheckExpression) -> Set<String> { node.expression.accept(self) }

    func visit(_ node: ArrayLiteralExpression) -> Set<String> {
        node.elements.reduce(into: Set<String>()) { $0.formUnion($1.accept(self)) }
    }

    func visit(_ node: MapLiteralExpression) -> Set<String> {
        node.entries.reduce(into: Set<String>()) { $0.formUnion($1.value.accept(self)) }
    }

    func visit(_ node: InterpolatedStringExpression) -> Set<String> {
        node.parts.reduce(into: Set<String>()) { accumulated, part in
            if case .interpolation(let expression) = part {
                accumulated.formUnion(expression.accept(self))
            }
        }
    }
}
