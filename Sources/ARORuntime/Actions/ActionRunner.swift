// ============================================================
// ActionRunner.swift
// ARO Runtime - Unified Action Execution
// ============================================================
//
// This module provides a unified interface for executing ARO actions
// that can be called from both the interpreter and compiled binaries.
// It handles verb canonicalization and async-to-sync bridging.

import Foundation
import AROParser

/// Unified action runner that bridges async actions for synchronous callers
///
/// The ActionRunner provides:
/// - Verb canonicalization (map synonym verbs to canonical verbs)
/// - Async-to-sync bridging for compiled binaries
/// - Consistent execution path for both `aro run` and `aro build`
public final class ActionRunner: @unchecked Sendable {
    /// Shared singleton instance
    public static let shared = ActionRunner()

    /// The action registry to use
    private let registry: ActionRegistry

    /// Synchronous-action lookup table (verb → type), built at startup.
    /// Keyed by canonical verb.  Safe to access from any thread because it
    /// is populated once in `init` and never mutated afterward.
    private let syncActions: [String: any SynchronousAction.Type]

    /// Private initializer
    private init() {
        self.registry = ActionRegistry.shared
        self.syncActions = Self.buildSyncActionsTable()
    }

    /// Build a flat verb → SynchronousAction.Type table that mirrors ActionRegistry's
    /// final verb→type mapping but only retains entries where the winning type is a
    /// SynchronousAction.  This prevents a sync-capable type from shadowing a
    /// later-registered non-sync type that overrides the same verb.
    private static func buildSyncActionsTable() -> [String: any SynchronousAction.Type] {
        let allModuleActions: [[any ActionImplementation.Type]] = [
            RequestActionsModule.actions,
            OwnActionsModule.actions,
            ResponseActionsModule.actions,
            ServerActionsModule.actions,
            SocketActionsModule.actions,
            FileActionsModule.actions,
            DataPipelineActionsModule.actions,
            TestActionsModule.actions,
            TerminalActionsModule.actions,
            SystemActionsModule.actions,
        ]

        // Step 1: build the full verb→type dict in the same order as ActionRegistry
        var fullDict: [String: any ActionImplementation.Type] = [:]
        for moduleActions in allModuleActions {
            for actionType in moduleActions {
                for verb in actionType.verbs {
                    fullDict[verb.lowercased()] = actionType
                }
            }
        }

        // Step 2: retain only verbs whose winning type is a SynchronousAction
        var table: [String: any SynchronousAction.Type] = [:]
        for (verb, actionType) in fullDict {
            if let syncType = actionType as? any SynchronousAction.Type {
                let canonical = canonicalizeVerb(verb)
                table[canonical] = syncType
            }
        }
        return table
    }

    /// Execute an action on the calling thread if it is a `SynchronousAction`.
    /// Returns `nil` if the verb is unknown or the action signals `NeedsAsyncExecution`.
    private func executeSynchronouslyIfSupported(
        canonicalVerb: String,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) -> ActionRunnerResult? {
        guard let syncType = syncActions[canonicalVerb] else { return nil }
        let action = syncType.init()
        do {
            let value = try action.executeSynchronously(result: result, object: object, context: context)
            return .success(value)
        } catch is NeedsAsyncExecution {
            // Action has async paths that need Task dispatch — fall through
            return nil
        } catch {
            return .failure(String(describing: error))
        }
    }

    // MARK: - Verb Canonicalization

