// ============================================================
// SymbolTable.swift
// ARO Parser - Symbol Table & Scoping
// ============================================================

import Foundation

// MARK: - Symbol

/// Represents a variable or binding in the program
public struct Symbol: Sendable, Equatable, CustomStringConvertible {
    public let name: String
    public let definedAt: SourceSpan
    public let visibility: Visibility
    public let source: SymbolSource
    public let dataType: DataType?
    
    public init(
        name: String,
        definedAt: SourceSpan,
        visibility: Visibility = .internal,
        source: SymbolSource,
        dataType: DataType? = nil
    ) {
        self.name = name
        self.definedAt = definedAt
        self.visibility = visibility
        self.source = source
        self.dataType = dataType
    }
    
    public var description: String {
        var result = "\(name): \(visibility)"
        if let type = dataType {
            result += " (\(type))"
        }
        result += " [source: \(source)]"
        return result
    }
}

// MARK: - Visibility

/// Visibility of a symbol
public enum Visibility: String, Sendable {
    case `internal`     // Only visible within the feature set
    case published      // Visible to other feature sets
    case external       // Defined outside this feature set
}

// MARK: - Symbol Source

/// Where a symbol gets its value from
public enum SymbolSource: Sendable, Equatable, CustomStringConvertible {
    case extracted(from: String)    // Extracted from external source
    case computed                   // Computed internally
    case parameter                  // Passed as parameter
    case alias(of: String)          // Alias of another symbol
    
    public var description: String {
        switch self {
        case .extracted(let from): return "extracted from \(from)"
        case .computed: return "computed"
        case .parameter: return "parameter"
        case .alias(let of): return "alias of \(of)"
        }
    }
}

// MARK: - Data Type

/// Simple type system for symbols
public enum DataType: Sendable, Equatable, CustomStringConvertible {
    case string
    case identifier
    case hash
    case record
    case status
    case boolean
    case error
    case custom(String)
    
    public var description: String {
        switch self {
        case .string: return "String"
        case .identifier: return "Identifier"
        case .hash: return "Hash"
        case .record: return "Record"
        case .status: return "Status"
        case .boolean: return "Boolean"
        case .error: return "Error"
        case .custom(let name): return name
        }
    }
    
    /// Infers type from specifiers
    public static func infer(from specifiers: [String]) -> DataType? {
        guard let first = specifiers.first?.lowercased() else { return nil }
        
        switch first {
        case "identifier", "id": return .identifier
        case "hash", "checksum": return .hash
        case "record": return .record
        case "status": return .status
        case "result": return .boolean
        case "error": return .error
        default: return .custom(first.capitalized)
        }
    }
}

// MARK: - Symbol Table

/// A scoped symbol table
public final class SymbolTable: Sendable, CustomStringConvertible {
    
    // MARK: - Properties
    
    public let scopeId: String
    public let scopeName: String
    private let parent: SymbolTable?
    private let _symbols: [String: Symbol]
    
    // MARK: - Initialization
    
    public init(scopeId: String, scopeName: String, parent: SymbolTable? = nil, symbols: [String: Symbol] = [:]) {
        self.scopeId = scopeId
        self.scopeName = scopeName
        self.parent = parent
        self._symbols = symbols
    }
    
    // MARK: - Lookup
    
    /// Looks up a symbol by name in this scope and parent scopes
    public func lookup(_ name: String) -> Symbol? {
        if let symbol = _symbols[name] {
            return symbol
        }
        return parent?.lookup(name)
    }
    
    /// Looks up a symbol only in this scope
    public func lookupLocal(_ name: String) -> Symbol? {
        _symbols[name]
    }
    
    /// Checks if a symbol exists in this scope or parent scopes
    public func contains(_ name: String) -> Bool {
        lookup(name) != nil
    }
    
    /// Returns all symbols in this scope
    public var symbols: [String: Symbol] {
        _symbols
    }
    
