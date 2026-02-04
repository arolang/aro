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

// MARK: - Data Type (ARO-0006)

/// Type system for ARO symbols
///
/// Primitives: String, Integer, Float, Boolean (built-in)
/// Collections: List<T>, Map<K,V> (built-in)
/// Complex: Schema references from openapi.yaml components
public indirect enum DataType: Sendable, Equatable, CustomStringConvertible {
    // Primitives (ARO-0006 Section 1)
    case string
    case integer
    case float
    case boolean

    // Collections (ARO-0006 Section 2)
    case list(DataType)
    case map(key: DataType, value: DataType)

    // OpenAPI schema reference (ARO-0006 Section 3)
    case schema(String)

    // Unknown/untyped
    case unknown

    public var description: String {
        switch self {
        case .string: return "String"
        case .integer: return "Integer"
        case .float: return "Float"
        case .boolean: return "Boolean"
        case .list(let element): return "List<\(element)>"
        case .map(let key, let value): return "Map<\(key), \(value)>"
        case .schema(let name): return name
        case .unknown: return "Unknown"
        }
    }

    /// Check if this is a primitive type
    public var isPrimitive: Bool {
        switch self {
        case .string, .integer, .float, .boolean: return true
        default: return false
        }
    }

    /// Check if this is a collection type
    public var isCollection: Bool {
        switch self {
        case .list, .map: return true
        default: return false
        }
    }

    /// Parse a type from a string (e.g., "String", "List<User>", "Map<String, Integer>")
    public static func parse(_ typeString: String) -> DataType {
        let trimmed = typeString.trimmingCharacters(in: .whitespaces)

        // Primitives
        switch trimmed {
        case "String": return .string
        case "Integer": return .integer
        case "Float": return .float
        case "Boolean": return .boolean
        default: break
        }

        // List<T>
        if trimmed.hasPrefix("List<") && trimmed.hasSuffix(">") {
            let inner = String(trimmed.dropFirst(5).dropLast(1))
            return .list(parse(inner))
        }

        // Map<K, V>
        if trimmed.hasPrefix("Map<") && trimmed.hasSuffix(">") {
            let inner = String(trimmed.dropFirst(4).dropLast(1))
            // Split on comma, handling nested generics
            if let commaIndex = findTopLevelComma(in: inner) {
                let keyStr = String(inner[inner.startIndex..<commaIndex]).trimmingCharacters(in: .whitespaces)
                let valueStr = String(inner[inner.index(after: commaIndex)...]).trimmingCharacters(in: .whitespaces)
                return .map(key: parse(keyStr), value: parse(valueStr))
            }
        }

        // OpenAPI schema reference
        return .schema(trimmed)
    }

    /// Find the top-level comma in a generic type string
    private static func findTopLevelComma(in str: String) -> String.Index? {
        var depth = 0
        for (index, char) in zip(str.indices, str) {
            switch char {
            case "<": depth += 1
            case ">": depth -= 1
            case "," where depth == 0: return index
            default: break
            }
        }
        return nil
    }

    /// Infer type from a literal value
    public static func infer(from literal: Any) -> DataType {
        switch literal {
        case is String: return .string
        case is Int: return .integer
        case is Double: return .float
        case is Bool: return .boolean
        default: return .unknown
        }
    }

    /// Check type compatibility (ARO-0006 Section 7.1)
    public func isAssignableTo(_ target: DataType) -> Bool {
        if self == target { return true }

        // Integer -> Float widening allowed
        if self == .integer && target == .float { return true }

        // Collection element compatibility
        if case .list(let selfElement) = self,
           case .list(let targetElement) = target {
            return selfElement.isAssignableTo(targetElement)
        }

        if case .map(let selfKey, let selfValue) = self,
           case .map(let targetKey, let targetValue) = target {
            return selfKey.isAssignableTo(targetKey) && selfValue.isAssignableTo(targetValue)
        }

        // Unknown is assignable to anything (for gradual typing)
        if self == .unknown { return true }

        return false
    }

    /// Legacy: Infer type from specifiers (backwards compatibility)
    /// This is used when type annotation is provided as space-separated specifiers
    public static func infer(from specifiers: [String]) -> DataType? {
        guard let typeStr = specifiers.first else { return nil }
        let parsed = parse(typeStr)
        return parsed == .schema(typeStr) && typeStr.lowercased() == typeStr ? nil : parsed
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
        if let symbol = symbols[name] {
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