    /// Canonical verb mappings - maps synonym verbs to their primary verb
    private static let verbMappings: [String: String] = [
        // compute synonyms
        "calculate": "compute",
        "derive": "compute",

        // validate synonyms
        "verify": "validate",
        "check": "validate",

        // compare synonyms
        "match": "compare",

        // transform synonyms
        "convert": "transform",

        // create synonyms
        // NOTE: "make" is NOT a synonym for "create" - MakeAction handles directory creation
        "build": "create",
        "construct": "create",

        // update synonyms
        "modify": "update",
        "change": "update",
        "set": "update",
        "configure": "update",

        // return synonyms
        "respond": "return",

        // throw synonyms
        "raise": "throw",
        "fail": "throw",

        // send synonyms
        "dispatch": "send",

        // log synonyms
        "print": "log",
        "output": "log",
        "debug": "log",

        // store synonyms
        "save": "store",
        "persist": "store",

        // publish synonyms
        "export": "publish",
        "expose": "publish",
        "share": "publish",

        // start synonyms
        "initialize": "start",
        "boot": "start",

        // listen synonyms
        "await": "listen",
        "wait": "listen",

        // route synonyms
        "forward": "route",

        // watch synonyms
        "monitor": "watch",
        "observe": "watch",

        // sleep synonyms (ARO-0054)
        "delay": "sleep",
        "pause": "sleep"
    ]

    /// Canonicalize a verb to its primary form
    /// - Parameter verb: The verb to canonicalize
    /// - Returns: The canonical verb
    public static func canonicalizeVerb(_ verb: String) -> String {
        let lowercased = verb.lowercased()
        return verbMappings[lowercased] ?? lowercased
    }

    // MARK: - Async Execution

    /// Execute an action asynchronously
    /// - Parameters:
    ///   - verb: The action verb (will be canonicalized)
    ///   - result: The result descriptor
    ///   - object: The object descriptor
    ///   - context: The execution context
    /// - Returns: The action result
    /// - Throws: ActionError if action not found or execution fails
    public func executeAsync(
        verb: String,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let canonicalVerb = Self.canonicalizeVerb(verb)
        return try await registry.execute(
            verb: canonicalVerb,
            result: result,
            object: object,
            context: context
        )
    }

    // MARK: - Sync Execution (for C bridge)

    /// Thread-safe result holder for async-to-sync bridging
    private final class ResultHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: (any Sendable)?
        private var _error: Error?

        var value: (any Sendable)? {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return _error
        }

        func setValue(_ value: any Sendable) {
            lock.lock()
            defer { lock.unlock() }
            _value = value
        }

