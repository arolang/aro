// ============================================================
// StoreAction.swift
// ARO Runtime - Store: writing a value into a repository
// ============================================================

import Foundation
import AROParser

/// Stores data to a repository
///
/// When the target name ends with `-repository`, the data is stored in
/// the RepositoryStorage service, which persists across HTTP requests
/// within the same business activity.
///
/// ## Examples
/// ```
/// // Basic: Store data (no ID capture)
/// <Store> the <message> into the <message-repository>.
///
/// // Immutable pattern: Capture stored value with generated ID
/// <Store> the <stored-user: user> into the <user-repository>.
/// // Now <stored-user> contains the user data WITH the generated ID
///
/// // Inline payload (GitLab #515): the `with` clause IS the record
/// <Store> the <ticket> into the <ticket-repository> with { id: 1, state: "new" }.
/// // Now <ticket> contains the stored record, exactly as Create-then-Store left it
/// ```
public struct StoreAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["store", "save", "persist"]
    // `.in` used to be listed here too, which is why ARO-0004 documented Store as
    // accepting `in`. It is an alias for `.into` (ServerActions.swift), not a case,
    // and the lexer has no `in` token — so `Store the <x> in the <repo>.` never
    // parsed. Dropping it is a no-op for the set and stops the declaration from
    // implying otherwise (GitLab #480).
    public static let validPrepositions: Set<Preposition> = [.into, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Support immutable pattern: <Store> the <stored-user: user> into <repository>
        // - result.base = new variable to bind (e.g., "stored-user")
        // - result.specifiers[0] = data to store (e.g., "user")
        let dataVarName: String
        var bindResultVar: Bool

        if !result.specifiers.isEmpty {
            // Immutable pattern: <Store> the <stored-user: user> into <repository>
            dataVarName = result.specifiers[0]
            bindResultVar = true
        } else {
            // Legacy pattern: <Store> the <user> into <repository>
            dataVarName = result.base
            bindResultVar = false
        }

        // Get repository name
        let repoName = object.base

        // GitLab #515: inline payload —
        //   Store the <ticket> into the <ticket-repository> with { id: 1, state: "new" }.
        //
        // Emit has accepted an object literal for its payload since it existed;
        // Store made you bind the record with Create first, for no reason other
        // than that nobody read the clause. The parser has always produced the
        // `with` expression (RangeModifiers.withClause) and FeatureSetExecutor
        // has always bound it to `_with_` — the value simply never reached here,
        // so the statement died on "Cannot store the ticket into the
        // ticket-repository", naming a variable the author never meant to bind.
        //
        // The payload IS the value to store, and the result slot binds the
        // stored record — the same thing the `<stored: user>` spelling binds,
        // so `<ticket>` is usable afterwards exactly as Create-then-Store leaves
        // it, generated id and all.
        let inlinePayload = context.resolveAny("_with_")

        if inlinePayload != nil {
            // Both conflicts below are thrown as AROError rather than a plain
            // ActionError: the statement-shaped wrapper in FeatureSetExecutor
            // keeps only the shape ("Cannot store the ticket into the
            // ticket-repository"), and here the shape is exactly what reads
            // fine — what went wrong is which of two things names the value.
            // Bare verb: the bracketed spelling was removed (GitLab #514), so
            // echoing it here would print a statement the reader cannot type
            // back (GitLab #574).
            let statementText =
                "Store the <\(result.fullName)> \(object.preposition.rawValue) the <\(repoName)> with { … }."

            if !result.specifiers.isEmpty {
                // `Store the <stored: ticket> into the <repo> with { … }` names
                // the value to store twice, and the two names disagree. Refuse
                // rather than silently picking one.
                throw AROError(
                    message: "The 'with' payload and the <\(result.base): \(result.specifiers[0])> "
                        + "specifier both name the value to store — write one or the other.",
                    featureSet: context.featureSetName,
                    businessActivity: context.businessActivity,
                    statement: statementText
                )
            }

            // A `<ticket>` that already holds a value cannot also hold the
            // stored record. Refused here rather than at the bind below,
            // because the bind happens after the write: letting the refusal
            // report it would leave the row in the repository from a statement
            // that failed. One value, one name — the payload never overwrites
            // a record someone else built.
            if let runtimeContext = context as? RuntimeContext,
               runtimeContext.wouldRefuseRebind(result.base) {
                throw AROError(
                    message: "<\(result.base)> is already bound, and the payload would rebind it with "
                        + "the stored record. Store the bound value (drop the 'with'), or give the "
                        + "payload a name of its own.",
                    featureSet: context.featureSetName,
                    businessActivity: context.businessActivity,
                    statement: statementText
                )
            }

            // The result names the stored record, so bind it.
            bindResultVar = true
        }

        // ARO-0051: Streaming support - only stream lazy values.
        // An inline payload is a value, never a stream, so it skips this.
        if inlinePayload == nil,
           let runtimeContext = context as? RuntimeContext,
           runtimeContext.isLazy(dataVarName),
           let stream = runtimeContext.resolveAsRowStream(dataVarName),
           InMemoryRepositoryStorage.isRepositoryName(repoName) {
            // Drain stream by storing each element as it arrives
            let storage = context.service(RepositoryStorageService.self) ?? context.container.repositoryStorage
            var count = 0
            var lastStoreResult: RepositoryStoreResult?

            for try await item in stream.stream {
                lastStoreResult = await storage.storeWithChangeInfo(
                    value: item,
                    in: repoName,
                    businessActivity: context.businessActivity
                )
                count += 1
            }

            // Return the last stored item or count
            if bindResultVar, let lastResult = lastStoreResult {
                context.bind(result.base, value: lastResult.storedValue)
                return lastResult.storedValue
            }
            return count
        }

        // Get data to store — the inline payload when one was written, the
        // named variable otherwise.
        let data: any Sendable
        if let inlinePayload {
            data = inlinePayload
        } else if let resolved = context.resolveAny(dataVarName) {
            data = resolved
        } else {
            throw ActionError.undefinedVariable(dataVarName)
        }

        // Check if this is a repository (ends with -repository)
        if InMemoryRepositoryStorage.isRepositoryName(repoName) {
            // If data is an array, store each element individually (flatten)
            // This allows: <Store> the <url-list> into the <crawled-repository>.
            // to add each URL as a separate item, not the array as one item
            let itemsToStore: [any Sendable]
            if let arrayData = data as? [any Sendable] {
                itemsToStore = arrayData
            } else {
                itemsToStore = [data]
            }

            // Store each item individually and emit events only for actual changes
            let storage = context.service(RepositoryStorageService.self) ?? context.container.repositoryStorage

            var lastStoreResult: RepositoryStoreResult?
            for item in itemsToStore {
                let storeResult = await storage.storeWithChangeInfo(
                    value: item,
                    in: repoName,
                    businessActivity: context.businessActivity
                )
                lastStoreResult = storeResult

                // Only emit events for actual changes (not duplicates)
                // - !isUpdate means new entry → emit .created
                // - isUpdate with oldValue means value changed → emit .updated
                // - isUpdate without oldValue means duplicate (no change) → no event
                let changeType: RepositoryChangeType?
                let oldValue: (any Sendable)?

                if !storeResult.isUpdate {
                    // New entry
                    changeType = .created
                    oldValue = nil
                } else if storeResult.oldValue != nil {
                    // Update with changed data
                    changeType = .updated
                    oldValue = storeResult.oldValue
                } else {
                    // Duplicate (same value already exists) - no event
                    changeType = nil
                    oldValue = nil
                }

                // Emit event if there was an actual change
                if let changeType = changeType {
                    let changeEvent = RepositoryChangedEvent(
                        repositoryName: repoName,
                        changeType: changeType,
                        entityId: storeResult.entityId,
                        newValue: storeResult.storedValue,
                        oldValue: oldValue
                    )
                    if let eventBus = context.eventBus {
                        if RuntimeDefaults.asyncObserverDispatch {
                            // #227: fire-and-forget through the bounded observer
                            // worker pool. Store returns without awaiting the
                            // observer subtree, so this handler's locals (e.g. a
                            // crawler's HTML body / parsed DOM) are freed
                            // immediately instead of staying resident until every
                            // descendant store drains. The pool caps concurrent
                            // observer bodies so memory stays bounded. Opt-in via
                            // ARO_ASYNC_OBSERVERS; default keeps the awaited path.
                            eventBus.publishBackpressured(changeEvent)
                        } else {
                            await eventBus.publishAndTrack(changeEvent)
                        }
                    } else {
                        context.emit(changeEvent)
                    }
                }
            }

            // Bind new-entry for atomic store-and-check patterns (e.g., parallel for each + repository dedup)
            // Value is 1 if newly created, 0 if duplicate/update - enables `when <new-entry> > 0` guards
            if let storeResult = lastStoreResult {
                context.bind("new-entry", value: storeResult.isUpdate ? 0 : 1, allowRebind: true)

                // Immutable pattern: bind the stored value (with generated ID) to result variable
                if bindResultVar {
                    context.bind(result.base, value: storeResult.storedValue)
                }
            }
        }

        // Emit store event (legacy)
        context.emit(DataStoredEvent(repository: repoName, dataType: String(describing: type(of: data))))

        return StoreResult(repository: repoName, success: true)
    }
}

/// Result of a store operation
public struct StoreResult: Sendable, Equatable {
    public let repository: String
    public let success: Bool
}

/// Event emitted when data is stored
public struct DataStoredEvent: RuntimeEvent {
    public static var eventType: String { "data.stored" }
    public let timestamp: Date
    public let repository: String
    public let dataType: String

    public init(repository: String, dataType: String) {
        self.timestamp = Date()
        self.repository = repository
        self.dataType = dataType
    }
}