    /// Returns all symbols including parent scopes
    public var allSymbols: [String: Symbol] {
        var result = parent?.allSymbols ?? [:]
        for (name, symbol) in _symbols {
            result[name] = symbol
        }
        return result
    }
    
    /// Returns all published symbols
    public var publishedSymbols: [String: Symbol] {
        _symbols.filter { $0.value.visibility == .published }
    }
    
    // MARK: - Mutation (returns new table)
    
    /// Defines a new symbol, returning a new symbol table
    public func define(_ symbol: Symbol) -> SymbolTable {
        var newSymbols = _symbols
        newSymbols[symbol.name] = symbol
        return SymbolTable(scopeId: scopeId, scopeName: scopeName, parent: parent, symbols: newSymbols)
    }
    
    /// Creates a child scope
    public func createChild(scopeId: String, scopeName: String) -> SymbolTable {
        SymbolTable(scopeId: scopeId, scopeName: scopeName, parent: self)
    }
    
    // MARK: - Description
    
    public var description: String {
        var result = "SymbolTable(\(scopeName))\n"
        for (name, symbol) in _symbols.sorted(by: { $0.key < $1.key }) {
            result += "  \(name): \(symbol.visibility) [\(symbol.source)]\n"
        }
        return result
    }
}

// MARK: - Symbol Table Builder

/// Mutable builder for creating symbol tables
public final class SymbolTableBuilder {
    
    private var symbols: [String: Symbol] = [:]
    private let scopeId: String
    private let scopeName: String
    private let parent: SymbolTable?
    
    public init(scopeId: String, scopeName: String, parent: SymbolTable? = nil) {
        self.scopeId = scopeId
        self.scopeName = scopeName
        self.parent = parent
    }
    
    /// Defines a new symbol
    @discardableResult
    public func define(_ symbol: Symbol) -> Self {
        symbols[symbol.name] = symbol
        return self
    }
    
    /// Defines a symbol with inline parameters
    @discardableResult
    public func define(
        name: String,
        definedAt: SourceSpan,
        visibility: Visibility = .internal,
        source: SymbolSource,
        dataType: DataType? = nil
    ) -> Self {
        let symbol = Symbol(
            name: name,
            definedAt: definedAt,
            visibility: visibility,
            source: source,
            dataType: dataType
        )
        return define(symbol)
    }
    
    /// Updates a symbol's visibility
    @discardableResult
    public func updateVisibility(name: String, to visibility: Visibility) -> Self {
        if var symbol = symbols[name] {
            symbols[name] = Symbol(
                name: symbol.name,
                definedAt: symbol.definedAt,
                visibility: visibility,
                source: symbol.source,
                dataType: symbol.dataType
            )
        }
        return self
    }
    
    /// Builds the immutable symbol table
    public func build() -> SymbolTable {
        SymbolTable(scopeId: scopeId, scopeName: scopeName, parent: parent, symbols: symbols)
    }
}

// MARK: - Global Symbol Registry

/// Registry for published symbols across feature sets
public final class GlobalSymbolRegistry: @unchecked Sendable {
    
    private var publishedSymbols: [String: (featureSet: String, symbol: Symbol)] = [:]
    private let lock = NSLock()
    
    public init() {}
    
    /// Registers a published symbol
    public func register(symbol: Symbol, fromFeatureSet: String) {
        lock.lock()
        defer { lock.unlock() }
        publishedSymbols[symbol.name] = (featureSet: fromFeatureSet, symbol: symbol)
    }
    
    /// Looks up a published symbol
    public func lookup(_ name: String) -> (featureSet: String, symbol: Symbol)? {
        lock.lock()
        defer { lock.unlock() }
        return publishedSymbols[name]
    }
    
    /// Returns all published symbols
    public var allPublished: [String: (featureSet: String, symbol: Symbol)] {
        lock.lock()
        defer { lock.unlock() }
        return publishedSymbols
    }
}