        func setError(_ error: Error) {
            lock.lock()
            defer { lock.unlock() }
            _error = error
        }
    }

    /// Execute an action synchronously by blocking on the async result
    /// - Parameters:
    ///   - verb: The action verb (will be canonicalized)
    ///   - result: The result descriptor
    ///   - object: The object descriptor
    ///   - context: The execution context (must be a RuntimeContext)
    /// - Returns: The action result, or nil if execution fails
    ///
    /// This method is designed for C interop where async execution is not possible.
    /// It uses a semaphore to block until the async operation completes.
    public func executeSync(
        verb: String,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) -> (any Sendable)? {
        // Fast path: bypass Task.detached + semaphore for synchronous actions
        let canonicalVerb = Self.canonicalizeVerb(verb)
        if let syncResult = executeSynchronouslyIfSupported(
            canonicalVerb: canonicalVerb, result: result, object: object, context: context
        ) {
            return syncResult.value
        }

        let holder = ResultHolder()
        let semaphore = DispatchSemaphore(value: 0)

        // Use Task.detached to ensure the task runs on the concurrent executor
        // rather than inheriting the current task context. This prevents deadlocks
        // on Linux where the default Task might try to use the blocked thread.
        Task.detached { @Sendable [self] in
            do {
                let result = try await self.executeAsync(
                    verb: verb,
                    result: result,
                    object: object,
                    context: context
                )
                holder.setValue(result)
            } catch {
                holder.setError(error)
            }
            semaphore.signal()
        }

        // Yield pattern: release our execution pool slot while blocked so other
        // compiled code can run. Re-acquire after the action completes.
        // This prevents deadlock from cascading event chains.
        let pool = CompiledExecutionPool.shared
        let hadSlot = pool.threadHoldsSlot
        if hadSlot {
            pool.gate.signal()
            pool.threadHoldsSlot = false
        }

        semaphore.wait()

        if hadSlot {
            pool.gate.wait()
            pool.threadHoldsSlot = true
        }

        if let error = holder.error {
            _ = error
            return nil
        }

        return holder.value
    }

    // MARK: - Lazy Execution (Issue #55, Phase 2)

    /// Build an AROFuture wrapping `executeAsync(...)`. The future's task
    /// starts running on the cooperative pool immediately; the caller may
    /// hold the handle without blocking. Forcing the handle (or awaiting
    /// `future.value()`) materializes the result.
    ///
    /// Used by the C bridge under `ARO_LAZY_ACTIONS=1` for non-force-at-site
    /// verbs.  See `LazyActionPolicy` for the force-at-site set.
    public func executeLazy(
        verb: String,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext,
        sourceLocation: String? = nil
    ) -> AROFuture {
        // Capture only Sendable-friendly values into the future closure.
        let capturedVerb = verb
        let capturedResult = result
        let capturedObject = object
        let capturedContext = context
        return AROFuture(bindingName: result.base, sourceLocation: sourceLocation) { [self] in
            return try await self.executeAsync(
                verb: capturedVerb,
                result: capturedResult,
                object: capturedObject,
                context: capturedContext
            )
        }
    }

    // MARK: - Action Lookup

    /// Check if a verb has a registered action
    /// - Parameter verb: The verb to check (will be canonicalized)
    /// - Returns: true if an action is registered for this verb
    public func hasAction(for verb: String) async -> Bool {
        let canonicalVerb = Self.canonicalizeVerb(verb)
        return await registry.isRegistered(canonicalVerb)
    }

    /// Get the canonical verb for a given verb
    /// - Parameter verb: The input verb
    /// - Returns: The canonical form of the verb
    public func getCanonicalVerb(_ verb: String) -> String {
        return Self.canonicalizeVerb(verb)
    }
}

// MARK: - Compiled Execution Pool

/// Bounds concurrent compiled code execution to prevent GCD thread pool exhaustion.
///
/// Compiled handlers block GCD threads via semaphore.wait(). Without limits,
/// cascading event chains (emit -> handler -> emit -> ...) create unbounded
/// blocked threads. The pool gates execution to `4 * CPU count` slots, and
/// the yield pattern in executeSync/executeSyncWithResult releases slots
/// while blocked on async actions, allowing other work to proceed.
public final class CompiledExecutionPool: @unchecked Sendable {
    public static let shared = CompiledExecutionPool()

    /// Gate limiting concurrent compiled code executions
    public let gate: DispatchSemaphore

    /// Serial queue for handler submission — only 1 thread waits on the gate at a time,
    /// preventing GCD thread explosion when many events fire simultaneously
    public let submitQueue = DispatchQueue(label: "aro.compiled.submit")

    /// Thread-local key for slot ownership
    private static let holdsSlotKey = "aro.compiled.holdsSlot"

