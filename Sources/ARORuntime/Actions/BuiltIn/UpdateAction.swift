// ============================================================
// UpdateAction.swift
// ARO Runtime - Update, and the entity update Configure shares with it
// ============================================================
//
// `Update` does two things: it merges a value into a binding
// (`Update the <order: status> with "paid".`) and it merges a row into a
// repository (`Update the <row> into the <orders-repository>.`, GitLab #505).
// It used to do two more — http-server and repository *configuration* — under
// a fifth verb, `configure`. Those live in ConfigureAction.swift now; `Update`
// still reaches them, because `Update the <cache-repository: ttl> with 60.`
// has always meant the same thing as writing `Configure`, and a refactor is
// not the place to take that away.

import Foundation
import AROParser

// MARK: - Entity update

/// Merging a value into a binding: the part `Update` and `Configure` share.
///
/// `Update the <order: status> with "paid".` replaces one field.
/// `Update the <order> with <changes>.` merges a dictionary.
/// A name that is not bound yet starts as an empty dictionary, which is what
/// makes `Configure the <validation: timeout> with 30.` work.
enum EntityUpdate {
    static func apply(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
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
                    updatedEntity[key] = SendableConverter.fromJSON(value)
                }
            } else {
                // Create dictionary from entity using reflection
                updatedEntity = [:]
                let mirror = Mirror(reflecting: entity)
                for child in mirror.children {
                    if let label = child.label {
                        updatedEntity[label] = SendableConverter.fromJSON(child.value)
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
}

// MARK: - Update

/// Updates an existing entity
public struct UpdateAction: SynchronousAction {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["update", "modify", "change", "set"]
    public static let validPrepositions: Set<Preposition> = [.with, .to, .for, .from, .into]

    public init() {}

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        try validatePreposition(object.preposition)

        // `Update the <row> into the <x-repository> …` — repository update
        // (GitLab #505). Storage is an actor, so the work happens on the
        // async path.
        if object.preposition == .into {
            guard InMemoryRepositoryStorage.isRepositoryName(object.base) else {
                // `into` only makes sense for a repository target; anything
                // else keeps the pre-#505 refusal instead of silently taking
                // the entity-update path.
                throw ActionError.undefinedRepository(object.base)
            }
            throw NeedsAsyncExecution()
        }

        // Repository configuration path needs async — fall back to Task path
        if ConfigurableSettings.isRepositorySetting(result: result) {
            throw NeedsAsyncExecution()
        }

        if let applied = try ConfigurableSettings.applyHTTPServerSetting(
            result: result, object: object, context: context) {
            return applied
        }

        return try EntityUpdate.apply(result: result, object: object, context: context)
    }

    /// Override to handle the repository paths that need `await`.
    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Which path this is, is decided from the statement rather than by
        // running the synchronous body and starting over when it throws
        // `NeedsAsyncExecution` — the sync body is still the one a compiled
        // binary calls directly.
        if object.preposition == .into, InMemoryRepositoryStorage.isRepositoryName(object.base) {
            try validatePreposition(object.preposition)
            return try await updateIntoRepository(result: result, object: object, context: context)
        }

        if ConfigurableSettings.isRepositorySetting(result: result) {
            try validatePreposition(object.preposition)
            return try await ConfigurableSettings.applyRepositorySetting(
                result: result, object: object, context: context)
        }

        return try executeSynchronously(result: result, object: object, context: context)
    }

    /// `Update the <row> into the <x-repository> [where <field> is <value>].`
    ///
    /// Merges the row into the matching repository entries (GitLab #505).
    /// Chapter 46's accumulator pattern is built on this shape. Storage is
    /// resolved exactly like Store / Retrieve / Delete resolve it — the
    /// registered `RepositoryStorageService` first, the container's storage
    /// as fallback — so the statement behaves identically under `aro run`
    /// and in interactive sessions.
    ///
    /// Matching: the `where` clause when one is written; the row's own
    /// identity field (`id`, then `name`, then `key`) otherwise — the same
    /// identity fields the storage upserts by. Update never inserts: no
    /// matching entry is an error (Store is the insert).
    private func updateIntoRepository(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let repoName = object.base

        // Same immutable pattern Store supports:
        //   Update the <updated: row> into the <repo>.  → binds <updated>
        //   Update the <row> into the <repo>.           → rebinds <row>
        //     (update verbs bind with allowRebind by contract)
        let dataVarName = result.specifiers.first ?? result.base

        guard let data = context.resolveAny(dataVarName) else {
            throw ActionError.undefinedVariable(dataVarName)
        }
        guard let updateDict = data as? [String: any Sendable] else {
            throw ActionError.typeMismatch(
                expected: "an object value to merge into the matching entry",
                actual: String(describing: type(of: data)),
                variable: dataVarName
            )
        }

        let storage = context.service(RepositoryStorageService.self)
            ?? context.container.repositoryStorage

        // Which entries to update: the where clause (bound by
        // FeatureSetExecutor) when given, the row's identity otherwise.
        let whereField: String? = context.resolve("_where_field_")
        let whereValue = context.resolveAny("_where_value_")

        let field: String
        let matchValue: any Sendable
        if let whereField, let whereValue {
            field = whereField
            matchValue = whereValue
        } else if let id = updateDict["id"] {
            field = "id"
            matchValue = id
        } else if let name = updateDict["name"] {
            field = "name"
            matchValue = name
        } else if let key = updateDict["key"] {
            field = "key"
            matchValue = key
        } else {
            throw ActionError.missingRequiredField(
                field: "a 'where' clause or an id/name/key field on the value",
                action: "Update into \(repoName)"
            )
        }

        let partition = try context.repositoryPartition(of: repoName)
        let existing = await storage.retrieve(
            from: repoName,
            businessActivity: context.businessActivity,
            caller: partition,
            where: field,
            equals: matchValue
        )
        let existingRows = existing.compactMap { $0 as? [String: any Sendable] }
        guard !existingRows.isEmpty else {
            throw ActionError.runtimeError(
                "No entry in \(repoName) where \(field) = \(matchValue) — Store inserts, Update updates"
            )
        }

        var updatedRows: [[String: any Sendable]] = []
        for row in existingRows {
            var merged = row
            for (k, v) in updateDict {
                merged[k] = v
            }
            // Rows in storage always carry an id, so this store replaces the
            // matched row in place (upsert by id) instead of inserting.
            let storeResult = await storage.storeWithChangeInfo(
                value: merged,
                in: repoName,
                businessActivity: context.businessActivity,
                caller: partition
            )
            updatedRows.append(merged)

            // Emit only for actual changes — an identical merge is a no-op
            // (isUpdate with nil oldValue), mirroring Store's event policy.
            if storeResult.isUpdate, let oldValue = storeResult.oldValue {
                context.emit(RepositoryChangedEvent(
                    repositoryName: repoName,
                    changeType: .updated,
                    entityId: storeResult.entityId,
                    newValue: storeResult.storedValue,
                    oldValue: oldValue
                ))
            }
        }

        let boundValue: any Sendable = updatedRows.count == 1
            ? updatedRows[0]
            : updatedRows
        context.bind(result.base, value: boundValue, allowRebind: true)
        return boundValue
    }
}
