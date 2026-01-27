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

    /// Private initializer
    private init() {
        self.registry = ActionRegistry.shared
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
        "observe": "watch"
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
}