    private init() {
        gate = DispatchSemaphore(value: 4 * ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Whether the current thread holds a global execution slot
    public var threadHoldsSlot: Bool {
        get { Thread.current.threadDictionary[Self.holdsSlotKey] as? Bool ?? false }
        set { Thread.current.threadDictionary[Self.holdsSlotKey] = newValue }
    }
}

// MARK: - C Bridge Support

/// Result type for C bridge calls
public struct ActionRunnerResult: @unchecked Sendable {
    public let value: (any Sendable)?
    public let error: String?

    public var succeeded: Bool { error == nil }

    public static func success(_ value: any Sendable) -> ActionRunnerResult {
        ActionRunnerResult(value: value, error: nil)
    }

    public static func failure(_ error: String) -> ActionRunnerResult {
        ActionRunnerResult(value: nil, error: error)
    }
}

extension ActionRunner {
    /// Thread-safe result holder for ActionRunnerResult
    private final class ActionResultHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _result: ActionRunnerResult = .failure("Unknown error")

        var result: ActionRunnerResult {
            lock.lock()
            defer { lock.unlock() }
            return _result
        }

        func setResult(_ result: ActionRunnerResult) {
            lock.lock()
            defer { lock.unlock() }
            _result = result
        }
    }

    /// Execute an action and return a detailed result for C bridge
    /// - Parameters:
    ///   - verb: The action verb
    ///   - result: The result descriptor
    ///   - object: The object descriptor
    ///   - context: The execution context
    /// - Returns: ActionRunnerResult with value or error
    public func executeSyncWithResult(
        verb: String,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) -> ActionRunnerResult {
        // Fast path: bypass Task.detached + semaphore for synchronous actions
        let canonicalVerb = Self.canonicalizeVerb(verb)
        if let syncResult = executeSynchronouslyIfSupported(
            canonicalVerb: canonicalVerb, result: result, object: object, context: context
        ) {
            return syncResult
        }

        // Issue #55, Phase 4: under lazy mode, run action work on
        // ActionTaskExecutor (elastic GCD) instead of the cooperative pool.
        // The C-bridge pthread blocks via AROFuture.force() — same blocking
        // semantics as before, but action work can never starve the
        // cooperative pool, eliminating cascading-emit deadlocks.
        if LazyActionMode.isEnabled {
            let future = self.executeLazy(
                verb: verb, result: result, object: object, context: context
            )
            do {
                let value = try future.force()
                return .success(value)
            } catch {
                return .failure(String(describing: error))
            }
        }

        // Phase 2: if the context has an async driver channel, submit work there
        // instead of spawning a new Task.detached per call.
        if let channel = (context as? RuntimeContext)?.driverChannel {
            let box = ActionRunnerResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            channel.submitAction(
                verb: verb, result: result, object: object,
                context: context, holder: box, semaphore: semaphore
            )

            // Yield pool slot while waiting (same as legacy path)
            let pool = CompiledExecutionPool.shared
            let hadSlot = pool.threadHoldsSlot
            if hadSlot {
                pool.gate.signal()
                pool.threadHoldsSlot = false
            }
            semaphore.wait()
            if hadSlot {
                pool.gate.wait()
                pool.threadHoldsSlot = true
            }
            return box.result
        }

        let holder = ActionResultHolder()
        let semaphore = DispatchSemaphore(value: 0)

        // Use Task.detached to ensure the task runs on the concurrent executor
        // rather than inheriting the current task context. This prevents deadlocks
        // on Linux where the default Task might try to use the blocked thread.
        Task.detached { @Sendable [self] in
            do {
                let value = try await self.executeAsync(
                    verb: verb,
                    result: result,
                    object: object,
                    context: context
                )
                holder.setResult(.success(value))
            } catch {
                holder.setResult(.failure(String(describing: error)))
            }
            semaphore.signal()
        }

        // Yield pattern: release our execution pool slot while blocked so other
        // compiled code can run. Re-acquire after the action completes.
        // This prevents deadlock from cascading event chains.
        let pool = CompiledExecutionPool.shared
        let hadSlot = pool.threadHoldsSlot
        if hadSlot {
            pool.gate.signal()
            pool.threadHoldsSlot = false
        }

        semaphore.wait()

        if hadSlot {
            pool.gate.wait()
            pool.threadHoldsSlot = true
        }

        return holder.result
    }

    /// Execute an action without waiting for completion (fire-and-forget)
    /// Used for Emit in compiled binaries to enable parallel event handling
    public func executeFireAndForget(
        verb: String,
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) {
        // Register this task with EventBus so awaitPendingEvents knows to wait
        context.eventBus?.registerPendingHandler()

        // Spawn task that runs the action - don't wait for it to complete
        Task.detached { @Sendable [self] in
            defer {
                // Unregister when task completes
                context.eventBus?.unregisterPendingHandler()
            }
            _ = try? await self.executeAsync(
                verb: verb,
                result: result,
                object: object,
                context: context
            )
        }
    }

    /// Execute an emit action with pre-captured literal value (fire-and-forget)
    /// This avoids race conditions where _literal_ is overwritten before the Task runs
    public func executeFireAndForgetEmit(
        eventType: String,
        capturedLiteral: (any Sendable)?,
        capturedExpressionName: String?,
        objectBase: String,
        context: ExecutionContext
    ) {
        // Register this task with EventBus so awaitPendingEvents knows to wait
        context.eventBus?.registerPendingHandler()

        // Capture the event bus reference before spawning
        let eventBus = context.eventBus

        // Spawn task that emits the event directly - don't wait for handlers to complete
        Task.detached {
            defer {
                // Unregister when task completes
                eventBus?.unregisterPendingHandler()
            }

            // Build payload directly using captured values (no context lookup)
            var payload: [String: any Sendable] = [:]

            // Determine the payload key name
            let payloadKey: String
            if let exprName = capturedExpressionName {
                payloadKey = exprName
            } else if objectBase != "_expression_" {
                payloadKey = objectBase
            } else {
                payloadKey = "data"
            }

            // Use the captured literal value
            if let literal = capturedLiteral {
                payload[payloadKey] = literal
            }

            // Create and emit the domain event (binary mode fire-and-forget path).
            // DomainEvent eventType: user-defined (result.base, e.g. "UserCreated")
            // DomainEvent payload:   { payloadKey: value } — same schema as interpreter EmitAction
            let event = DomainEvent(eventType: eventType, payload: payload)

            // Publish and wait for handlers
            if let bus = eventBus {
                await bus.publishAndTrack(event)
            }
        }
    }
}

// MARK: - Per-Feature-Set Async Driver (Phase 2)

/// Work item submitted by the C bridge for cooperative action dispatch.
///
/// The C feature set pthread submits a work item and blocks on `semaphore`.
/// The driver Swift Task picks it up, calls `await executeAsync(...)`, stores
/// the result, and signals `semaphore` — without spawning a new Task.
public struct ActionDriverWorkItem: @unchecked Sendable {
    public let verb: String
    public let result: ResultDescriptor
    public let object: ObjectDescriptor
    public let context: ExecutionContext
    public let holder: ActionRunnerResultBox
    public let semaphore: DispatchSemaphore
}

/// Work item for cooperative directory iteration (Phase 3 pipelining).
///
/// `aro_array_get_next_ctx` submits one of these per loop iteration so that
/// `PipelinedDirectoryIterator.nextAsync()` is awaited on the cooperative pool
/// rather than on the C pthread — letting the producer and consumer overlap.
public struct ArrayNextWorkItem: @unchecked Sendable {
    public let iterator: PipelinedDirectoryIterator
    public let holder: ActionRunnerResultBox
    public let semaphore: DispatchSemaphore
}

/// Unified work-item type for `ActionDriverChannel`.
public enum DriverWorkItem: @unchecked Sendable {
    case action(ActionDriverWorkItem)
    case arrayNext(ArrayNextWorkItem)
}

/// Thread-safe box for `ActionRunnerResult` shared between the C bridge
/// (writer, from the driver task) and the calling pthread (reader).
public final class ActionRunnerResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: ActionRunnerResult = .failure("pending")

