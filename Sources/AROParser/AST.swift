// ============================================================
// AST.swift
// ARO Parser - Abstract Syntax Tree Definitions
// ============================================================

import Foundation

// MARK: - AST Node Protocol

/// Base protocol for all AST nodes
public protocol ASTNode: Sendable, Locatable, CustomStringConvertible {
    /// Accepts a visitor for traversal
    func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result
}

// MARK: - Import Declaration (ARO-0007)

/// An import declaration for including another ARO application
public struct ImportDeclaration: ASTNode {
    /// The relative path to the imported application directory
    public let path: String
    public let span: SourceSpan

    public init(path: String, span: SourceSpan) {
        self.path = path
        self.span = span
    }

    public var description: String {
        "import \(path)"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Program (Root Node)

/// The root node representing an entire ARO program
public struct Program: ASTNode {
    /// Import declarations (ARO-0007)
    public let imports: [ImportDeclaration]
    public let featureSets: [FeatureSet]
    public let span: SourceSpan

    public init(imports: [ImportDeclaration] = [], featureSets: [FeatureSet], span: SourceSpan) {
        self.imports = imports
        self.featureSets = featureSets
        self.span = span
    }

    public var description: String {
        var desc = "Program("
        if !imports.isEmpty {
            desc += "\(imports.count) imports, "
        }
        desc += "\(featureSets.count) feature sets)"
        return desc
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Feature Set

/// A feature set containing related features
public struct FeatureSet: ASTNode {
    public let name: String
    public let businessActivity: String
    public let statements: [Statement]
    public let whenCondition: (any Expression)?
    /// User-defined action sugar slot (ARO-0081).
    ///
    /// When the activity is `Action`, the optional `takes <field[: Type]>` clause
    /// in the header declares a single positional parameter that callers may pass
    /// using `from <value>`. When non-nil this feature set is callable as
    /// `Application.<name>` and `from <value>` synthesises an input object with
    /// `{ field: value }`.
    public let userActionTakesField: String?
    /// Optional type annotation for the `takes` field (e.g. "Integer").
    public let userActionTakesType: String?
    /// Positional command-line arguments declared by an `Application-Start`
    /// header (ARO-0047 §Positional Arguments, GitLab #857):
    ///
    /// ```aro
    /// (Application-Start: Crawler takes <url> <depth>) { … }
    /// ```
    ///
    /// Each name binds the positional at the same index, readable as
    /// `<parameter: url>`. Empty for every other feature set.
    public let positionalParameters: [String]
    public let span: SourceSpan

    public init(
        name: String,
        businessActivity: String,
        statements: [Statement],
        whenCondition: (any Expression)? = nil,
        userActionTakesField: String? = nil,
        userActionTakesType: String? = nil,
        positionalParameters: [String] = [],
        span: SourceSpan
    ) {
        self.name = name
        self.businessActivity = businessActivity
        self.statements = statements
        self.whenCondition = whenCondition
        self.userActionTakesField = userActionTakesField
        self.userActionTakesType = userActionTakesType
        self.positionalParameters = positionalParameters
        self.span = span
    }

    public var description: String {
        let whenDesc = whenCondition != nil ? " when ..." : ""
        let takesDesc = userActionTakesField.map { " takes <\($0)>" } ?? ""
        return "FeatureSet(\(name): \(businessActivity)\(takesDesc)\(whenDesc), \(statements.count) statements)"
    }

    /// True when this feature set is a user-defined action (ARO-0081).
    /// User-defined actions live under the `Application.` handle and are invoked
    /// like plugin actions: `Application.<Name> the <result> with { ... }.`
    public var isUserAction: Bool {
        businessActivity == "Action"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Statements

/// Protocol for all statement types
public protocol Statement: ASTNode {
    /// Accepts a `StatementVisitor` for polymorphic dispatch (#338).
    /// Declared as a protocol requirement (not just an extension) so the
    /// concrete node's implementation is dynamically dispatched even when
    /// the value is typed as `Statement`.
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result

    /// The word this statement is called by in user-visible output — the
    /// node cards and pairing keys of `aro diff --graph`, for instance.
    ///
    /// A requirement rather than something derived from the Swift type name:
    /// the graph diff used to spell it `String(describing: type(of:))` minus
    /// the word "Statement", which made a rename of an AST type a silent
    /// change to what the tool prints.
    var displayVerb: String { get }
}

/// A pipeline statement chains actions with |> operator (ARO-0067)
public struct PipelineStatement: Statement {
    public var displayVerb: String { "Pipeline" }

    public let stages: [AROStatement]
    public let span: SourceSpan

    public init(stages: [AROStatement], span: SourceSpan) {
        self.stages = stages
        self.span = span
    }

    public var description: String {
        "Pipeline(\(stages.count) stages)"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// An ARO (Action-Result-Object) statement
///
/// Refactored to use grouped clause types for better semantic organization:
/// - `valueSource`: Where the value comes from (literal, expression, sink)
/// - `queryModifiers`: Query-related clauses (where, aggregation, by)
/// - `rangeModifiers`: Range/set operation clauses (to, with)
/// - `statementGuard`: Optional condition for guarded execution
public struct AROStatement: Statement {
    /// The verb the author wrote.
    public var displayVerb: String { action.verb }

    // MARK: - Required Fields
    public let action: Action
    public let result: QualifiedNoun
    public let object: ObjectClause
    public let span: SourceSpan

    // MARK: - Grouped Clause Fields
    /// Where the statement's value comes from (replaces literalValue, expression, resultExpression)
    public let valueSource: ValueSource
    /// Query-related clauses (replaces whereClause, aggregation, byClause)
    public let queryModifiers: QueryModifiers
    /// Range and set operation clauses (replaces toClause, withClause)
    public let rangeModifiers: RangeModifiers
    /// Optional guard condition (replaces whenCondition)
    public let statementGuard: StatementGuard

    // MARK: - Grouped Initializer

    public init(
        action: Action,
        result: QualifiedNoun,
        object: ObjectClause,
        valueSource: ValueSource = .none,
        queryModifiers: QueryModifiers = .none,
        rangeModifiers: RangeModifiers = .none,
        statementGuard: StatementGuard = .none,
        span: SourceSpan
    ) {
        self.action = action
        self.result = result
        self.object = object
        self.valueSource = valueSource
        self.queryModifiers = queryModifiers
        self.rangeModifiers = rangeModifiers
        self.statementGuard = statementGuard
        self.span = span
    }

    // MARK: - Legacy Initializer (Backward Compatibility)

    @available(*, deprecated, message: "Use the grouped initializer instead")
    public init(
        action: Action,
        result: QualifiedNoun,
        object: ObjectClause,
        literalValue: LiteralValue? = nil,
        expression: (any Expression)? = nil,
        aggregation: AggregationClause? = nil,
        whereClause: WhereClause? = nil,
        byClause: ByClause? = nil,
        toClause: (any Expression)? = nil,
        withClause: (any Expression)? = nil,
        whenCondition: (any Expression)? = nil,
        resultExpression: (any Expression)? = nil,
        span: SourceSpan
    ) {
        self.action = action
        self.result = result
        self.object = object
        self.span = span

        // Build ValueSource from legacy fields
        if let resExpr = resultExpression {
            self.valueSource = .sinkExpression(resExpr)
        } else if let expr = expression {
            self.valueSource = .expression(expr)
        } else if let literal = literalValue {
            self.valueSource = .literal(literal)
        } else {
            self.valueSource = .none
        }

        // Build QueryModifiers from legacy fields
        self.queryModifiers = QueryModifiers(
            whereClause: whereClause,
            aggregation: aggregation,
            byClause: byClause
        )

        // Build RangeModifiers from legacy fields
        self.rangeModifiers = RangeModifiers(
            toClause: toClause,
            withClause: withClause
        )

        // Build StatementGuard from legacy field
        self.statementGuard = StatementGuard(condition: whenCondition)
    }

    // MARK: - Convenience Accessors

    /// Optional expression value (ARO-0002) - for computed values like `from <x> * <y>`
    public var expression: (any Expression)? {
        if case .expression(let e) = valueSource { return e }
        return nil
    }

    /// Optional result expression (ARO-0043) - for sink syntax: `<Log> "message" to <console>`
    public var resultExpression: (any Expression)? {
        if case .sinkExpression(let e) = valueSource { return e }
        return nil
    }

    /// Optional aggregation clause (ARO-0018) - for Reduce: `with sum(<field>)`
    public var aggregation: AggregationClause? {
        queryModifiers.aggregation
    }

    /// Optional where clause (ARO-0018) - for Filter: `where <field> is "value"`
    public var whereClause: WhereClause? {
        queryModifiers.whereClause
    }

    /// Optional by clause (ARO-0037) - for Split: `by /delimiter/`
    public var byClause: ByClause? {
        queryModifiers.byClause
    }

    /// Optional matching clause (ARO-0036) - for List: `matching "*.csv"`
    public var matchingPattern: (any Expression)? {
        queryModifiers.matchingPattern
    }

    /// Optional to clause (ARO-0041) - for date ranges: `from <start> to <end>`
    public var toClause: (any Expression)? {
        rangeModifiers.toClause
    }

    /// Optional with clause (ARO-0042) - for set operations: `from <a> with <b>`
    public var withClause: (any Expression)? {
        rangeModifiers.withClause
    }

    /// Optional when condition (ARO-0004) - for guarded statements
    public var whenCondition: (any Expression)? {
        statementGuard.condition
    }

    // MARK: - Description

    public var description: String {
        var desc: String
        if case .sinkExpression(let resExpr) = valueSource {
            // Sink syntax: <Log> "message" to the <console>
            desc = "<\(action.verb)> \(resExpr) \(object.preposition) the <\(object.noun)>"
        } else {
            desc = "<\(action.verb)> the <\(result)> \(object.preposition) the <\(object.noun)>"
        }
        if let literal = valueSource.asLiteral {
            desc += " with \(literal)"
        }
        if case .expression(let expr) = valueSource {
            desc += " = \(expr)"
        }
        if let agg = queryModifiers.aggregation {
            desc += " with \(agg)"
        }
        if let where_ = queryModifiers.whereCondition {
            desc += " where \(where_)"
        }
        if let by = queryModifiers.byClause {
            desc += " \(by)"
        }
        if let matching = queryModifiers.matchingPattern {
            desc += " matching \(matching)"
        }
        if queryModifiers.recursive {
            desc += " recursively"
        }
        if let when = statementGuard.condition {
            desc += " when \(when)"
        }
        return desc + "."
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// A publish statement for exporting variables
public struct PublishStatement: Statement {
    public var displayVerb: String { "Publish" }

    public let externalName: String
    public let internalVariable: String
    /// Optional `when` guard, the same one every action statement carries
    /// (GitLab #830 item 14).
    ///
    /// Publishing is an effect like any other, and it is the one effect
    /// that had no way to say "only if". The workaround the books taught
    /// was to publish unconditionally and have every reader guard, which
    /// puts the condition in the wrong place and repeats it once per
    /// reader.
    public let statementGuard: StatementGuard
    public let span: SourceSpan

    public init(externalName: String, internalVariable: String,
                statementGuard: StatementGuard = .none, span: SourceSpan) {
        self.externalName = externalName
        self.internalVariable = internalVariable
        self.statementGuard = statementGuard
        self.span = span
    }

    /// The guard condition, for callers that only want the expression.
    public var whenCondition: (any Expression)? { statementGuard.condition }

    public var description: String {
        if let when = statementGuard.condition {
            return "Publish as <\(externalName)> <\(internalVariable)> when \(when)."
        }
        return "Publish as <\(externalName)> <\(internalVariable)>."
    }
    
    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Aggregation Clause (ARO-0018)

/// Types of aggregation operations
public enum AggregationType: String, Sendable, Equatable, CustomStringConvertible {
    case sum = "sum"
    case count = "count"
    case avg = "avg"
    case min = "min"
    case max = "max"
    case first = "first"
    case last = "last"

    public var description: String { rawValue }
}

/// An aggregation clause: with sum(<field>), with count(), with avg(<field>)
public struct AggregationClause: Sendable, CustomStringConvertible {
    public let type: AggregationType
    /// The field to aggregate (nil for count)
    public let field: String?
    public let span: SourceSpan

    public init(type: AggregationType, field: String?, span: SourceSpan) {
        self.type = type
        self.field = field
        self.span = span
    }

    public var description: String {
        if let field = field {
            return "\(type)(<\(field)>)"
        }
        return "\(type)()"
    }
}

// MARK: - Where Clause (ARO-0018)

/// Comparison operators for where clauses
public enum WhereOperator: String, Sendable, Equatable, CustomStringConvertible {
    case equal = "is"
    case notEqual = "is not"
    case lessThan = "<"
    case greaterThan = ">"
    case lessEqual = "<="
    case greaterEqual = ">="
    case contains = "contains"
    case matches = "matches"
    /// `where <name> starts with "ARO-"`.
    ///
    /// The runtime has evaluated `starts-with` / `ends-with` since
    /// ARO-0018 shipped; only the grammar to write them was missing, so
    /// the books taught a `matches "^ARO-"` regex for a prefix test
    /// (GitLab #830 item 5). The raw values are the strings
    /// `WhereConditionEvaluator` already dispatches on.
    case startsWith = "starts-with"
    case endsWith = "ends-with"
    case `in` = "in"          // ARO-0042: membership test
    case notIn = "not in"     // ARO-0042: negative membership test
    // Temporal comparison (Book ch. 42 §42.8, GitLab #516) — the
    // same ordering as `<` / `>`, said the way a domain says it.
    case before = "before"
    case after = "after"

    public var description: String { rawValue }
}

/// A where clause: where <field> is "value" or where <field> > 1000
public struct WhereClause: Sendable, CustomStringConvertible {
    public let field: String
    public let op: WhereOperator
    public let value: any Expression
    public let span: SourceSpan

    public init(field: String, op: WhereOperator, value: any Expression, span: SourceSpan) {
        self.field = field
        self.op = op
        self.value = value
        self.span = span
    }

    public var description: String {
        "<\(field)> \(op) \(value)"
    }
}

/// A where-clause condition tree (ARO-0018 §2.2, GitLab #498).
///
/// `where <status> == "paid" and <qty> > 2` parses into
/// `.and(.predicate(status == "paid"), .predicate(qty > 2))`.
/// `and` binds tighter than `or`; parentheses group explicitly.
/// `between lo and hi` desugars in the parser to
/// `.and(field >= lo, field <= hi)`, so it never appears here as
/// its own case. A plain single-predicate where is `.predicate`.
public indirect enum WhereCondition: Sendable, CustomStringConvertible {
    case predicate(WhereClause)
    case and(WhereCondition, WhereCondition)
    case or(WhereCondition, WhereCondition)

    /// All leaf predicates, left to right. The order matches the
    /// indices used in `treeSkeleton`.
    public var predicates: [WhereClause] {
        switch self {
        case .predicate(let p): return [p]
        case .and(let l, let r), .or(let l, let r): return l.predicates + r.predicates
        }
    }

    /// The single predicate when the condition is not compound;
    /// nil for any `and`/`or` node.
    public var singlePredicate: WhereClause? {
        if case .predicate(let p) = self { return p }
        return nil
    }

    public var span: SourceSpan {
        switch self {
        case .predicate(let p): return p.span
        case .and(let l, let r), .or(let l, let r): return l.span.merged(with: r.span)
        }
    }

    /// Structure-only rendering with predicates replaced by their
    /// left-to-right index: `and(0,or(1,2))`. This is the wire form
    /// both execution modes hand to the runtime (`_where_tree_`):
    /// the interpreter binds it directly, the LLVM backend emits it
    /// as a string constant, and the runtime's where-condition
    /// evaluator parses it back next to the numbered
    /// `_where_field_N_` / `_where_op_N_` / `_where_value_N_` binds.
    public var treeSkeleton: String {
        var counter = 0
        func render(_ condition: WhereCondition) -> String {
            switch condition {
            case .predicate:
                defer { counter += 1 }
                return String(counter)
            case .and(let l, let r): return "and(\(render(l)),\(render(r)))"
            case .or(let l, let r): return "or(\(render(l)),\(render(r)))"
            }
        }
        return render(self)
    }

    public var description: String {
        switch self {
        case .predicate(let p): return p.description
        case .and(let l, let r): return "(\(l) and \(r))"
        case .or(let l, let r): return "(\(l) or \(r))"
        }
    }
}

// MARK: - By Clause (ARO-0037)

/// The direction of a trailing `ascending` / `descending` on a `by` clause.
///
/// The raw values are the words the author writes and the words the runtime
/// binds into `_by_order_`, so the enum is a name for the two strings that
/// were already the only legal ones — not a new encoding.
public enum SortOrder: String, Sendable, CaseIterable, CustomStringConvertible {
    case ascending
    case descending

    public var description: String { rawValue }
}

/// A by clause for regex-based splitting or field-based grouping
///
/// Supports two forms:
/// - Regex: `by /pattern/flags` (for Split action)
/// - Field: `by "fieldName"` (for Group action)
public struct ByClause: Sendable, CustomStringConvertible {
    public let pattern: String
    public let flags: String
    /// When true, `pattern` is a literal field name rather than a regex.
    public let isFieldName: Bool
    /// When set, the executor resolves this variable at runtime and uses
    /// its string value as the split pattern. Lets data files (yaml/json)
    /// drive what a Split or Group action keys off — `pattern` is then
    /// just a fallback / display value.
    public let variableName: String?
    /// Trailing sort order after the by target — `by <score> descending`
    /// (ARO-0002 §Ordering, GitLab #491).
    public let order: SortOrder?
    public let span: SourceSpan

    public init(pattern: String,
                flags: String,
                span: SourceSpan,
                isFieldName: Bool = false,
                variableName: String? = nil,
                order: SortOrder? = nil) {
        self.pattern = pattern
        self.flags = flags
        self.isFieldName = isFieldName
        self.variableName = variableName
        self.order = order
        self.span = span
    }

    public var description: String {
        if let v = variableName {
            return "by <\(v)>"
        }
        if isFieldName {
            return "by \"\(pattern)\""
        }
        if flags.isEmpty {
            return "by /\(pattern)/"
        }
        return "by /\(pattern)/\(flags)"
    }
}

// MARK: - Value Source (ARO-0002, ARO-0043)

/// Represents the source of a value in an ARO statement.
/// These are mutually exclusive - a statement has exactly one value source.
public enum ValueSource: Sendable, CustomStringConvertible {
    /// Standard syntax: no explicit value, derived from object
    case none

    /// Legacy literal: `with "string"`, `with 42`
    case literal(LiteralValue)

    /// Expression value (ARO-0002): `from <x> * <y>`
    case expression(any Expression)

    /// Sink expression (ARO-0043): `<Log> "message" to <console>`
    /// The result position contains an expression instead of a variable to bind
    case sinkExpression(any Expression)

    public var description: String {
        switch self {
        case .none: return "none"
        case .literal(let v): return "literal(\(v))"
        case .expression(let e): return "expression(\(e))"
        case .sinkExpression(let e): return "sink(\(e))"
        }
    }

    /// Extract the expression if this is an expression or sink expression
    public var asExpression: (any Expression)? {
        switch self {
        case .expression(let e), .sinkExpression(let e): return e
        case .none, .literal: return nil
        }
    }

    /// Extract the literal if this is a literal value source
    public var asLiteral: LiteralValue? {
        if case .literal(let v) = self { return v }
        return nil
    }

    /// Check if this is a sink expression
    public var isSinkSyntax: Bool {
        if case .sinkExpression = self { return true }
        return false
    }
}

// MARK: - Query Modifiers (ARO-0018, ARO-0037)

/// Groups query-related clauses for Filter, Reduce, Split operations.
public struct QueryModifiers: Sendable, CustomStringConvertible {
    /// Filter condition tree: `where <a> is "x" and <b> > 2` (GitLab #498)
    public let whereCondition: WhereCondition?

    /// Aggregation function: `with sum(<field>)`
    public let aggregation: AggregationClause?

    /// Split pattern: `by /delimiter/`
    public let byClause: ByClause?

    /// Default value when retrieve returns no results: `default ""`
    public let defaultValue: (any Expression)?

    /// Glob filter on a directory listing: `matching "*.csv"` (ARO-0036 §6.2,
    /// GitLab #518). An expression, so `matching <pattern>` reads the glob out
    /// of a variable the same way `default <fallback>` reads its fallback.
    public let matchingPattern: (any Expression)?

    /// Trailing `recursively` on a directory listing (ARO-0036 §6.3).
    public let recursive: Bool

    /// The where condition when it is a single predicate; nil when
    /// absent or compound. Kept for consumers that can only handle
    /// one field/op/value triple — anything walking variables or
    /// fields must use `whereCondition?.predicates` instead.
    public var whereClause: WhereClause? {
        whereCondition?.singlePredicate
    }

    public init(
        whereClause: WhereClause? = nil,
        aggregation: AggregationClause? = nil,
        byClause: ByClause? = nil,
        defaultValue: (any Expression)? = nil,
        matchingPattern: (any Expression)? = nil,
        recursive: Bool = false
    ) {
        self.whereCondition = whereClause.map { .predicate($0) }
        self.aggregation = aggregation
        self.byClause = byClause
        self.defaultValue = defaultValue
        self.matchingPattern = matchingPattern
        self.recursive = recursive
    }

    public init(
        whereCondition: WhereCondition?,
        aggregation: AggregationClause? = nil,
        byClause: ByClause? = nil,
        defaultValue: (any Expression)? = nil,
        matchingPattern: (any Expression)? = nil,
        recursive: Bool = false
    ) {
        self.whereCondition = whereCondition
        self.aggregation = aggregation
        self.byClause = byClause
        self.defaultValue = defaultValue
        self.matchingPattern = matchingPattern
        self.recursive = recursive
    }

    /// Empty query modifiers
    public static let none = QueryModifiers()

    /// Check if any query modifier is present
    public var isEmpty: Bool {
        whereCondition == nil && aggregation == nil && byClause == nil
            && defaultValue == nil && matchingPattern == nil && !recursive
    }

    public var description: String {
        var parts: [String] = []
        if let w = whereCondition { parts.append("where \(w)") }
        if let a = aggregation { parts.append("with \(a)") }
        if let b = byClause { parts.append("\(b)") }
        if defaultValue != nil { parts.append("default ...") }
        if let m = matchingPattern { parts.append("matching \(m)") }
        if recursive { parts.append("recursively") }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }
}

// MARK: - Range Modifiers (ARO-0041, ARO-0042)

/// Groups range and set operation clauses.
public struct RangeModifiers: Sendable, CustomStringConvertible {
    /// End of range: `from <start> to <end>`
    public let toClause: (any Expression)?

    /// Set operation operand: `from <a> with <b>`
    public let withClause: (any Expression)?

    /// Comparison right-hand operand: `from <a> against <b>`
    /// (GitLab #469). Separate from `withClause` because a
    /// statement can carry both — `Compare` reads this one.
    public let againstClause: (any Expression)?

    public init(
        toClause: (any Expression)? = nil,
        withClause: (any Expression)? = nil,
        againstClause: (any Expression)? = nil
    ) {
        self.toClause = toClause
        self.withClause = withClause
        self.againstClause = againstClause
    }

    /// Empty range modifiers
    public static let none = RangeModifiers()

    /// Check if any range modifier is present
    public var isEmpty: Bool {
        toClause == nil && withClause == nil
    }

    public var description: String {
        var parts: [String] = []
        if let t = toClause { parts.append("to \(t)") }
        if let w = withClause { parts.append("with \(w)") }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }
}

// MARK: - Statement Guard (ARO-0004)

/// Optional guard condition for conditional execution.
public struct StatementGuard: Sendable, CustomStringConvertible {
    /// The condition expression: `when <condition>`
    public let condition: (any Expression)?

    public init(condition: (any Expression)? = nil) {
        self.condition = condition
    }

    /// No guard condition
    public static let none = StatementGuard()

    /// Check if a guard condition is present
    public var isPresent: Bool { condition != nil }

    public var description: String {
        if let c = condition { return "when \(c)" }
        return "none"
    }
}

// MARK: - Require Statement (ARO-0003)

/// Source for a required dependency
public enum RequireSource: Sendable, Equatable, CustomStringConvertible {
    case framework
    case environment
    case featureSet(String)

    public var description: String {
        switch self {
        case .framework: return "framework"
        case .environment: return "environment"
        case .featureSet(let name): return name
        }
    }
}

/// Statement for declaring external dependencies: <Require> the <variable> from the <source>.
public struct RequireStatement: Statement {
    public var displayVerb: String { "Require" }

    public let variableName: String
    public let source: RequireSource
    public let span: SourceSpan

    public init(variableName: String, source: RequireSource, span: SourceSpan) {
        self.variableName = variableName
        self.source = source
        self.span = span
    }

    public var description: String {
        "Require the <\(variableName)> from the <\(source)>."
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Match Statement (ARO-0004)

/// Pattern for case matching
public enum Pattern: Sendable, CustomStringConvertible {
    case literal(LiteralValue)
    case variable(QualifiedNoun)
    case wildcard
    case regex(pattern: String, flags: String)

    public var description: String {
        switch self {
        case .literal(let value): return value.description
        case .variable(let noun): return "<\(noun.fullName)>"
        case .wildcard: return "_"
        case .regex(let pattern, let flags): return "/\(pattern)/\(flags)"
        }
    }
}

/// A single case clause in a match expression
public struct CaseClause: Sendable, CustomStringConvertible {
    public let pattern: Pattern
    public let guardCondition: (any Expression)?
    public let body: [Statement]
    public let span: SourceSpan

    public init(pattern: Pattern, guardCondition: (any Expression)?, body: [Statement], span: SourceSpan) {
        self.pattern = pattern
        self.guardCondition = guardCondition
        self.body = body
        self.span = span
    }

    public var description: String {
        var desc = "case \(pattern)"
        if let guard_ = guardCondition {
            desc += " where \(guard_)"
        }
        desc += " { ... }"
        return desc
    }
}

/// Match expression statement: match <subject> { case ... otherwise ... }
/// A guarded block: `when <condition> { … }`.
///
/// ARO has always had `when` as a statement suffix. The block form is
/// what the Language Guide writes when a whole group of statements
/// shares one condition (Book ch. 42 §42.8, GitLab #516) — the same
/// meaning, spelled once instead of once per line.
public struct WhenStatement: Statement {
    public var displayVerb: String { "When" }

    public let condition: any Expression
    public let body: [Statement]
    public let span: SourceSpan

    public init(condition: any Expression, body: [Statement], span: SourceSpan) {
        self.condition = condition
        self.body = body
        self.span = span
    }

    public var description: String {
        "when \(condition) { \(body.count) statements }"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

public struct MatchStatement: Statement {
    public var displayVerb: String { "Match" }

    public let subject: QualifiedNoun
    public let cases: [CaseClause]
    public let otherwise: [Statement]?
    public let span: SourceSpan

    public init(subject: QualifiedNoun, cases: [CaseClause], otherwise: [Statement]?, span: SourceSpan) {
        self.subject = subject
        self.cases = cases
        self.otherwise = otherwise
        self.span = span
    }

    public var description: String {
        var desc = "match <\(subject.fullName)> { \(cases.count) cases"
        if otherwise != nil {
            desc += ", otherwise"
        }
        desc += " }"
        return desc
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - For-Each Loop (ARO-0005)

/// For-each loop statement: for each <item> [at <index>] in <collection> [where <condition>] { ... }
/// Also supports: parallel for each <item> in <collection> [with <concurrency: N>] { ... }
///
/// The collection slot takes either a plain noun (`<items>`, `<team: members>`) or
/// a general expression (`[1, 2, 3]`, `(<a> + <b>)`, `<order>.lines`) — GitLab #519.
/// Exactly one of `collection` / `collectionExpression` is non-nil.
public struct ForEachLoop: Statement {
    public var displayVerb: String { "ForEachLoop" }

    public let itemVariable: String
    public let indexVariable: String?

    /// The collection written as a noun: `<items>` or `<team: members>`.
    ///
    /// nil when the header carries a general expression — read
    /// `collectionExpression` instead. The noun form is kept separate rather
    /// than wrapped in a `VariableRefExpression` because it alone supports
    /// specifier property access and the lazy-stream iteration path (ARO-0051),
    /// both of which resolve a *name* in the context.
    public let collection: QualifiedNoun?

    /// The collection written as an expression (list literal, member access,
    /// parenthesised arithmetic, …). nil for the noun form.
    public let collectionExpression: (any Expression)?

    public let filter: (any Expression)?
    public let isParallel: Bool
    public let concurrency: Int?
    public let body: [Statement]
    public let span: SourceSpan

    public init(
        itemVariable: String,
        indexVariable: String? = nil,
        collection: QualifiedNoun,
        filter: (any Expression)? = nil,
        isParallel: Bool = false,
        concurrency: Int? = nil,
        body: [Statement],
        span: SourceSpan
    ) {
        self.itemVariable = itemVariable
        self.indexVariable = indexVariable
        self.collection = collection
        self.collectionExpression = nil
        self.filter = filter
        self.isParallel = isParallel
        self.concurrency = concurrency
        self.body = body
        self.span = span
    }

    public init(
        itemVariable: String,
        indexVariable: String? = nil,
        collectionExpression: any Expression,
        filter: (any Expression)? = nil,
        isParallel: Bool = false,
        concurrency: Int? = nil,
        body: [Statement],
        span: SourceSpan
    ) {
        self.itemVariable = itemVariable
        self.indexVariable = indexVariable
        self.collection = nil
        self.collectionExpression = collectionExpression
        self.filter = filter
        self.isParallel = isParallel
        self.concurrency = concurrency
        self.body = body
        self.span = span
    }

    /// How the collection reads back in a diagnostic or an outline label.
    public var collectionLabel: String {
        if let collection { return "<\(collection.fullName)>" }
        if let collectionExpression { return String(describing: collectionExpression) }
        return "<?>"
    }

    public var description: String {
        var desc = isParallel ? "parallel " : ""
        desc += "for each <\(itemVariable)>"
        if let index = indexVariable {
            desc += " at <\(index)>"
        }
        desc += " in \(collectionLabel)"
        if let concurrency = concurrency {
            desc += " with <concurrency: \(concurrency)>"
        }
        if filter != nil {
            desc += " where ..."
        }
        desc += " { \(body.count) statements }"
        return desc
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Error Statement

/// Range-based for loop: for <var> from <low> to <high> { ... }
///
/// A struct, like every other statement. It was a `final class` marked
/// `@unchecked Sendable`, which promised the compiler something it could
/// have checked itself: every stored property is a `let` holding `Sendable`
/// values, so neither the reference type nor the escape hatch bought
/// anything.
public struct RangeLoop: Statement {
    public var displayVerb: String { "RangeLoop" }

    public let variable: String
    public let from: any Expression
    public let to: any Expression
    public let body: [Statement]
    public let span: SourceSpan

    public init(variable: String, from: any Expression, to: any Expression, body: [Statement], span: SourceSpan) {
        self.variable = variable
        self.from = from
        self.to = to
        self.body = body
        self.span = span
    }

    public var description: String {
        "for <\(variable)> from ... to ... { \(body.count) statements }"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// Represents a parse error inline in the AST (partial AST construction).
/// Inserted by the parser when statement-level error recovery skips invalid tokens,
/// allowing downstream consumers to see where errors occurred without discarding
/// the surrounding valid AST nodes.
public struct ErrorStatement: Statement {
    public var displayVerb: String { "Error" }

    /// The error message that caused this node to be created
    public let message: String
    /// The tokens that were skipped during synchronization
    public let skippedTokens: [Token]
    public let span: SourceSpan

    public init(message: String, skippedTokens: [Token], span: SourceSpan) {
        self.message = message
        self.skippedTokens = skippedTokens
        self.span = span
    }

    public var description: String {
        "[parse error: \(message)]"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - While Loop (ARO-0002 extension, GitLab #131)

/// An unbounded `while <condition> { body }` loop.
///
/// Variables bound inside the body are visible on the next iteration and
/// after the loop exits, because the body executes in the same context
/// as the enclosing feature set (mutable-scope mode).
///
/// ## Syntax
/// ```aro
/// while <done> == false {
///     Request the <response> from <url>.
///     Create the <done> with true when <status> == "ok".
/// }
/// ```
public struct WhileLoop: Statement {
    public var displayVerb: String { "WhileLoop" }

    public let condition: any Expression
    public let body: [Statement]
    public let span: SourceSpan

    public init(condition: any Expression, body: [Statement], span: SourceSpan) {
        self.condition = condition
        self.body = body
        self.span = span
    }

    public var description: String {
        "while (...) { \(body.count) statements }"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// A `break` statement that exits the innermost while loop.
public struct BreakStatement: Statement {
    public var displayVerb: String { "Break" }

    public let span: SourceSpan

    public init(span: SourceSpan) {
        self.span = span
    }

    public var description: String { "break" }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}


// MARK: - Action

/// Represents an action verb with semantic classification
public struct Action: Sendable, Equatable, CustomStringConvertible {
    public let verb: String
    public let span: SourceSpan
    
    public init(verb: String, span: SourceSpan) {
        self.verb = verb
        self.span = span
    }
    
    /// The semantic role of this action
    public var semanticRole: ActionSemanticRole {
        ActionSemanticRole.classify(verb: verb)
    }
    
    public var description: String {
        verb
    }
}

/// Semantic classification of actions
public enum ActionSemanticRole: String, Sendable, CaseIterable {
    case request    // Fetches from external (Extract, Parse, Retrieve)
    case own        // Internal computation (Compute, Validate, Compare)
    case response   // Outputs to external (Return, Throw, Send)
    case export     // Makes available to other feature sets (Publish)
    case server     // Server/service operations (Start, Stop, Connect, Close)

    /// Classifies a verb into its semantic role
    /// The semantic role of `verb`.
    ///
    /// One definition, in `ActionRoleCatalog`, mirroring
    /// `ActionImplementation.role`. This used to be four hardcoded lists that
    /// disagreed with the registry on 25 of 136 verbs — so the LSP hover panel
    /// and `aro actions` gave different answers for the same verb, and a
    /// reader had no way to tell which was authoritative (GitLab #585).
    public static func classify(verb: String) -> ActionSemanticRole {
        ActionRoleCatalog.role(forVerb: verb)
    }
}

// MARK: - Qualified Noun

/// What the text after the colon in `<noun: …>` turned out to be.
///
/// The four cases are the four the parser has always distinguished; they
/// were just re-derived by scanning the raw string for `|` and `<` on every
/// read of `specifiers`. Classifying once, at construction, puts the decision
/// in one place and makes it something a reader can see in the type.
public enum Qualifier: Sendable, Equatable {
    /// No qualifier was written.
    case absent
    /// A quoted string literal, e.g. `<file: "data.json">`. Opaque: never a
    /// property path, so the `.json` is not a field access.
    case literal(String)
    /// A chain, e.g. `stats.sort|list.take`. Kept whole so the runtime can
    /// hand it to `resolveChain`.
    case chain(String)
    /// A generic type, e.g. `List<User>`. Kept whole for the same reason a
    /// chain is: the dots inside it are not path separators.
    case generic(String)
    /// A dot-separated property path, e.g. `customer.address.city`.
    case path([String])

    /// Classifies the raw annotation exactly as `specifiers` used to, in the
    /// same order: a quoted literal first, then a chain, then a generic, then
    /// a property path.
    public init(annotation: String?, isLiteral: Bool) {
        guard let annotation else {
            self = .absent
            return
        }
        if isLiteral {
            self = .literal(annotation)
        } else if annotation.contains("|") {
            self = .chain(annotation)
        } else if annotation.contains("<") {
            self = .generic(annotation)
        } else {
            self = .path(annotation.split(separator: ".").map(String.init))
        }
    }

    /// The qualifier as the flat array the rest of the tree consumes: empty
    /// when absent, a single opaque element for a literal, chain or generic,
    /// and the split components for a property path.
    public var specifiers: [String] {
        switch self {
        case .absent: return []
        case .literal(let text), .chain(let text), .generic(let text): return [text]
        case .path(let components): return components
        }
    }
}

/// A noun with optional type annotation (ARO-0006)
///
/// Examples:
/// - `<user>` - Untyped variable
/// - `<name: String>` - Primitive type annotation
/// - `<items: List<Order>>` - Collection type annotation
/// - `<user: User>` - OpenAPI schema type annotation
/// - `<file: "data.json">` - Quoted string literal (an opaque value, never a property path)
public struct QualifiedNoun: Sendable, Equatable, CustomStringConvertible {
    public let base: String
    public let typeAnnotation: String?  // Raw type string (e.g., "String", "List<User>")
    public let span: SourceSpan

    /// The `as <Type>` result annotation, when present.
    ///
    /// Kept separate from `typeAnnotation` because the two are different things:
    /// the qualifier selects an *operation* (`<n: length>`), while `as` requests a
    /// *result type* (`as Float`). The parser used to overwrite `typeAnnotation`
    /// with the `as` type, which silently discarded the operation — so
    /// `Compute the <m: length> as Integer from <s>.` computed the identity and
    /// returned the string, not its length (GitLab #475).
    public let asType: String?

    /// True when the qualifier was written as a quoted string literal, e.g. `<file: "data.json">`.
    ///
    /// A quoted literal is a value, not a property path, so it must never be split on `.`.
    /// Without this the extension of a bare relative filename is silently discarded and
    /// `<file: "data.json">` resolves to the path `data`.
    public let isLiteralQualifier: Bool

    /// What the qualifier is, decided once when the noun is built.
    public let qualifier: Qualifier

    /// The qualifier as a flat array — a property path split on dots, a
    /// literal, chain or generic kept whole, nothing at all when absent.
    public var specifiers: [String] {
        qualifier.specifiers
    }

    /// Whether this noun has a chained qualifier annotation (contains |)
    ///
    /// Reads the raw annotation rather than `qualifier`, because a quoted
    /// literal that happens to contain `|` answers `true` here and is still
    /// opaque to `specifiers`. Folding the two would change that.
    public var isQualifierChain: Bool {
        typeAnnotation?.contains("|") == true
    }

    /// Returns the individual qualifier names in a chain, or nil if not a chain.
    /// For "stats.sort|list.take" returns ["stats.sort", "list.take"].
    public var qualifierChain: [String]? {
        guard let type = typeAnnotation, type.contains("|") else { return nil }
        return type.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public init(
        base: String,
        typeAnnotation: String? = nil,
        span: SourceSpan,
        asType: String? = nil,
        isLiteralQualifier: Bool = false
    ) {
        self.base = base
        self.typeAnnotation = typeAnnotation
        self.span = span
        self.asType = asType
        self.isLiteralQualifier = isLiteralQualifier
        self.qualifier = Qualifier(annotation: typeAnnotation, isLiteral: isLiteralQualifier)
    }

    /// Initializer for when you have a specifiers array (joins with dots)
    public init(base: String, specifiers: [String], span: SourceSpan) {
        let annotation = specifiers.isEmpty ? nil : specifiers.joined(separator: ".")
        self.base = base
        self.typeAnnotation = annotation
        self.span = span
        self.asType = nil
        self.isLiteralQualifier = false
        self.qualifier = Qualifier(annotation: annotation, isLiteral: false)
    }

    /// The full qualified name
    public var fullName: String {
        if let type = typeAnnotation {
            return "\(base): \(type)"
        }
        return base
    }

    /// Get the parsed DataType (ARO-0006)
    public var dataType: DataType? {
        guard let type = typeAnnotation else { return nil }
        return DataType.parse(type)
    }

    /// Check if this noun has a type annotation
    public var hasTypeAnnotation: Bool {
        typeAnnotation != nil
    }

    public var description: String {
        fullName
    }
}

// MARK: - Object Clause

/// A literal value that can be passed with an ARO statement
public indirect enum LiteralValue: Sendable, Equatable, CustomStringConvertible {
    case string(String)
    case integer(Int)
    case float(Double)
    case boolean(Bool)
    case null
    case array([LiteralValue])
    case object([(String, LiteralValue)])
    case regex(pattern: String, flags: String)

    public var description: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .integer(let i): return "\(i)"
        case .float(let f): return "\(f)"
        case .boolean(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let elements):
            let items = elements.map { $0.description }.joined(separator: ", ")
            return "[\(items)]"
        case .object(let fields):
            let items = fields.map { "\($0.0): \($0.1.description)" }.joined(separator: ", ")
            return "{\(items)}"
        case .regex(let pattern, let flags): return "/\(pattern)/\(flags)"
        }
    }

    public static func == (lhs: LiteralValue, rhs: LiteralValue) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.float(let a), .float(let b)): return a == b
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (i, (keyA, valA)) in a.enumerated() {
                let (keyB, valB) = b[i]
                if keyA != keyB || valA != valB { return false }
            }
            return true
        case (.regex(let patternA, let flagsA), .regex(let patternB, let flagsB)):
            return patternA == patternB && flagsA == flagsB
        default: return false
        }
    }
}

/// The object part of an ARO statement
public struct ObjectClause: Sendable, Equatable, CustomStringConvertible {
    public let preposition: Preposition
    public let noun: QualifiedNoun
    
    public init(preposition: Preposition, noun: QualifiedNoun) {
        self.preposition = preposition
        self.noun = noun
    }
    
    /// Whether this references an external source
    public var isExternalReference: Bool {
        preposition.indicatesExternalSource
    }
    
    public var description: String {
        "\(preposition.rawValue) the <\(noun)>"
    }
}

// MARK: - Expressions (ARO-0002)

/// Base protocol for all expression nodes
public protocol Expression: ASTNode {
    /// Accepts an `ExpressionVisitor` for polymorphic dispatch (#338).
    /// A protocol requirement so the concrete node's implementation is
    /// dynamically dispatched even through an `any Expression` value.
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result
}

// MARK: - Literal Expressions

/// A literal value expression
public struct LiteralExpression: Expression {
    public let value: LiteralValue
    public let span: SourceSpan

    public init(value: LiteralValue, span: SourceSpan) {
        self.value = value
        self.span = span
    }

    public var description: String {
        value.description
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// An array literal expression: [1, 2, 3]
public struct ArrayLiteralExpression: Expression {
    public let elements: [any Expression]
    public let span: SourceSpan

    public init(elements: [any Expression], span: SourceSpan) {
        self.elements = elements
        self.span = span
    }

    public var description: String {
        "[\(elements.map { $0.description }.joined(separator: ", "))]"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// A map literal expression: { name: "John", age: 30 }
public struct MapLiteralExpression: Expression {
    public let entries: [MapEntry]
    public let span: SourceSpan

    public init(entries: [MapEntry], span: SourceSpan) {
        self.entries = entries
        self.span = span
    }

    public var description: String {
        "{ \(entries.map { $0.description }.joined(separator: ", ")) }"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// A single map entry
public struct MapEntry: Sendable, CustomStringConvertible {
    public let key: String
    public let value: any Expression
    public let span: SourceSpan

    public init(key: String, value: any Expression, span: SourceSpan) {
        self.key = key
        self.value = value
        self.span = span
    }

    public var description: String {
        "\(key): \(value.description)"
    }
}

// MARK: - Reference Expressions

/// A variable reference expression: <user> or <user: name>
public struct VariableRefExpression: Expression {
    public let noun: QualifiedNoun
    public let span: SourceSpan

    public init(noun: QualifiedNoun, span: SourceSpan) {
        self.noun = noun
        self.span = span
    }

    public var description: String {
        "<\(noun.fullName)>"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Operator Expressions

/// Binary operators
public enum BinaryOperator: String, Sendable, CaseIterable {
    // Arithmetic
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case modulo = "%"
    case concat = "++"

    // Comparison
    case equal = "=="
    case notEqual = "!="
    case lessThan = "<"
    case greaterThan = ">"
    case lessEqual = "<="
    case greaterEqual = ">="
    case `is` = "is"
    case isNot = "is not"
    /// Temporal comparison. Reads as the book writes it — `when
    /// <deadline> before <now>` — and orders the two instants the
    /// same way `<` and `>` order numbers (GitLab #516).
    case before = "before"
    case after = "after"
    /// Membership: `when <order-date> in <sale-period>`.
    ///
    /// ARO-0041 §7 specifies this for a `date-range`, and ARO-0042 for a
    /// collection. `where <field> in <list>` had it as a `WhereOperator`, and
    /// `contains` had it as this operator with the operands the other way
    /// round — but the guard spelling the proposals write did not parse at all
    /// (GitLab #558). It is the inverse of `contains`, and evaluates through
    /// the same code.
    case `in` = "in"

    /// `when <tag> not in <banned>` — the negation of `in`.
    ///
    /// `where` has had it since ARO-0042; the guard grammar had not, so a
    /// negative membership test in a `when` had to be written as a
    /// separate `Validate` statement (GitLab #830 item 5).
    case notIn = "not in"

    /// `when <path> starts with "/api"` / `when <name> ends with ".aro"`.
    ///
    /// Two words, neither of them a lexer keyword — `<starts>` and
    /// `<ends>` are names people write, and reserving them would break
    /// those the way GitLab #497 describes. Position disambiguates: after
    /// a complete expression, `starts`/`ends` can only be an operator.
    case startsWith = "starts with"
    case endsWith = "ends with"

    // Logical
    case and = "and"
    case or = "or"

    /// Value-returning fallback: `<params: count> default 3` (GitLab #547).
    ///
    /// Distinct from `or`, which stays strictly boolean. The left operand wins
    /// whenever it is *present* — an explicit `false`, `0` or `""` is a value
    /// and wins; only a missing variable, a missing field, or `nil`/`null`
    /// falls through to the right operand.
    case defaulting = "default"

    // Collection
    case contains = "contains"
    case matches = "matches"
    /// Set containment: `when <required-roles> subset of <user-roles>`.
    ///
    /// A *predicate*, so it belongs here with the condition operators rather
    /// than in ARO-0042's qualifier table, which holds the operations that
    /// produce a collection (GitLab #864). Written as an intersect plus a
    /// length comparison until this existed, which is two statements and a
    /// subtle one — `length(intersect) == length(required)` is only the same
    /// question when the required side has no duplicates.
    case subset = "subset of"

    /// True for comparison/equality operators (==, !=, <, >, <=, >=, is, is not, contains, matches)
    public var isComparison: Bool {
        switch self {
        case .equal, .notEqual, .lessThan, .greaterThan,
             .lessEqual, .greaterEqual, .is, .isNot,
             .contains, .matches, .subset:
            return true
        default:
            return false
        }
    }

    /// True for logical connectives (and, or)
    public var isLogical: Bool {
        self == .and || self == .or
    }
}

/// Unary operators
public enum UnaryOperator: String, Sendable, CaseIterable {
    case negate = "-"
    case not = "not"
}

/// A binary expression: a + b, x == y, etc.
public struct BinaryExpression: Expression {
    public let left: any Expression
    public let op: BinaryOperator
    public let right: any Expression
    public let span: SourceSpan

    public init(left: any Expression, op: BinaryOperator, right: any Expression, span: SourceSpan) {
        self.left = left
        self.op = op
        self.right = right
        self.span = span
    }

    public var description: String {
        "(\(left.description) \(op.rawValue) \(right.description))"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// A unary expression: -x, not x
public struct UnaryExpression: Expression {
    public let op: UnaryOperator
    public let operand: any Expression
    public let span: SourceSpan

    public init(op: UnaryOperator, operand: any Expression, span: SourceSpan) {
        self.op = op
        self.operand = operand
        self.span = span
    }

    public var description: String {
        "(\(op.rawValue)\(operand.description))"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Access Expressions

/// Member access expression: <user>.name
public struct MemberAccessExpression: Expression {
    public let base: any Expression
    public let member: String
    public let span: SourceSpan

    public init(base: any Expression, member: String, span: SourceSpan) {
        self.base = base
        self.member = member
        self.span = span
    }

    public var description: String {
        "\(base.description).\(member)"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// Subscript expression: <items>[0]
public struct SubscriptExpression: Expression {
    public let base: any Expression
    public let index: any Expression
    public let span: SourceSpan

    public init(base: any Expression, index: any Expression, span: SourceSpan) {
        self.base = base
        self.index = index
        self.span = span
    }

    public var description: String {
        "\(base.description)[\(index.description)]"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Special Expressions

/// Grouped (parenthesized) expression: (expr)
public struct GroupedExpression: Expression {
    public let expression: any Expression
    public let span: SourceSpan

    public init(expression: any Expression, span: SourceSpan) {
        self.expression = expression
        self.span = span
    }

    public var description: String {
        "(\(expression.description))"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// Existence check expression: <x> exists
public struct ExistenceExpression: Expression {
    public let expression: any Expression
    public let span: SourceSpan

    public init(expression: any Expression, span: SourceSpan) {
        self.expression = expression
        self.span = span
    }

    public var description: String {
        "\(expression.description) exists"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

/// Type check expression: <x> is a Number
/// `<collection> is empty` / `<collection> is not empty` (ARO-0002).
///
/// Kept as its own node rather than desugared to a length
/// comparison: emptiness is defined across strings, lists and
/// objects, and `length == 0` would have to pick one meaning for
/// a nil value. Here nil *is* empty, which is what the guard in
/// `when <username> is empty` is asking about.
public struct EmptinessCheckExpression: Expression {
    public let expression: any Expression
    /// True for `is not empty`.
    public let negated: Bool
    public let span: SourceSpan

    public init(expression: any Expression, negated: Bool, span: SourceSpan) {
        self.expression = expression
        self.negated = negated
        self.span = span
    }

    public var description: String {
        "\(expression.description) is \(negated ? "not " : "")empty"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

public struct TypeCheckExpression: Expression {
    public let expression: any Expression
    public let typeName: String
    public let hasArticle: Bool
    public let span: SourceSpan

    public init(expression: any Expression, typeName: String, hasArticle: Bool, span: SourceSpan) {
        self.expression = expression
        self.typeName = typeName
        self.hasArticle = hasArticle
        self.span = span
    }

    public var description: String {
        if hasArticle {
            return "\(expression.description) is a \(typeName)"
        }
        return "\(expression.description) is \(typeName)"
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - String Interpolation

/// Part of an interpolated string
public enum StringPart: Sendable, CustomStringConvertible {
    case literal(String)
    case interpolation(any Expression)

    public var description: String {
        switch self {
        case .literal(let s): return s
        case .interpolation(let expr): return "${\(expr.description)}"
        }
    }
}

/// Interpolated string expression: "Hello ${<name>}!"
public struct InterpolatedStringExpression: Expression {
    public let parts: [StringPart]
    public let span: SourceSpan

    public init(parts: [StringPart], span: SourceSpan) {
        self.parts = parts
        self.span = span
    }

    public var description: String {
        "\"\(parts.map { $0.description }.joined())\""
    }

    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Statement Visitor Protocol

/// Visitor for polymorphic dispatch over `Statement` nodes (#338).
///
/// Analyzers that previously walked a chain of `if let x = stmt as? Type`
/// casts can instead conform to `StatementVisitor` and let each statement
/// node dispatch itself via `accept(_:)`. Adding a new statement node type
/// then surfaces as a missing protocol requirement (a compile-time error at
/// the visitor) rather than a silently-skipped branch in every analyzer.
///
/// There is a `visit` requirement for **every** concrete `Statement` node,
/// so a conforming visitor must decide what each node means — including the
/// nodes that legacy `as?`-chains handled only via a trailing `else`
/// fallback. To preserve that fallback behaviour, a conformer can provide a
/// single catch-all through the `Result`-specific default implementations it
/// writes; this protocol itself has no defaults, keeping dispatch explicit.
public protocol StatementVisitor {
    associatedtype Result

    func visit(_ node: AROStatement) -> Result
    func visit(_ node: PublishStatement) -> Result
    func visit(_ node: RequireStatement) -> Result
    func visit(_ node: MatchStatement) -> Result
    func visit(_ node: WhenStatement) -> Result
    func visit(_ node: ForEachLoop) -> Result
    func visit(_ node: WhileLoop) -> Result
    func visit(_ node: BreakStatement) -> Result
    func visit(_ node: RangeLoop) -> Result
    func visit(_ node: PipelineStatement) -> Result
    func visit(_ node: ErrorStatement) -> Result
}

public extension AROStatement {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension PublishStatement {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension RequireStatement {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension MatchStatement {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension WhenStatement {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension ForEachLoop {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension WhileLoop {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension BreakStatement {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension RangeLoop {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension PipelineStatement {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension ErrorStatement {
    func accept<V: StatementVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}

/// Dispatches a `Statement` to `AROStatement` (or nil) via `StatementVisitor`
/// rather than a raw `as?` cast (#434). Every node type is enumerated, so a
/// new `Statement` kind surfaces as a missing `visit` requirement here instead
/// of silently taking the nil path at every call site.
private struct AROStatementExtractor: StatementVisitor {
    func visit(_ node: AROStatement) -> AROStatement? { node }
    func visit(_ node: PublishStatement) -> AROStatement? { nil }
    func visit(_ node: RequireStatement) -> AROStatement? { nil }
    func visit(_ node: MatchStatement) -> AROStatement? { nil }
    func visit(_ node: WhenStatement) -> AROStatement? { nil }
    func visit(_ node: ForEachLoop) -> AROStatement? { nil }
    func visit(_ node: WhileLoop) -> AROStatement? { nil }
    func visit(_ node: BreakStatement) -> AROStatement? { nil }
    func visit(_ node: RangeLoop) -> AROStatement? { nil }
    func visit(_ node: PipelineStatement) -> AROStatement? { nil }
    func visit(_ node: ErrorStatement) -> AROStatement? { nil }
}

public extension Statement {
    /// The receiver as an `AROStatement` when it is one, else nil — resolved
    /// through `StatementVisitor` dispatch so the statement taxonomy stays
    /// compile-time-checked (#434).
    var asAROStatement: AROStatement? { accept(AROStatementExtractor()) }
}

// MARK: - Expression Visitor Protocol

/// Visitor for polymorphic dispatch over `Expression` nodes (#338).
///
/// Mirrors `StatementVisitor` for the expression side so that variable
/// collection and similar walks can dispatch instead of type-testing.
public protocol ExpressionVisitor {
    associatedtype Result

    func visit(_ node: LiteralExpression) -> Result
    func visit(_ node: ArrayLiteralExpression) -> Result
    func visit(_ node: MapLiteralExpression) -> Result
    func visit(_ node: VariableRefExpression) -> Result
    func visit(_ node: BinaryExpression) -> Result
    func visit(_ node: UnaryExpression) -> Result
    func visit(_ node: MemberAccessExpression) -> Result
    func visit(_ node: SubscriptExpression) -> Result
    func visit(_ node: GroupedExpression) -> Result
    func visit(_ node: ExistenceExpression) -> Result
    func visit(_ node: TypeCheckExpression) -> Result
    func visit(_ node: EmptinessCheckExpression) -> Result
    func visit(_ node: InterpolatedStringExpression) -> Result
}

public extension LiteralExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension ArrayLiteralExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension MapLiteralExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension VariableRefExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension BinaryExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension UnaryExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension MemberAccessExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension SubscriptExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension GroupedExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension ExistenceExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension TypeCheckExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension EmptinessCheckExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}
public extension InterpolatedStringExpression {
    func accept<V: ExpressionVisitor>(_ visitor: V) -> V.Result { visitor.visit(self) }
}

// MARK: - AST Visitor Protocol

/// Visitor pattern for AST traversal
public protocol ASTVisitor {
    associatedtype Result

    func visit(_ node: Program) throws -> Result
    func visit(_ node: ImportDeclaration) throws -> Result
    func visit(_ node: FeatureSet) throws -> Result
    func visit(_ node: AROStatement) throws -> Result
    func visit(_ node: PublishStatement) throws -> Result
    func visit(_ node: RequireStatement) throws -> Result
    func visit(_ node: MatchStatement) throws -> Result
    func visit(_ node: WhenStatement) throws -> Result
    func visit(_ node: ForEachLoop) throws -> Result
    func visit(_ node: WhileLoop) throws -> Result
    func visit(_ node: BreakStatement) throws -> Result
    func visit(_ node: RangeLoop) throws -> Result
    func visit(_ node: PipelineStatement) throws -> Result
    func visit(_ node: ErrorStatement) throws -> Result

    // Expression visitors (ARO-0002)
    func visit(_ node: LiteralExpression) throws -> Result
    func visit(_ node: ArrayLiteralExpression) throws -> Result
    func visit(_ node: MapLiteralExpression) throws -> Result
    func visit(_ node: VariableRefExpression) throws -> Result
    func visit(_ node: BinaryExpression) throws -> Result
    func visit(_ node: UnaryExpression) throws -> Result
    func visit(_ node: MemberAccessExpression) throws -> Result
    func visit(_ node: SubscriptExpression) throws -> Result
    func visit(_ node: GroupedExpression) throws -> Result
    func visit(_ node: ExistenceExpression) throws -> Result
    func visit(_ node: TypeCheckExpression) throws -> Result
    func visit(_ node: EmptinessCheckExpression) throws -> Result
    func visit(_ node: InterpolatedStringExpression) throws -> Result
}

/// Default implementations that traverse children
public extension ASTVisitor where Result == Void {
    func visit(_ node: Program) throws {
        for importDecl in node.imports {
            try importDecl.accept(self)
        }
        for featureSet in node.featureSets {
            try featureSet.accept(self)
        }
    }

    func visit(_ node: ImportDeclaration) throws {}

    func visit(_ node: FeatureSet) throws {
        for statement in node.statements {
            try statement.accept(self)
        }
    }

    func visit(_ node: AROStatement) throws {}
    func visit(_ node: PublishStatement) throws {}
    func visit(_ node: RequireStatement) throws {}
    func visit(_ node: ErrorStatement) throws {}
    func visit(_ node: WhenStatement) throws {
        for statement in node.body {
            try statement.accept(self)
        }
    }
    func visit(_ node: MatchStatement) throws {
        for caseClause in node.cases {
            for statement in caseClause.body {
                try statement.accept(self)
            }
        }
        if let otherwise = node.otherwise {
            for statement in otherwise {
                try statement.accept(self)
            }
        }
    }

    func visit(_ node: ForEachLoop) throws {
        for statement in node.body {
            try statement.accept(self)
        }
    }

    func visit(_ node: WhileLoop) throws {
        for statement in node.body {
            try statement.accept(self)
        }
    }

    func visit(_ node: BreakStatement) throws {}

    func visit(_ node: RangeLoop) throws {
        for statement in node.body {
            try statement.accept(self)
        }
    }

    func visit(_ node: PipelineStatement) throws {
        for stage in node.stages {
            try stage.accept(self)
        }
    }

    // Expression default implementations
    func visit(_ node: LiteralExpression) throws {}
    func visit(_ node: ArrayLiteralExpression) throws {
        for element in node.elements {
            try element.accept(self)
        }
    }
    func visit(_ node: MapLiteralExpression) throws {
        for entry in node.entries {
            try entry.value.accept(self)
        }
    }
    func visit(_ node: VariableRefExpression) throws {}
    func visit(_ node: BinaryExpression) throws {
        try node.left.accept(self)
        try node.right.accept(self)
    }
    func visit(_ node: UnaryExpression) throws {
        try node.operand.accept(self)
    }
    func visit(_ node: MemberAccessExpression) throws {
        try node.base.accept(self)
    }
    func visit(_ node: SubscriptExpression) throws {
        try node.base.accept(self)
        try node.index.accept(self)
    }
    func visit(_ node: GroupedExpression) throws {
        try node.expression.accept(self)
    }
    func visit(_ node: ExistenceExpression) throws {
        try node.expression.accept(self)
    }
    func visit(_ node: TypeCheckExpression) throws {
        try node.expression.accept(self)
    }
    func visit(_ node: EmptinessCheckExpression) throws {
        try node.expression.accept(self)
    }
    func visit(_ node: InterpolatedStringExpression) throws {
        for part in node.parts {
            if case .interpolation(let expr) = part {
                try expr.accept(self)
            }
        }
    }
}
