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

// MARK: - Program (Root Node)

/// The root node representing an entire ARO program
public struct Program: ASTNode {
    public let featureSets: [FeatureSet]
    public let span: SourceSpan
    
    public init(featureSets: [FeatureSet], span: SourceSpan) {
        self.featureSets = featureSets
        self.span = span
    }
    
    public var description: String {
        "Program(\(featureSets.count) feature sets)"
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
    public let span: SourceSpan
    
    public init(name: String, businessActivity: String, statements: [Statement], span: SourceSpan) {
        self.name = name
        self.businessActivity = businessActivity
        self.statements = statements
        self.span = span
    }
    
    public var description: String {
        "FeatureSet(\(name): \(businessActivity), \(statements.count) statements)"
    }
    
    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

// MARK: - Statements

/// Protocol for all statement types
public protocol Statement: ASTNode {}

/// An ARO (Action-Result-Object) statement
public struct AROStatement: Statement {
    public let action: Action
    public let result: QualifiedNoun
    public let object: ObjectClause
    /// Optional literal value (e.g., `with "string"`, `with 42`)
    public let literalValue: LiteralValue?
    public let span: SourceSpan

    public init(action: Action, result: QualifiedNoun, object: ObjectClause, literalValue: LiteralValue? = nil, span: SourceSpan) {
        self.action = action
        self.result = result
        self.object = object
        self.literalValue = literalValue
        self.span = span
    }

    public var description: String {
        var desc = "<\(action.verb)> the <\(result)> \(object.preposition) the <\(object.noun)>"
        if let literal = literalValue {
            desc += " with \(literal)"
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
        "<Publish> as <\(externalName)> <\(internalVariable)>."
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
    
    /// Classifies a verb into its semantic role
    public static func classify(verb: String) -> ActionSemanticRole {
        let lower = verb.lowercased()
        
        let requestVerbs = ["extract", "parse", "retrieve", "fetch", "read", "receive", "get", "load"]
        let responseVerbs = ["return", "throw", "send", "emit", "respond", "output", "write"]
        let exportVerbs = ["publish", "export", "expose", "share"]
        
        if requestVerbs.contains(lower) { return .request }
        if responseVerbs.contains(lower) { return .response }
        if exportVerbs.contains(lower) { return .export }
        return .own
    }
}

// MARK: - Qualified Noun

/// A noun with optional specifiers (e.g., <user: identifier name>)
public struct QualifiedNoun: Sendable, Equatable, CustomStringConvertible {
    public let base: String
    public let specifiers: [String]
    public let span: SourceSpan
    
    public init(base: String, specifiers: [String] = [], span: SourceSpan) {
        self.base = base
        self.specifiers = specifiers
        self.span = span
    }
    
    /// The full qualified name
    public var fullName: String {
        if specifiers.isEmpty {
            return base
        }
        return "\(base): \(specifiers.joined(separator: " "))"
    }
    
    public var description: String {
        fullName
    }
}

// MARK: - Object Clause

/// A literal value that can be passed with an ARO statement
public enum LiteralValue: Sendable, Equatable, CustomStringConvertible {
    case string(String)
    case integer(Int)
    case float(Double)
    case boolean(Bool)
    case null

    public var description: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .integer(let i): return "\(i)"
        case .float(let f): return "\(f)"
        case .boolean(let b): return b ? "true" : "false"
        case .null: return "null"
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

// MARK: - AST Visitor Protocol

/// Visitor pattern for AST traversal
public protocol ASTVisitor {
    associatedtype Result
    
    func visit(_ node: Program) throws -> Result
    func visit(_ node: FeatureSet) throws -> Result
    func visit(_ node: AROStatement) throws -> Result
    func visit(_ node: PublishStatement) throws -> Result
}

/// Default implementations that traverse children
public extension ASTVisitor where Result == Void {
    func visit(_ node: Program) throws {
        for featureSet in node.featureSets {
            try featureSet.accept(self)
        }
    }
    
    func visit(_ node: FeatureSet) throws {
        for statement in node.statements {
            try statement.accept(self)
        }
    }
    
    func visit(_ node: AROStatement) throws {}
    func visit(_ node: PublishStatement) throws {}
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
        for featureSet in node.featureSets {
            result += try! featureSet.accept(printer)
        }
        return result
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
}