    public init() {}

    public var result: ActionRunnerResult {
        lock.lock(); defer { lock.unlock() }
        return _result
    }
    public func set(_ r: ActionRunnerResult) {
        lock.lock(); defer { lock.unlock() }
        _result = r
    }
}

/// Single-producer, single-consumer channel used to ferry work items
/// from the C feature set pthread to the cooperative driver Swift Task.
///
/// Accepts both action work items (via `submitAction`) and array-next items
/// (via `submitArrayNext`).  Closed via `close()` after the C function returns;
/// `next()` returns `nil` when the channel is drained and closed.
public final class ActionDriverChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [DriverWorkItem] = []
    private var waiter: CheckedContinuation<DriverWorkItem?, Never>? = nil
    private var closed = false

    public init() {}

    /// Submit an action work item from the C pthread.
    public func submitAction(verb: String, result: ResultDescriptor, object: ObjectDescriptor,
                             context: ExecutionContext, holder: ActionRunnerResultBox,
                             semaphore: DispatchSemaphore) {
        let item = ActionDriverWorkItem(verb: verb, result: result, object: object,
                                       context: context, holder: holder, semaphore: semaphore)
        enqueue(.action(item))
    }

    /// Submit an array-next work item from `aro_array_get_next_ctx`.
    public func submitArrayNext(iterator: PipelinedDirectoryIterator,
                                holder: ActionRunnerResultBox,
                                semaphore: DispatchSemaphore) {
        enqueue(.arrayNext(ArrayNextWorkItem(iterator: iterator, holder: holder, semaphore: semaphore)))
    }

    private func enqueue(_ item: DriverWorkItem) {
        lock.lock()
        if let cont = waiter {
            waiter = nil
            lock.unlock()
            cont.resume(returning: item)
        } else {
            queue.append(item)
            lock.unlock()
        }
    }

    /// Receive the next work item on the driver Task.  Returns `nil` when the
    /// channel is closed and the queue is drained.
    ///
    /// Uses `withLock` (the Swift-6-safe scoped form) instead of bare `lock()`/`unlock()`
    /// so the async-context concurrency checker is satisfied.
    public func next() async -> DriverWorkItem? {
        // Fast path: item already queued (synchronous, no suspension)
        if let item = lock.withLock({ () -> DriverWorkItem? in
            guard let item = queue.first else { return nil }
            queue.removeFirst()
            return item
        }) {
            return item
        }
        // Closed and empty?
        if lock.withLock({ closed }) { return nil }

        // Slow path: register a continuation, re-checking under lock to close the TOCTOU
        // window between the two withLock calls above.
        return await withCheckedContinuation { (cont: CheckedContinuation<DriverWorkItem?, Never>) in
            lock.withLock {
                if let item = queue.first {
                    queue.removeFirst()
                    cont.resume(returning: item)
                } else if closed {
                    cont.resume(returning: nil)
                } else {
                    waiter = cont
                }
            }
        }
    }

    /// Signal end-of-stream after the C function returns.
    public func close() {
        lock.lock()
        closed = true
        if let cont = waiter {
            waiter = nil
            lock.unlock()
            cont.resume(returning: nil)
        } else {
            lock.unlock()
        }
    }
}

