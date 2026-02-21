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
    public let span: SourceSpan

    public init(name: String, businessActivity: String, statements: [Statement], whenCondition: (any Expression)? = nil, span: SourceSpan) {
        self.name = name
        self.businessActivity = businessActivity
        self.statements = statements
        self.whenCondition = whenCondition
        self.span = span
    }

    public var description: String {
        let whenDesc = whenCondition != nil ? " when ..." : ""
        return "FeatureSet(\(name): \(businessActivity)\(whenDesc), \(statements.count) statements)"
    }
    
    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Statements

/// Protocol for all statement types
public protocol Statement: ASTNode {}

/// An ARO (Action-Result-Object) statement
///
/// Refactored to use grouped clause types for better semantic organization:
/// - `valueSource`: Where the value comes from (literal, expression, sink)
/// - `queryModifiers`: Query-related clauses (where, aggregation, by)
/// - `rangeModifiers`: Range/set operation clauses (to, with)
/// - `statementGuard`: Optional condition for guarded execution
public struct AROStatement: Statement {
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
        if let where_ = queryModifiers.whereClause {
            desc += " where \(where_)"
        }
        if let by = queryModifiers.byClause {
            desc += " \(by)"
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
    public let externalName: String
    public let internalVariable: String
    public let span: SourceSpan
    
    public init(externalName: String, internalVariable: String, span: SourceSpan) {
        self.externalName = externalName
        self.internalVariable = internalVariable
        self.span = span
    }
    
    public var description: String {
        "Publish as <\(externalName)> <\(internalVariable)>."
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
    case `in` = "in"          // ARO-0042: membership test
    case notIn = "not in"     // ARO-0042: negative membership test

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

// MARK: - By Clause (ARO-0037)

/// A by clause for regex-based splitting: by /pattern/flags
public struct ByClause: Sendable, CustomStringConvertible {
    public let pattern: String
    public let flags: String
    public let span: SourceSpan

    public init(pattern: String, flags: String, span: SourceSpan) {
        self.pattern = pattern
        self.flags = flags
        self.span = span
    }

    public var description: String {
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
    /// Filter condition: `where <field> is "value"`
    public let whereClause: WhereClause?

    /// Aggregation function: `with sum(<field>)`
    public let aggregation: AggregationClause?

    /// Split pattern: `by /delimiter/`
    public let byClause: ByClause?

    public init(
        whereClause: WhereClause? = nil,
        aggregation: AggregationClause? = nil,
        byClause: ByClause? = nil
    ) {
        self.whereClause = whereClause
        self.aggregation = aggregation
        self.byClause = byClause
    }

    /// Empty query modifiers
    public static let none = QueryModifiers()

    /// Check if any query modifier is present
    public var isEmpty: Bool {
        whereClause == nil && aggregation == nil && byClause == nil
    }

    public var description: String {
        var parts: [String] = []
        if let w = whereClause { parts.append("where \(w)") }
        if let a = aggregation { parts.append("with \(a)") }
        if let b = byClause { parts.append("\(b)") }
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

    public init(
        toClause: (any Expression)? = nil,
        withClause: (any Expression)? = nil
    ) {
        self.toClause = toClause
        self.withClause = withClause
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
public struct MatchStatement: Statement {
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
public struct ForEachLoop: Statement {
    public let itemVariable: String
    public let indexVariable: String?
    public let collection: QualifiedNoun
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
        self.filter = filter
        self.isParallel = isParallel
        self.concurrency = concurrency
        self.body = body
        self.span = span
    }

    public var description: String {
        var desc = isParallel ? "parallel " : ""
        desc += "for each <\(itemVariable)>"
        if let index = indexVariable {
            desc += " at <\(index)>"
        }
        desc += " in <\(collection.fullName)>"
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
    public static func classify(verb: String) -> ActionSemanticRole {
        let lower = verb.lowercased()

        let requestVerbs = ["extract", "parse", "retrieve", "fetch", "read", "receive", "get", "load"]
        let responseVerbs = ["return", "throw", "send", "emit", "respond", "output", "write", "store", "save", "persist", "log", "print", "debug", "notify", "alert", "signal", "broadcast"]
        let exportVerbs = ["publish", "export", "expose", "share"]
        let serverVerbs = ["start", "stop", "listen", "await", "connect", "close", "disconnect", "terminate", "wait", "keepalive", "block", "make", "touch", "mkdir", "createdirectory", "copy", "move", "rename"]

        if requestVerbs.contains(lower) { return .request }
        if responseVerbs.contains(lower) { return .response }
        if exportVerbs.contains(lower) { return .export }
        if serverVerbs.contains(lower) { return .server }
        return .own
    }
}

// MARK: - Qualified Noun

/// A noun with optional type annotation (ARO-0006)
///
/// Examples:
/// - `<user>` - Untyped variable
/// - `<name: String>` - Primitive type annotation
/// - `<items: List<Order>>` - Collection type annotation
/// - `<user: User>` - OpenAPI schema type annotation
public struct QualifiedNoun: Sendable, Equatable, CustomStringConvertible {
    public let base: String
    public let typeAnnotation: String?  // Raw type string (e.g., "String", "List<User>")
    public let span: SourceSpan

    // Specifiers are parsed from typeAnnotation as dot-separated property path
    public var specifiers: [String] {
        guard let type = typeAnnotation else { return [] }
        // If it contains < it's a generic type like List<User>, return as single element
        if type.contains("<") {
            return [type]
        }
        // If it looks like a file path, don't split by dots (preserve extensions)
        // File paths start with /, ./, ../, or ~ (home directory)
        if type.hasPrefix("/") || type.hasPrefix("./") || type.hasPrefix("../") || type.hasPrefix("~") {
            return [type]
        }
        // If it looks like a URL, don't split by dots (ARO-0052)
        if type.hasPrefix("http://") || type.hasPrefix("https://") {
            return [type]
        }
        // Split by dots for property path syntax (e.g., "customer.address.city")
        return type.split(separator: ".").map(String.init)
    }

    public init(base: String, typeAnnotation: String? = nil, span: SourceSpan) {
        self.base = base
        self.typeAnnotation = typeAnnotation
        self.span = span
    }

    /// Initializer for when you have a specifiers array (joins with dots)
    public init(base: String, specifiers: [String], span: SourceSpan) {
        self.base = base
        self.typeAnnotation = specifiers.isEmpty ? nil : specifiers.joined(separator: ".")
        self.span = span
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
public protocol Expression: ASTNode {}

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

    // Logical
    case and = "and"
    case or = "or"

    // Collection
    case contains = "contains"
    case matches = "matches"
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
    func visit(_ node: ForEachLoop) throws -> Result

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
    func visit(_ node: InterpolatedStringExpression) throws {
        for part in node.parts {
            if case .interpolation(let expr) = part {
                try expr.accept(self)
            }
        }
    }
}

// MARK: - AST Pretty Printer

/// Prints the AST in a readable format
public struct ASTPrinter: ASTVisitor {
    public typealias Result = String
    
    private var indent: Int = 0
    
    public init() {}
    
    private func indentation() -> String {
        String(repeating: "  ", count: indent)
    }
    
    public func visit(_ node: Program) -> String {
        var result = "Program\n"
        var printer = self
        printer.indent += 1
        for importDecl in node.imports {
            result += try! importDecl.accept(printer)
        }
        for featureSet in node.featureSets {
            result += try! featureSet.accept(printer)
        }
        return result
    }

    public func visit(_ node: ImportDeclaration) -> String {
        "\(indentation())Import: \(node.path)\n"
    }

    public func visit(_ node: FeatureSet) -> String {
        var result = "\(indentation())FeatureSet: \(node.name)\n"
        result += "\(indentation())  BusinessActivity: \(node.businessActivity)\n"
        
        var printer = self
        printer.indent += 1
        for statement in node.statements {
            result += try! statement.accept(printer)
        }
        return result
    }
    
    public func visit(_ node: AROStatement) -> String {
        var result = "\(indentation())AROStatement\n"
        result += "\(indentation())  Action: \(node.action.verb) [\(node.action.semanticRole)]\n"
        result += "\(indentation())  Result: \(node.result.fullName)\n"
        result += "\(indentation())  Object: \(node.object.preposition.rawValue) \(node.object.noun.fullName)\n"
        return result
    }
    
    public func visit(_ node: PublishStatement) -> String {
        var result = "\(indentation())PublishStatement\n"
        result += "\(indentation())  External: \(node.externalName)\n"
        result += "\(indentation())  Internal: \(node.internalVariable)\n"
        return result
    }

    public func visit(_ node: RequireStatement) -> String {
        var result = "\(indentation())RequireStatement\n"
        result += "\(indentation())  Variable: \(node.variableName)\n"
        result += "\(indentation())  Source: \(node.source)\n"
        return result
    }

    public func visit(_ node: MatchStatement) -> String {
        var result = "\(indentation())MatchStatement\n"
        result += "\(indentation())  Subject: <\(node.subject.fullName)>\n"
        var printer = self
        printer.indent += 1
        for caseClause in node.cases {
            result += "\(printer.indentation())Case: \(caseClause.pattern)\n"
            if let guard_ = caseClause.guardCondition {
                result += "\(printer.indentation())  Guard: \(guard_)\n"
            }
            var bodyPrinter = printer
            bodyPrinter.indent += 1
            for statement in caseClause.body {
                result += try! statement.accept(bodyPrinter)
            }
        }
        if let otherwise = node.otherwise {
            result += "\(printer.indentation())Otherwise:\n"
            var otherwisePrinter = printer
            otherwisePrinter.indent += 1
            for statement in otherwise {
                result += try! statement.accept(otherwisePrinter)
            }
        }
        return result
    }

    public func visit(_ node: ForEachLoop) -> String {
        var result = "\(indentation())ForEachLoop\n"
        result += "\(indentation())  Item: <\(node.itemVariable)>\n"
        if let index = node.indexVariable {
            result += "\(indentation())  Index: <\(index)>\n"
        }
        result += "\(indentation())  Collection: <\(node.collection.fullName)>\n"
        result += "\(indentation())  Parallel: \(node.isParallel)\n"
        if let concurrency = node.concurrency {
            result += "\(indentation())  Concurrency: \(concurrency)\n"
        }
        if let filter = node.filter {
            result += "\(indentation())  Filter: \(filter)\n"
        }
        var printer = self
        printer.indent += 1
        result += "\(indentation())  Body:\n"
        for statement in node.body {
            result += try! statement.accept(printer)
        }
        return result
    }

    // Expression visitors
    public func visit(_ node: LiteralExpression) -> String {
        "\(indentation())Literal: \(node.value)\n"
    }

    public func visit(_ node: ArrayLiteralExpression) -> String {
        var result = "\(indentation())Array[\(node.elements.count)]\n"
        var printer = self
        printer.indent += 1
        for element in node.elements {
            result += try! element.accept(printer)
        }
        return result
    }

    public func visit(_ node: MapLiteralExpression) -> String {
        var result = "\(indentation())Map{\(node.entries.count)}\n"
        var printer = self
        printer.indent += 1
        for entry in node.entries {
            result += "\(printer.indentation())\(entry.key):\n"
            printer.indent += 1
            result += try! entry.value.accept(printer)
            printer.indent -= 1
        }
        return result
    }

    public func visit(_ node: VariableRefExpression) -> String {
        "\(indentation())VarRef: <\(node.noun.fullName)>\n"
    }

    public func visit(_ node: BinaryExpression) -> String {
        var result = "\(indentation())Binary: \(node.op.rawValue)\n"
        var printer = self
        printer.indent += 1
        result += try! node.left.accept(printer)
        result += try! node.right.accept(printer)
        return result
    }

    public func visit(_ node: UnaryExpression) -> String {
        var result = "\(indentation())Unary: \(node.op.rawValue)\n"
        var printer = self
        printer.indent += 1
        result += try! node.operand.accept(printer)
        return result
    }

    public func visit(_ node: MemberAccessExpression) -> String {
        var result = "\(indentation())MemberAccess: .\(node.member)\n"
        var printer = self
        printer.indent += 1
        result += try! node.base.accept(printer)
        return result
    }

    public func visit(_ node: SubscriptExpression) -> String {
        var result = "\(indentation())Subscript\n"
        var printer = self
        printer.indent += 1
        result += "\(printer.indentation())base:\n"
        printer.indent += 1
        result += try! node.base.accept(printer)
        printer.indent -= 1
        result += "\(printer.indentation())index:\n"
        printer.indent += 1
        result += try! node.index.accept(printer)
        return result
    }

    public func visit(_ node: GroupedExpression) -> String {
        var result = "\(indentation())Grouped\n"
        var printer = self
        printer.indent += 1
        result += try! node.expression.accept(printer)
        return result
    }

    public func visit(_ node: ExistenceExpression) -> String {
        var result = "\(indentation())Exists\n"
        var printer = self
        printer.indent += 1
        result += try! node.expression.accept(printer)
        return result
    }

    public func visit(_ node: TypeCheckExpression) -> String {
        var result = "\(indentation())TypeCheck: \(node.typeName)\n"
        var printer = self
        printer.indent += 1
        result += try! node.expression.accept(printer)
        return result
    }

    public func visit(_ node: InterpolatedStringExpression) -> String {
        var result = "\(indentation())InterpolatedString[\(node.parts.count) parts]\n"
        var printer = self
        printer.indent += 1
        for part in node.parts {
            switch part {
            case .literal(let s):
                result += "\(printer.indentation())literal: \"\(s)\"\n"
            case .interpolation(let expr):
                result += "\(printer.indentation())interpolation:\n"
                printer.indent += 1
                result += try! expr.accept(printer)
                printer.indent -= 1
            }
        }
        return result
    }
}
