// ============================================================
// GlobalSymbolStorage.swift
// ARO Runtime - Storage for published symbols
// ============================================================

import Foundation

// MARK: - Global Symbol Storage

/// A single published symbol entry.
public struct PublishedSymbol: Sendable {
    public let value: any Sendable
    public let featureSet: String
    public let businessActivity: String
    /// Unique ID of the feature-set invocation that published this symbol.
    /// Used by `evict(executionId:)` to remove symbols when their execution ends.
    public let executionId: String
}

/// Thread-safe storage for published symbols with business activity enforcement.
/// Converted to actor for Swift 6.2 concurrency safety (Issue #2).
///
/// Symbols are scoped to their publishing execution. When `evict(executionId:)`
/// is called after a feature set completes, its symbols are removed unless a
/// newer invocation has overwritten them (ownership guard prevents stale eviction).
/// Application-lifecycle feature sets (Application-Start / Application-End) are
/// intentionally excluded from eviction so their symbols persist for the entire
/// process lifetime.
public actor GlobalSymbolStorage {
    private var symbols: [String: PublishedSymbol] = [:]

    /// Reverse index: executionId → symbol names it owns.
    /// Enables O(1) bulk eviction without scanning the entire symbol table.
    private var executionIndex: [String: Set<String>] = [:]

    public init() {}

    // MARK: - Write

    /// Store a published symbol with its business activity and execution owner.
    public func publish(
        name: String,
        value: any Sendable,
        fromFeatureSet: String,
        businessActivity: String,
        executionId: String
    ) {
        // If a previous entry exists under the same name, remove it from the
        // old execution's index to keep the index clean.
        if let existing = symbols[name], existing.executionId != executionId {
            executionIndex[existing.executionId]?.remove(name)
        }
        symbols[name] = PublishedSymbol(
            value: value,
            featureSet: fromFeatureSet,
            businessActivity: businessActivity,
            executionId: executionId
        )
        executionIndex[executionId, default: []].insert(name)
    }

    /// Remove all symbols published by a specific execution.
    ///
    /// The ownership guard ensures that a late-arriving eviction cannot remove
    /// a symbol that was overwritten by a newer invocation: the stored
    /// `executionId` is checked before deleting.
    public func evict(executionId: String) {
        guard let names = executionIndex.removeValue(forKey: executionId) else { return }
        for name in names {
            if symbols[name]?.executionId == executionId {
                symbols.removeValue(forKey: name)
            }
        }
    }

    // MARK: - Read

    /// Resolve a published symbol (validates business activity)
    /// - Parameters:
    ///   - name: The symbol name
    ///   - forBusinessActivity: The business activity of the requesting feature set
    /// - Returns: The value if found and accessible, nil otherwise
    public func resolve<T: Sendable>(_ name: String, forBusinessActivity: String) -> T? {
        guard let entry = symbols[name] else { return nil }

        // Business activity validation: must match or be empty (framework/external)
        if !entry.businessActivity.isEmpty && !forBusinessActivity.isEmpty &&
           entry.businessActivity != forBusinessActivity {
            return nil  // Access denied - different business activity
        }

        return entry.value as? T
    }

    /// Resolve a published symbol as any Sendable (validates business activity)
    public func resolveAny(_ name: String, forBusinessActivity: String) -> (any Sendable)? {
        guard let entry = symbols[name] else { return nil }

        // Business activity validation: must match or be empty (framework/external)
        if !entry.businessActivity.isEmpty && !forBusinessActivity.isEmpty &&
           entry.businessActivity != forBusinessActivity {
            return nil  // Access denied - different business activity
        }

        return entry.value
    }

    /// Check if a symbol is published and accessible
    public func isPublished(_ name: String, forBusinessActivity: String) -> Bool {
        guard let entry = symbols[name] else { return false }

        // Business activity validation
        if !entry.businessActivity.isEmpty && !forBusinessActivity.isEmpty &&
           entry.businessActivity != forBusinessActivity {
            return false
        }

        return true
    }

    /// Get the feature set that published a symbol
    public func sourceFeatureSet(for name: String) -> String? {
        return symbols[name]?.featureSet
    }

    /// Get the business activity that a symbol belongs to
    public func businessActivity(for name: String) -> String? {
        return symbols[name]?.businessActivity
    }

    /// Check if accessing a symbol would be denied due to business activity mismatch
    public func isAccessDenied(_ name: String, forBusinessActivity: String) -> Bool {
        guard let entry = symbols[name] else { return false }

        // Access is denied if both have non-empty business activities that don't match
        return !entry.businessActivity.isEmpty &&
               !forBusinessActivity.isEmpty &&
               entry.businessActivity != forBusinessActivity
    }

    /// One-pass dependency resolution: walks the dependency list,
    /// applying access-control checks and value lookups in a
    /// single actor turn. Eliminates the per-dependency triple of
    /// actor hops (\`isAccessDenied\`, \`businessActivity\`,
    /// \`resolveAny\`) that \`FeatureSetExecutor\` was making before
    /// (#332).
    public func resolveDependencies<S: Collection>(
        _ names: S,
        forBusinessActivity activity: String
    ) -> [DependencyResolution] where S.Element == String {
        var out: [DependencyResolution] = []
        out.reserveCapacity(names.count)
        for name in names {
            guard let entry = symbols[name] else {
                out.append(.notFound(name: name))
                continue
            }
            let crossActivity = !entry.businessActivity.isEmpty
                && !activity.isEmpty
                && entry.businessActivity != activity
            if crossActivity {
                out.append(.denied(
                    name: name,
                    sourceActivity: entry.businessActivity
                ))
            } else {
                out.append(.resolved(name: name, value: entry.value))
            }
        }
        return out
    }

    /// Get all published symbols (for eager binding in feature sets)
    public func allSymbols() -> [String: PublishedSymbol] {
        return symbols
    }

    /// Total number of currently stored symbols. Useful for memory monitoring.
    public var count: Int { symbols.count }
}

/// Outcome of a single dependency lookup via
/// \`GlobalSymbolStorage.resolveDependencies\`.
public enum DependencyResolution: Sendable {
    case resolved(name: String, value: any Sendable)
    case denied(name: String, sourceActivity: String)
    case notFound(name: String)

    public var name: String {
        switch self {
        case .resolved(let n, _), .denied(let n, _), .notFound(let n): return n
        }
    }
}