extension ActionRunner {
    /// Drive all action calls for a single feature set invocation cooperatively.
    ///
    /// Called as `Task.detached { await ActionRunner.shared.driveFeatureSet(channel) }`
    /// once per compiled feature set invocation.  The C feature set pthread submits
    /// work items via `channel.submitAction/submitArrayNext()` and the driver processes
    /// them cooperatively — no nested Task.detached per action or array iteration.
    public func driveFeatureSet(channel: ActionDriverChannel) async {
        while let item = await channel.next() {
            switch item {
            case .action(let actionItem):
                do {
                    let value = try await self.executeAsync(
                        verb: actionItem.verb,
                        result: actionItem.result,
                        object: actionItem.object,
                        context: actionItem.context
                    )
                    actionItem.holder.set(.success(value))
                } catch {
                    actionItem.holder.set(.failure(String(describing: error)))
                }
                actionItem.semaphore.signal()

            case .arrayNext(let nextItem):
                // Cooperative: await the next directory entry from the producer Task.
                // The producer runs on a different cooperative-pool thread, so this
                // await allows the producer to prefetch while the driver is suspended.
                if let entry = await nextItem.iterator.nextAsync() {
                    nextItem.holder.set(.success(entry as any Sendable))
                } else {
                    nextItem.holder.set(.failure("__exhausted__"))
                }
                nextItem.semaphore.signal()
            }
        }
    }
}
