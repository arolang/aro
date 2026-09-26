// ============================================================
// RuntimeContext.swift
// ARO Runtime - Concrete Execution Context Implementation
// ============================================================

import Foundation
import AROParser

/// Monotonic counter bumped whenever any context registers a service or a
/// repository.
///
/// `RuntimeContext.service(_:)` / `repository(named:)` memoize their ancestor
/// walk against this value, so a registration anywhere invalidates every cached
/// answer without having to know which contexts cached what. Registrations are
/// rare (startup, `Connect`, `Store` creating a repository on demand); lookups
/// are not, and they are the walks that used to cost O(chain depth) each
/// (GitLab #473).
enum ServiceRegistrationClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _value: UInt64 = 0

    static var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    static func bump() {
        lock.lock()
        _value &+= 1
        lock.unlock()
    }
}

/// Concrete implementation of ExecutionContext
///
/// ## Sendable-safety of the `nonisolated(unsafe)` storage
///
/// RuntimeContext is an actor, but every `ExecutionContext` protocol method is
/// `nonisolated` so actions can call it synchronously without hopping onto the
/// actor executor. Those methods therefore touch the mutable stored properties
/// below directly, which is why each is marked `nonisolated(unsafe)` rather than
/// relying on actor isolation.
///
/// The invariant that makes this sound: **exactly one flow of control mutates a
/// given RuntimeContext instance at a time.** A single `FeatureSetExecutor`
/// drives one context through its statements serially — even though action work
/// runs on `ActionTaskExecutor` and `await` resumptions hop OS threads, the
/// mutations of *this* instance are strictly ordered and never overlap.
/// Genuinely concurrent regions (parallel `For each`, template rendering) do NOT
/// share this instance: they operate on their own child via
/// `createChild(...)` / `createTemplateContext()`, mutating only the child and
/// reading the parent read-only.
///
/// Mutation is serialised: every mutating entry point runs inside
/// `withExclusiveMutation { … }`, which takes this instance's storage lock.
/// All the `nonisolated(unsafe)` fields below share that one mechanism.
///
/// This used to be a DEBUG-only *detector* rather than a lock, resting on the
/// invariant that exactly one flow drives a context at a time. ARO-0088 ended
/// that invariant — deferred actions run concurrently and write their results
/// through to the feature-set context they belong to — so the detector was
/// replaced by the lock it could only have reported the absence of.
public actor RuntimeContext: ExecutionContext {
    // MARK: - Properties

    // Sendable-safety for all `nonisolated(unsafe)` fields in this type: the
    // storage lock taken by `withExclusiveMutation`, documented on the type
    // above. Not individually locked by design — one lock covers the set.

    /// Variable storage (now using TypedValue for type preservation)
    nonisolated(unsafe) private var variables: [String: TypedValue] = [:]

    /// Guards `variables` and `immutableVariables`. See `withExclusiveMutation`.
    private nonisolated let storageLock = NSRecursiveLock()

    /// Track which variables are user-defined (immutable) vs framework-internal (mutable)
    /// Only user variables enforce immutability; framework variables can be rebound
    nonisolated(unsafe) private var immutableVariables: Set<String> = []

    /// Categories written by the Configure action (ARO-0035). Reads of an
    /// UNSET setting on a configured category return nil instead of the
    /// happy-path error — §3.2's documented `when <x> = nil` idiom needs a
    /// value to compare, and configuration is optional by definition, unlike
    /// data (GitLab #506). Guarded by `storageLock`, mirrored nowhere.
    nonisolated(unsafe) private var configuredCategories: Set<String> = []

    /// Statement-scope marker (ARO-0088 §2).
    ///
    /// A deferred statement runs after later statements have already rebound the
    /// framework variables (`_with_`, `_where_value_`, `_literal_`, …) it reads,
    /// so each statement gets its own scope holding private copies of those. Any
    /// *other* binding an action makes — including its own result and any
    /// auxiliary names — writes through to the owning feature-set context, which
    /// is where consumers look for it.
    nonisolated(unsafe) private var _isStatementScope: Bool = false

    /// True when this scope is running a *deferred* action's body.
    ///
    /// A lookup that misses inside deferred work must not fall back to draining
    /// pending futures: the future being computed is itself in that set, so the
    /// drain would wait on the work that is doing the waiting. `RequestAction`
    /// finds this immediately — its config lookup misses on a normal program and
    /// the fallback deadlocked the process against itself.
    nonisolated(unsafe) private var _isDeferredScope: Bool = false

    /// Re-entrancy guard for `drainPendingFutures()`. Forcing a future can run
    /// code that reads another binding, which can miss, which would drain again.
    nonisolated(unsafe) private var _isDraining: Bool = false

    /// Call-frame marker for user-defined actions (ARO-0081).
    ///
    /// A variable lookup that reaches a call-frame root jumps straight to the
    /// application root instead of continuing through the caller: a callee sees
    /// its own bindings and application-level ones, never the locals of whatever
    /// feature set happened to call it. `input` is the only channel between
    /// caller and callee, which is what ARO-0081 already specifies and what
    /// `UserDefinedActionHost.buildInput` already works to enforce.
    ///
    /// It is also what keeps recursion linear. Each call parents its callee to
    /// the caller, so without the jump every lookup walked one link per live
    /// call — and `FeatureSetExecutor.execute` probes each published symbol on
    /// entry, so a 20 000-deep recursion spent 60 s walking chains (GitLab #473).
    nonisolated(unsafe) private var _isCallFrameRoot: Bool = false

    /// Cached application root of this chain, resolved once at init. `nil` means
    /// this context *is* the root. See `rootRuntimeContext`.
    private nonisolated let _inheritedRoot: RuntimeContext?

    /// Where a tail call parks itself instead of nesting a frame (ARO-0081).
    /// Installed by `UserDefinedActionHost` on the frame it is about to run.
    nonisolated(unsafe) private var _tailCallSlot: TailCallSlot?

    /// True while the executor runs a statement it has identified as a tail
    /// call. Read by the user-action dispatch handler, which parks instead of
    /// recursing. Lives on the frame; statement scopes ask their parent.
    nonisolated(unsafe) private var _isExecutingTailCallStatement: Bool = false

    /// How many user-action frames are live below this one, this one included.
    /// Computed once, at `markCallFrameRoot()`. Tail calls reuse a frame, so
    /// they do not increase it.
    nonisolated(unsafe) private var _callDepth: Int = 0

    /// The tail of the call chain that led here — most recent last, bounded so
    /// a deep recursion doesn't carry a deep array on every frame. Used only to
    /// make the runaway-recursion error name the actions involved.
    nonisolated(unsafe) private var _callChainTail: [String] = []

    /// Deferred action results bound in this context that have not been forced.
    ///
    /// A deferred action may bind names beyond its declared result (Split binding
    /// a count, Stream binding its handle). Those names do not exist until the
    /// action runs, so a lookup that misses drains this set and retries once
    /// before reporting the variable as undefined. See `drainPendingFutures()`.
    nonisolated(unsafe) private var pendingFutures: [AROFuture] = []

    /// Service registry
    nonisolated(unsafe) private var services: [ObjectIdentifier: any Sendable] = [:]

    /// Repository registry
    nonisolated(unsafe) private var repositories: [String: Any] = [:]

    /// Memoized ancestor-walk results for `service(_:)`, including misses.
    /// Stamped with `ServiceRegistrationClock` so any registration anywhere
    /// invalidates the whole cache. See `service(_:)` for the rationale.
    nonisolated(unsafe) private var serviceCache: [ObjectIdentifier: (generation: UInt64, value: (any Sendable)?)] = [:]

    /// Memoized ancestor-walk results for `repository(named:)`. Same stamping
    /// scheme as `serviceCache`.
    nonisolated(unsafe) private var repositoryCache: [String: (generation: UInt64, value: Any?)] = [:]

    /// Current response
    nonisolated(unsafe) private var _response: Response?

    /// Error tracking for binary mode
    nonisolated(unsafe) private var _executionError: Error?

    /// DI container providing shared infrastructure services
    public nonisolated let container: RuntimeContainer

    /// Event bus for event emission
    public nonisolated let eventBus: EventBus?

    /// Wait state flag
    nonisolated(unsafe) private var _isWaiting: Bool = false

    /// Continuation for wait/shutdown signaling
    nonisolated(unsafe) private var shutdownContinuation: CheckedContinuation<Void, Error>?

    /// Output context for formatting
    private nonisolated let _outputContext: OutputContext

    /// Whether this is a compiled binary execution
    private nonisolated let _isCompiled: Bool

    /// Phase 2 async driver channel — set once at context init time by
    /// AROCContextHandle for compiled binary feature sets.  When non-nil,
    /// ActionRunner.executeSyncWithResult submits work here instead of
    /// spawning a new Task.detached per action call.
    public nonisolated let driverChannel: ActionDriverChannel?

    /// Template output buffer (ARO-0050).
    ///
    /// Capped per #317 to bound the worst-case memory growth — runaway
    /// loops in template code (e.g. unbounded `For each` that appends
    /// HTML on every tick) used to exhaust available RAM before the
    /// process noticed anything was wrong. The cap is a soft ceiling:
    /// once exceeded, further appends are silently dropped and
    /// `templateBufferOverflowed` flips to true so callers can surface
    /// the truncation in their output / error path.
    nonisolated(unsafe) private var _templateBuffer: String = ""

    /// Upper bound on the template buffer (#317). 100 MB is large
    /// enough that legitimate Mustache / HTML rendering never hits it
    /// but small enough that a runaway loop won't OOM the process
    /// before the runtime can recover. UTF-8 byte count.
    public static let defaultTemplateBufferMaxBytes: Int = 100 * 1024 * 1024

    /// Per-instance template buffer cap. Read at every
    /// `appendToTemplateBuffer` so a future runtime-config knob can
    /// dial it without recompiling. Defaults to
    /// `defaultTemplateBufferMaxBytes`.
    nonisolated(unsafe) public var templateBufferMaxBytes: Int = RuntimeContext.defaultTemplateBufferMaxBytes

    /// True once an append was dropped because the buffer would have
    /// exceeded `templateBufferMaxBytes`. Reset by
    /// `flushTemplateBuffer`. Useful for diagnostics — a successful
    /// render with `overflowed == true` means the output was
    /// truncated.
    nonisolated(unsafe) public private(set) var templateBufferOverflowed: Bool = false

    /// Tracks whether we've already warned about the overflow on
    /// stderr. We log once per buffer (per flush) instead of per
    /// dropped append so a runaway loop doesn't drown the log.
    nonisolated(unsafe) private var _templateBufferOverflowWarned: Bool = false

    /// Whether this is a template rendering context
    private nonisolated let _isTemplateContext: Bool

    /// How values printed into the template buffer are escaped (GitLab #476).
    /// Set by the template engine once the template's path is known.
    nonisolated(unsafe) private var _templateEscaping: TemplateEscaping = .none

    /// Schema registry for typed event extraction (ARO-0046)
    nonisolated(unsafe) private var _schemaRegistry: SchemaRegistry?

    /// Mutable scope depth for while loops (GitLab #131)
    /// When > 0, all bind calls automatically allow rebinding
    nonisolated(unsafe) private var mutableScopeDepth: Int = 0

    // MARK: - Metadata

    public nonisolated let featureSetName: String
    public nonisolated let businessActivity: String
    public nonisolated let executionId: String
    public nonisolated let parent: ExecutionContext?

    /// Who this execution is on behalf of (ARO-0094). Inherited from the
    /// parent unless the transport that built this context said otherwise —
    /// so a `for each` body, a template render and a user-defined action call
    /// all stay with the caller the request arrived as.
    public nonisolated let caller: CallerIdentity

    // MARK: - Initialization

    /// Initialize a new runtime context
    /// - Parameters:
    ///   - featureSetName: Name of the feature set being executed
    ///   - businessActivity: Business activity this feature set belongs to
    ///   - outputContext: Output context for formatting (defaults to .human)
    ///   - eventBus: Optional event bus for event emission (overrides container.eventBus when provided)
    ///   - container: DI container providing shared services (defaults to `.default`)
    ///   - parent: Optional parent context for nested execution
    ///   - isCompiled: Whether this is a compiled binary execution (defaults to false)
    ///   - isTemplateContext: Whether this is a template rendering context (defaults to false)
    public init(
        featureSetName: String,
        businessActivity: String = "",
        outputContext: OutputContext = .human,
        eventBus: EventBus? = nil,
        container: RuntimeContainer? = nil,
        parent: ExecutionContext? = nil,
        isCompiled: Bool = false,
        isTemplateContext: Bool = false,
        driverChannel: ActionDriverChannel? = nil,
        caller: CallerIdentity? = nil
    ) {
        self.featureSetName = featureSetName
        self.businessActivity = businessActivity
        self.executionId = UUID().uuidString
        self._outputContext = outputContext
        self._isCompiled = isCompiled
        self._isTemplateContext = isTemplateContext
        self.driverChannel = driverChannel
        self.parent = parent

        // Caller resolution order: explicit > inherit from parent > none.
        // Inheritance is the important half: transports set the caller once,
        // on the context they build for the request, and every child made
        // below it — loop bodies, template renders, `Application.<Name>`
        // frames — must resolve the same partition or a nested `Store` would
        // write somewhere the enclosing `Retrieve` never looks.
        self.caller = caller ?? (parent as? RuntimeContext)?.caller ?? .none

        // Resolve the chain root once, so a call-frame jump costs nothing at
        // lookup time (see `_isCallFrameRoot`).
        if let parentCtx = parent as? RuntimeContext {
            self._inheritedRoot = parentCtx._inheritedRoot ?? parentCtx
        } else {
            self._inheritedRoot = nil
        }

        // Container resolution order: explicit > inherit from parent > global default
        let resolvedContainer: RuntimeContainer
        if let c = container {
            resolvedContainer = c
        } else if let parentCtx = parent as? RuntimeContext {
            resolvedContainer = parentCtx.container
        } else {
            resolvedContainer = .default
        }
        self.container = resolvedContainer

        // EventBus resolution order: explicit > container
        self.eventBus = eventBus ?? resolvedContainer.eventBus
    }

    // MARK: - Variable Management

    public nonisolated func resolve<T: Sendable>(_ name: String) -> T? {
        // A miss does NOT fall back to draining pending work.
        //
        // That fallback was tried and removed: lookups miss constantly (magic
        // names, optional modifiers, shadowed bindings), so every miss forced
        // everything outstanding and deferral collapsed back to sequential —
        // measurably so, 4s of overlap turning into 4s of waiting. A deferred
        // action's declared result is bound as a handle the moment the statement
        // runs, so the ordinary case never needs this; anything an action binds
        // *beyond* its declared result appears once that result is read, or at
        // feature-set exit (ARO-0088 §3).
        resolveWithoutDraining(name)
    }

    nonisolated func resolveWithoutDraining<T: Sendable>(_ name: String) -> T? {
        // Iterative parent walk — see `ancestorHolding(_:)` for why the walk is
        // a loop rather than recursion (GitLab #473). A local binding whose
        // value does not cast to `T` keeps the walk going, exactly as the
        // recursive version's fall-through did: a shadowing binding of the
        // wrong type must not hide a usable one further up.
        var current: RuntimeContext = self
        while true {
            if let typedValue = current.localVariable(name) {
                // Reading a deferred result is a force point (ARO-0088 §3):
                // block here until the action that produces it has finished.
                if let future = typedValue.value as? AROFuture {
                    do {
                        let forced = try future.force()
                        if let bound = current.bindingProducedWhileForcing(name) { return bound as? T }
                        return forced as? T
                    } catch {
                        // Record the failure so feature-set exit reports it with
                        // both spans rather than letting a typed read swallow it
                        // as nil.
                        current.recordDeferredFailure(
                            error, binding: name, sourceLocation: future.sourceLocation)
                        return nil
                    }
                }
                if let value = typedValue.value as? T {
                    return value
                }
            }
            // Walk on without the drain fallback: the decision to drain is taken
            // once, by the context the read entered on. Re-deciding it per
            // ancestor reintroduces the self-deadlock the `isInsideDeferredWork`
            // guard exists to prevent, because an ancestor is not itself
            // "inside" deferred work.
            switch Self.nextVariableScope(after: current) {
            case .scope(let next):
                current = next
            case .foreign(let foreign):
                return foreign.resolve(name)
            case .end:
                return nil
            }
        }
    }

    /// The nearest context in this chain (starting with `self`) whose own
    /// storage holds `name`.
    ///
    /// Returns `(nil, foreignParent)` when the walk fell off the end of the
    /// `RuntimeContext` chain without a hit: the caller hands off to the
    /// protocol-typed ancestor, which only synthetic test contexts ever are.
    ///
    /// **Why this is a loop.** Every lookup used to recurse into `parent`, one
    /// native stack frame per level. `UserDefinedActionHost` parents each callee
    /// to its caller, so chain depth equals ARO recursion depth — meaning a
    /// recursive program paid `depth` native frames on *every* variable and
    /// service lookup. That, not the ARO call frames (which are `async` and
    /// therefore heap-allocated), is what killed a recursive program with
    /// SIGBUS at ~1300 frames on the 512 KB cooperative-pool stack: the crash
    /// report's faulting thread was a stack of `RuntimeContext.service<A>(_:)`
    /// frames. Iterating costs one frame regardless of depth (GitLab #473).
    private nonisolated func ancestorHolding(
        _ name: String
    ) -> (owner: RuntimeContext?, foreignParent: ExecutionContext?) {
        var current: RuntimeContext = self
        while true {
            if current.localVariable(name) != nil { return (current, nil) }
            switch Self.nextVariableScope(after: current) {
            case .scope(let next):
                current = next
            case .foreign(let foreign):
                return (nil, foreign)
            case .end:
                return (nil, nil)
            }
        }
    }

    /// Where a *variable* lookup goes after `ctx`.
    enum VariableScopeStep {
        /// Another `RuntimeContext` to consult.
        case scope(RuntimeContext)
        /// A protocol-typed ancestor — hand the lookup to it (test contexts only).
        case foreign(ExecutionContext)
        /// End of the chain.
        case end
    }

    /// The application root of this chain (itself, if this is the root).
    nonisolated var rootRuntimeContext: RuntimeContext { _inheritedRoot ?? self }

    /// Ordinary scopes chain to their parent; a call-frame root jumps to the
    /// application root, skipping the caller's locals entirely. See
    /// `_isCallFrameRoot` for why.
    static func nextVariableScope(after ctx: RuntimeContext) -> VariableScopeStep {
        if ctx._isCallFrameRoot {
            let root = ctx.rootRuntimeContext
            return root === ctx ? .end : .scope(root)
        }
        guard let parent = ctx.parent else { return .end }
        guard let runtimeParent = parent as? RuntimeContext else { return .foreign(parent) }
        return .scope(runtimeParent)
    }

    /// Mark this context as a user-defined action's own frame (ARO-0081).
    ///
    /// Called by `UserDefinedActionHost` right after it spawns the callee
    /// context. Inside deferred work the marker also has to carry the deferred
    /// flag across the jump: the callee genuinely *is* running inside the
    /// caller's deferred statement, and the lookup chain no longer passes
    /// through the scope that says so.
    // MARK: - Tail Calls (ARO-0081)

    /// Install the slot a tail call in this frame parks itself in.
    public nonisolated func installTailCallSlot(_ slot: TailCallSlot) {
        _tailCallSlot = slot
    }

    /// The tail-call slot governing the frame this context belongs to.
    /// A statement scope finds its frame one link up; nothing crosses a call
    /// boundary, so a nested call can never park in its caller's slot.
    public nonisolated var enclosingTailCallSlot: TailCallSlot? {
        if let slot = _tailCallSlot { return slot }
        guard !_isCallFrameRoot, let runtimeParent = parent as? RuntimeContext else { return nil }
        return runtimeParent._tailCallSlot
    }

    /// Mark/unmark the statement currently executing in this frame as a tail call.
    public nonisolated func setExecutingTailCallStatement(_ value: Bool) {
        _isExecutingTailCallStatement = value
    }

    /// Whether the statement being executed in the enclosing frame is a tail call.
    public nonisolated var isExecutingTailCallStatement: Bool {
        if _isExecutingTailCallStatement { return true }
        guard !_isCallFrameRoot, let runtimeParent = parent as? RuntimeContext else { return false }
        return runtimeParent._isExecutingTailCallStatement
    }

    public nonisolated func markCallFrameRoot() {
        _isCallFrameRoot = true
        if let runtimeParent = parent as? RuntimeContext {
            if runtimeParent.isInsideDeferredWork {
                _isDeferredScope = true
            }
            let caller = runtimeParent.enclosingCallFrame
            _callDepth = (caller?._callDepth ?? 0) + 1
            var chain = caller?._callChainTail ?? []
            chain.append(featureSetName)
            if chain.count > Self.callChainTailLimit {
                chain.removeFirst(chain.count - Self.callChainTailLimit)
            }
            _callChainTail = chain
        } else {
            _callDepth = 1
            _callChainTail = [featureSetName]
        }
    }

    /// How many user-action frames are live, this one included.
    public nonisolated var callDepth: Int { _callDepth }

    /// The last few actions on the way here, most recent last.
    public nonisolated var callChainTail: [String] { _callChainTail }

    private static let callChainTailLimit = 4

    /// The nearest enclosing user-action frame, if execution is inside one.
    private nonisolated var enclosingCallFrame: RuntimeContext? {
        var current: RuntimeContext = self
        while true {
            if current._isCallFrameRoot { return current }
            guard let runtimeParent = current.parent as? RuntimeContext else { return nil }
            current = runtimeParent
        }
    }

    public nonisolated func resolveAny(_ name: String) -> (any Sendable)? {
        // No drain-on-miss — see `resolve(_:)`.
        resolveAnyWithoutDraining(name)
    }

    // MARK: - Magic Variables

    /// What a framework-provided name resolves to, if it is one.
    enum MagicResolution {
        /// The name is the framework's to answer — with this value, which may
        /// itself be nil (a `<contract>` read in an application with no
        /// contract resolves to nothing rather than to a variable).
        case resolved((any Sendable)?)
        /// Not a framework name, or — for `<http-server>` with no contract
        /// loaded — a framework name that defers to the variable store.
        case notMagic
    }

    /// The names the framework answers itself.
    ///
    /// The list was written out three times, once per resolve entry point, so
    /// adding a magic variable meant remembering all three; `resolveAnyRaw` and
    /// `resolveAnyAsync` only need to know that a name *is* magic, because a
    /// magic name never holds a future.
    static let magicNames: Set<String> = [
        "now", "contract", "Contract", "http-server", "httpServer",
        "metrics", "application"
    ]

    /// Resolve a framework-provided name.
    nonisolated func resolveMagic(_ name: String) -> MagicResolution {
        switch name {
        case "now":
            // Through `service(_:)`, not the local dictionary: services are
            // registered on the root context, and a statement scope has none of
            // its own (ARO-0088 §2).
            let dateService = service(DateService.self) ?? DefaultDateService()
            return .resolved(dateService.now(timezone: nil))

        case "contract", "Contract":
            // <Contract> or <contract> returns OpenAPI contract metadata
            return .resolved(buildContractObject())

        case "http-server", "httpServer":
            // <http-server> returns Contract.http-server, so both <Contract>
            // and <http-server> work. Falls through to the regular variable
            // store when no contract is available — e.g. in binary mode after
            // `Start the <http-server>` binds a ServerStartResult.
            if let httpServer = buildContractObject()?.httpServer {
                return .resolved(httpServer)
            }
            return .notMagic

        case "metrics":
            // <metrics> returns current execution metrics
            return .resolved(container.metricsCollector.snapshot())

        case "application":
            // <application> provides application context (Stop/Close actions)
            return .resolved(["type": "application"] as [String: any Sendable])

        default:
            return .notMagic
        }
    }

    nonisolated func resolveAnyWithoutDraining(_ name: String) -> (any Sendable)? {
        // Names the framework answers itself, before any variable store is
        // consulted (`<now>`, `<contract>`, `<metrics>`, …).
        if case .resolved(let value) = resolveMagic(name) { return value }

        // Iterative walk without the drain fallback — see `resolveWithoutDraining`
        // for the drain reasoning and `ancestorHolding` for why it is a loop.
        let (owner, foreignParent) = ancestorHolding(name)
        guard let ctx = owner else { return foreignParent?.resolveAny(name) }
        guard let typedValue = ctx.localVariable(name) else { return nil }

        // Issue #55, Phase 2: a binding may hold an AROFuture under lazy mode.
        // Synchronous resolve callers expect a concrete value, so we force
        // here. This is a force-point that converts the consumer-of-binding
        // pattern into a sync wait. Async-aware callers should use
        // `resolveAnyAsync(_:)` to await without blocking a pthread.
        if let future = typedValue.value as? AROFuture {
            do {
                let forced = try future.force()
                if let bound = ctx.bindingProducedWhileForcing(name) { return bound }
                return forced
            } catch {
                // Previously this returned "" — a failed action became an
                // empty string at the read site with nothing reported. Keep
                // the read total, but remember the failure so feature-set
                // exit can surface it (ARO-0088 §4).
                ctx.recordDeferredFailure(
                    error, binding: name, sourceLocation: future.sourceLocation)
                return ""
            }
        }
        return typedValue.value
    }

    /// Resolve a binding without forcing an AROFuture. Returns the AROFuture
    /// itself when the binding holds one, otherwise the materialized value.
    ///
    /// Used by EmitAction to capture lazy payload handles into a DomainEvent
    /// so the value is forced at *first handler read* (memoized for the rest)
    /// instead of eagerly at emit time. See issue #55 — "Resolved Emit
    /// semantics: payload materialization → force at first handler read."
    ///
    /// Magic variables (e.g. `<now>`, `<contract>`) never produce futures and
    /// fall through to the regular resolveAny path.
    public nonisolated func resolveAnyRaw(_ name: String) -> (any Sendable)? {
        if Self.magicNames.contains(name) {
            return resolveAny(name)
        }
        let (owner, foreignParent) = ancestorHolding(name)
        guard let ctx = owner else { return foreignParent?.resolveAny(name) }
        return ctx.localVariable(name)?.value
    }

    /// Async variant of `resolveAny(_:)` that awaits AROFuture bindings via
    /// `future.value()` instead of blocking. Use this from any `async` action
    /// or task body so the cooperative pool doesn't have a thread tied up
    /// blocking on another task on the same pool.
    ///
    /// Issue #55, Phase 2.
    public nonisolated func resolveAnyAsync(_ name: String) async -> (any Sendable)? {
        // Magic variables short-circuit through the sync path — they don't
        // produce futures.
        if Self.magicNames.contains(name) {
            return resolveAny(name)
        }
        let (owner, foreignParent) = ancestorHolding(name)
        guard let ctx = owner else { return foreignParent?.resolveAny(name) }
        guard let typedValue = ctx.localVariable(name) else { return nil }
        if let future = typedValue.value as? AROFuture {
            do {
                return try await future.value()
            } catch {
                ctx.recordDeferredFailure(
                    error, binding: name, sourceLocation: future.sourceLocation)
                return ""
            }
        }
        return typedValue.value
    }

    /// Resolve a variable returning the full TypedValue (type + value)
    public nonisolated func resolveTyped(_ name: String) -> TypedValue? {
        let (owner, foreignParent) = ancestorHolding(name)
        guard let ctx = owner else {
            // Fall back to resolveAny on the protocol-typed ancestor and wrap
            // with unknown type.
            if let value = foreignParent?.resolveAny(name) {
                return TypedValue(value, type: .unknown)
            }
            return nil
        }
        guard let typedValue = ctx.localVariable(name) else { return nil }
        // Force here too: a TypedValue wrapping an unforced handle would
        // leak an AROFuture into every consumer that inspects `.type`
        // or `.value` directly (ARO-0088 §3).
        if let future = typedValue.value as? AROFuture {
            do {
                return TypedValue.infer(try future.force())
            } catch {
                ctx.recordDeferredFailure(
                    error, binding: name, sourceLocation: future.sourceLocation)
                return TypedValue.infer("")
            }
        }
        return typedValue
    }

    /// Get the type of a variable without retrieving its value
    public nonisolated func typeOf(_ name: String) -> DataType? {
        // Only `RuntimeContext` ancestors carry type information, so a walk that
        // falls off the chain reports nothing — same as the recursive version.
        let (owner, _) = ancestorHolding(name)
        return owner?.localVariable(name)?.type
    }

    /// Build the Contract magic object from OpenAPI spec service
    private nonisolated func buildContractObject() -> Contract? {
        // Parent-walking lookup: reading `services` directly made `<contract>`
        // undefined inside a statement scope, which broke every HTTP example.
        guard let specService = service(OpenAPISpecService.self) else {
            return nil
        }

        // Extract server configuration from OpenAPI spec
        let port = specService.serverPort ?? 8080
        let hostname = specService.serverHost ?? "0.0.0.0"
        let routes = specService.spec.paths.map { $0.key }
        let routeCount = routes.count

        let httpServer = HTTPServerConfig(
            port: port,
            hostname: hostname,
            routes: routes,
            routeCount: routeCount
        )

        return Contract(httpServer: httpServer)
    }

    public nonisolated func bind(_ name: String, value: any Sendable) {
        bind(name, value: value, allowRebind: false)
    }

    /// Record that `category` was written by Configure (ARO-0035), so
    /// reads of its unset settings answer nil rather than erroring.
    public nonisolated func markConfigured(_ category: String) {
        storageLock.lock()
        configuredCategories.insert(category)
        storageLock.unlock()
    }

    /// Whether `category` was Configure-written in this context or any
    /// ancestor (children read configuration through the parent chain,
    /// like every other resolution).
    ///
    /// A loop, not a recursion: this sits on the miss path of `ExtractAction`,
    /// so it is reached inside recursive user actions — exactly the depth that
    /// `ancestorHolding` documents as fatal for a per-level stack frame.
    public nonisolated func isConfigured(_ category: String) -> Bool {
        firstInChain { context in
            context.storageLock.lock()
            let local = context.configuredCategories.contains(category)
            context.storageLock.unlock()
            return local ? true : nil
        } ?? false
    }

    /// The first non-nil answer from this context or a `RuntimeContext`
    /// ancestor, nearest first.
    ///
    /// Iterative for the reason spelled out on `ancestorHolding`: a chain is as
    /// deep as the program's recursion, and one native frame per level killed a
    /// recursive program with SIGBUS at ~1300 frames (GitLab #473). Anything
    /// that reads through the parent chain is written this way.
    private nonisolated func firstInChain<T>(_ read: (RuntimeContext) -> T?) -> T? {
        var current: RuntimeContext = self
        while true {
            if let found = read(current) { return found }
            guard let runtimeParent = current.parent as? RuntimeContext else { return nil }
            current = runtimeParent
        }
    }

    public nonisolated func bind(_ name: String, value: any Sendable, allowRebind: Bool) {
        // Auto-wrap with inferred type
        let typedValue: TypedValue
        if let tv = value as? TypedValue {
            typedValue = tv
        } else {
            typedValue = TypedValue.infer(value)
        }
        bindTyped(name, value: typedValue, allowRebind: allowRebind)
    }

    /// Bind a variable with explicit type information
    public nonisolated func bindTyped(_ name: String, value: TypedValue) {
        bindTyped(name, value: value, allowRebind: false)
    }

    /// Bind a variable with explicit type information and rebind option
    public nonisolated func bindTyped(_ name: String, value: TypedValue, allowRebind: Bool) {
        // Check immutability: framework variables (_prefix) can be rebound
        let isFrameworkVariable = name.hasPrefix("_")

        // Statement scopes keep only the framework variables private; everything
        // an action binds belongs to the feature set, not to the statement that
        // happened to produce it (ARO-0088 §2).
        if _isStatementScope, !isFrameworkVariable,
           let owner = parent as? RuntimeContext {
            owner.bindTyped(name, value: value, allowRebind: allowRebind)
            return
        }

        let alreadyImmutable = withExclusiveMutation { immutableVariables.contains(name) }

        // A binding that currently holds a *pending* result accepts one more
        // write: the action that produces it binds its own value when it
        // finishes, and that is the same binding being completed, not a second
        // one (ARO-0088 §2). Without this, deferral turns every action that
        // binds its own result — Split, Group, Merge, Stream, … — into an
        // immutable-rebind trap.
        let holdsPendingResult = localVariable(name)?.value is AROFuture

        if !isFrameworkVariable && !allowRebind && !holdsPendingResult
            && mutableScopeDepth == 0 && alreadyImmutable {
            // GitLab #495: this used to be a fatalError, which took the whole
            // process down — a REPL/notebook kernel died with SIGTRAP, and an
            // `aro run` server crashed mid-request. Per ARO-0006 the message is
            // only useful if the process survives to deliver it, so the write
            // is refused (the existing value stays) and the violation is
            // recorded for the executor to throw as a statement-attributed
            // error. `bind` stays non-throwing because it is called from every
            // action, plugin bridge, and framework-variable site; the executor
            // checks after each statement (`throwRefusedRebind`), and
            // feature-set exit is the backstop for binds no statement check
            // observed (deferred actions, event-driven binds).
            recordRebindViolation(AROError(
                message: """
                    Cannot rebind immutable variable '\(name)'

                    Variables in ARO are immutable. Once bound, they cannot be changed.
                    Create a new variable instead: <Action> the <\(name)-updated> ...

                    This error indicates the semantic analyzer missed a duplicate binding.
                    Please report this as a compiler bug.
                    """,
                featureSet: featureSetName,
                businessActivity: businessActivity,
                statement: "(bind of <\(name)>, reported by the runtime immutability backstop)"
            ))
            return
        }

        // A pending result is a placeholder, not yet a user-visible binding, so
        // it does not make the name immutable — the value that lands does.
        //
        // Marking it at placeholder time is subtly wrong and fails in a way that
        // depends on interleaving: the producing action binds its own result
        // when it finishes, and an effect may legitimately rebind after that
        // (`Store` writes back generated ids). Both were fine when an action
        // bound exactly once at its statement. With deferral they raced, and
        // DirectoryReplicatorEvents trapped on Linux — passing on macOS, which
        // is exactly the signature of an ordering-dependent rule.
        let isPendingPlaceholder = value.value is AROFuture

        withExclusiveMutation {
            variables[name] = value

            // Mark user variables as immutable (framework variables stay mutable)
            if !isFrameworkVariable && !isPendingPlaceholder {
                immutableVariables.insert(name)
            }
        }
    }

    public nonisolated func unbind(_ name: String) {
        withExclusiveMutation {
            variables.removeValue(forKey: name)
            immutableVariables.remove(name)
        }
    }

    /// Enter a mutable scope (e.g., while loop body). Variables can be rebound within this scope.
    public nonisolated func enterMutableScope() {
        withExclusiveMutation { mutableScopeDepth += 1 }
    }

    /// Exit a mutable scope. Restores immutability enforcement when depth reaches zero.
    public nonisolated func exitMutableScope() {
        withExclusiveMutation {
            if mutableScopeDepth > 0 { mutableScopeDepth -= 1 }
        }
    }

    public nonisolated func exists(_ name: String) -> Bool {
        let (owner, foreignParent) = ancestorHolding(name)
        if owner != nil { return true }
        return foreignParent?.exists(name) ?? false
    }

    /// Check if a variable is bound in THIS context only (ignoring parent contexts).
    /// Used by FeatureSetExecutor to decide whether to create a local shadow binding.
    public nonisolated func existsLocally(_ name: String) -> Bool {
        return localVariable(name) != nil
    }

    /// Whether a plain `bind(name, …)` from here would be refused as an
    /// immutable rebind — the same decision `bindTyped(_:value:allowRebind:)`
    /// makes, asked before the write instead of after it.
    ///
    /// An action that produces an effect *and* a binding needs this: Store
    /// with an inline payload writes a row and then binds the stored record,
    /// so discovering the conflict from the refusal would leave the row behind
    /// (GitLab #515). Statement scopes forward, because that is where the bind
    /// would land.
    public nonisolated func wouldRefuseRebind(_ name: String) -> Bool {
        if name.hasPrefix("_") { return false }
        if _isStatementScope, let owner = parent as? RuntimeContext {
            return owner.wouldRefuseRebind(name)
        }
        if localVariable(name)?.value is AROFuture { return false }
        return withExclusiveMutation {
            mutableScopeDepth == 0 && immutableVariables.contains(name)
        }
    }

    public nonisolated var variableNames: Set<String> {
        var names = Set<String>()
        var current: RuntimeContext = self
        while true {
            names.formUnion(current.withExclusiveMutation { Set(current.variables.keys) })
            switch Self.nextVariableScope(after: current) {
            case .scope(let next):
                current = next
            case .foreign(let foreign):
                names.formUnion(foreign.variableNames)
                return names
            case .end:
                return names
            }
        }
    }

    // MARK: - Service Access

    /// Look up a service, walking ancestors when this context has none of its own.
    ///
    /// Memoized against `ServiceRegistrationClock`, including misses. Without the
    /// memo the walk is O(chain depth) on every call, and chain depth equals ARO
    /// recursion depth — so a recursive program spent quadratic time in service
    /// lookups even once the walk stopped overflowing the stack (GitLab #473).
    /// Registrations are rare and bump the clock, which invalidates every cached
    /// answer at once; over-invalidation just costs one more walk.
    public nonisolated func service<S>(_ type: S.Type) -> S? {
        let id = ObjectIdentifier(type)
        let generation = ServiceRegistrationClock.current

        var current: RuntimeContext = self
        while true {
            // A warm ancestor cache ends the walk: it already holds the answer
            // for the rest of the chain above it. This is what makes the walk
            // O(1) amortized in a deep recursion — the caller's frame resolved
            // the same services one call earlier, so a fresh frame stops after a
            // single link instead of walking every live call (GitLab #473).
            if let cached = current.withExclusiveMutation({ current.serviceCache[id] }),
               cached.generation == generation {
                if current !== self {
                    withExclusiveMutation { serviceCache[id] = cached }
                }
                return cached.value as? S
            }
            if let found = current.withExclusiveMutation({ current.services[id] }) {
                withExclusiveMutation { serviceCache[id] = (generation, found) }
                return found as? S
            }
            guard let runtimeParent = current.parent as? RuntimeContext else {
                guard let foreignParent = current.parent else {
                    // Walked the whole chain with no hit — memoize the miss so a
                    // repeated lookup of an absent service stays O(1) too.
                    withExclusiveMutation { serviceCache[id] = (generation, nil) }
                    return nil
                }
                // A protocol-typed ancestor owns its own storage and never bumps
                // our clock, so its answer is deliberately not memoized. Only
                // synthetic test contexts take this path.
                return foreignParent.service(type)
            }
            current = runtimeParent
        }
    }

    /// Register a service.
    ///
    /// Forwarded to the owning context from a statement scope, for the same
    /// reason bindings are: a service an action registers belongs to the feature
    /// set, not to the statement that happened to create it. `Connect` registers
    /// its socket client this way, and registering it on a scope that is
    /// discarded at the end of the statement left inbound packets with nowhere
    /// to go — the handler simply never fired (ARO-0088 §2).
    public nonisolated func register<S: Sendable>(_ service: S) {
        if _isStatementScope, let owner = parent as? RuntimeContext {
            owner.register(service)
            return
        }
        withExclusiveMutation { services[ObjectIdentifier(S.self)] = service }
        ServiceRegistrationClock.bump()
    }

    /// Register a service with an explicit type ID (for preserving type info across type-erased collections)
    public nonisolated func registerWithTypeId(_ typeId: ObjectIdentifier, service: any Sendable) {
        if _isStatementScope, let owner = parent as? RuntimeContext {
            owner.registerWithTypeId(typeId, service: service)
            return
        }
        withExclusiveMutation { services[typeId] = service }
        ServiceRegistrationClock.bump()
    }

    // MARK: - Repository Access

    /// Look up a repository by name. Iterative and memoized for the same reason
    /// as `service(_:)` — see its documentation (GitLab #473).
    public nonisolated func repository<T: Sendable>(named name: String) -> (any Repository<T>)? {
        let generation = ServiceRegistrationClock.current

        var current: RuntimeContext = self
        while true {
            // Warm ancestor cache ends the walk — see `service(_:)`.
            if let cached = current.withExclusiveMutation({ current.repositoryCache[name] }),
               cached.generation == generation {
                if current !== self {
                    withExclusiveMutation { repositoryCache[name] = cached }
                }
                return cached.value as? any Repository<T>
            }
            if let repo = current.withExclusiveMutation({ current.repositories[name] }) {
                withExclusiveMutation { repositoryCache[name] = (generation, repo) }
                return repo as? any Repository<T>
            }
            guard let runtimeParent = current.parent as? RuntimeContext else {
                guard let foreignParent = current.parent else {
                    withExclusiveMutation { repositoryCache[name] = (generation, nil) }
                    return nil
                }
                return foreignParent.repository(named: name)
            }
            current = runtimeParent
        }
    }

    public nonisolated func registerRepository<T: Sendable>(name: String, repository: any Repository<T>) {
        // Same reasoning as `register(_:)`: a repository belongs to the feature
        // set, not the statement.
        if _isStatementScope, let owner = parent as? RuntimeContext {
            owner.registerRepository(name: name, repository: repository)
            return
        }
        withExclusiveMutation { repositories[name] = repository }
        ServiceRegistrationClock.bump()
    }

    // MARK: - Response Management

    public nonisolated func setResponse(_ response: Response) {
        // The response belongs to the feature set, not to the statement that
        // produced it. Without this, `Return` inside a statement scope would set
        // it somewhere the executor never looks, and every feature set would
        // fall through to the default response (ARO-0088 §2).
        if _isStatementScope, let owner = parent as? RuntimeContext {
            owner.setResponse(response)
            return
        }
        withExclusiveMutation { _response = response }
    }

    public nonisolated func getResponse() -> Response? {
        if _isStatementScope, let owner = parent as? RuntimeContext {
            return owner.getResponse()
        }
        return _response
    }

    // MARK: - Error Management (for binary mode)

    /// Set an execution error (e.g., from action failures)
    public nonisolated func setExecutionError(_ error: Error) {
        if _isStatementScope, let owner = parent as? RuntimeContext {
            owner.setExecutionError(error)
            return
        }
        withExclusiveMutation {
            if _executionError == nil {
                _executionError = error
            }
        }
    }

    /// Get the execution error if one occurred
    public nonisolated func getExecutionError() -> Error? {
        if _isStatementScope, let owner = parent as? RuntimeContext {
            return owner.getExecutionError()
        }
        return _executionError
    }

    /// Check if an execution error occurred
    public nonisolated func hasExecutionError() -> Bool {
        if _isStatementScope, let owner = parent as? RuntimeContext {
            return owner.hasExecutionError()
        }
        return _executionError != nil
    }

    // MARK: - Event Emission

    public nonisolated func emit(_ event: any RuntimeEvent) {
        eventBus?.publish(event)
    }

    // MARK: - Statement Scope and Deferred Results (ARO-0088)

    /// Create the per-statement scope a statement's framework variables live in.
    ///
    /// Reads fall through to this context; writes fall through too, except for
    /// `_`-prefixed framework variables, which stay private so a deferred action
    /// still sees the modifiers written next to it rather than the next
    /// statement's.
    public nonisolated func createStatementScope() -> RuntimeContext {
        let scope = RuntimeContext(
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            outputContext: _outputContext,
            eventBus: eventBus,
            container: container,
            parent: self,
            isCompiled: _isCompiled,
            isTemplateContext: _isTemplateContext,
            driverChannel: driverChannel
        )
        scope._isStatementScope = true
        return scope
    }

    /// Mark this scope as the body of a deferred action. See `_isDeferredScope`.
    public nonisolated func markDeferredScope() {
        _isDeferredScope = true
    }

    /// Copy this context's framework variables (`_`-prefixed) into `scope`.
    ///
    /// The interpreter builds a statement's modifiers directly in its scope, so
    /// it needs nothing here. The compiled bridge is handed a context that
    /// already holds them and then clears them right after dispatch, so a
    /// deferred action has to take its own copy before that happens.
    public nonisolated func copyFrameworkVariables(to scope: RuntimeContext) {
        let snapshot = withExclusiveMutation { variables.filter { $0.key.hasPrefix("_") } }
        for (name, value) in snapshot {
            scope.bindTyped(name, value: value, allowRebind: true)
        }
    }

    /// Whether execution is currently inside a deferred action's body, here or
    /// in any enclosing scope.
    public nonisolated var isInsideDeferredWork: Bool {
        var current: RuntimeContext = self
        while true {
            if current._isDeferredScope { return true }
            // A call frame answers for itself: `markCallFrameRoot()` copies the
            // caller's answer in at creation time, so the walk never has to
            // cross a call boundary.
            guard !current._isCallFrameRoot,
                  let runtimeParent = current.parent as? RuntimeContext else { return false }
            current = runtimeParent
        }
    }

    /// Record a deferred action result so an unresolved lookup can fall back to
    /// forcing it. Registered on the feature-set context, not the statement scope.
    public nonisolated func registerPendingFuture(_ future: AROFuture) {
        withExclusiveMutation {
            pendingFutures.append(future)
        }
    }

    /// The first failure observed while forcing a deferred result, if any.
    ///
    /// Reads are total — `resolveAny` still hands back `""` so a downstream
    /// action fails on its own terms — but the original error is kept here so
    /// feature-set exit can report the statement that actually broke rather than
    /// the one that noticed. See `takeDeferredFailure()`.
    nonisolated(unsafe) private var _deferredFailure: Error?

    /// `AROFuture.sourceLocation` ("line:column") of the statement that created
    /// the failing future.
    ///
    /// Kept so the debugger's error-any breakpoint can name the statement that
    /// *caused* the failure rather than the one that noticed it. Under ARO-0088
    /// deferral a value-producing action does not throw at its own statement —
    /// the future carries the failure — so `errorCheckpoint` was never reached
    /// for the majority of runtime failures and `berror` silently did nothing
    /// (GitLab #561).
    nonisolated(unsafe) private var _deferredFailureLocation: String?

    nonisolated func recordDeferredFailure(
        _ error: Error,
        binding: String,
        sourceLocation: String? = nil
    ) {
        let owner = statementScopeOwner
        if owner !== self {
            owner.recordDeferredFailure(error, binding: binding, sourceLocation: sourceLocation)
            return
        }
        // Reads are total, so the caller is about to receive an empty value.
        // Say so: a silently-empty binding is exactly the kind of failure that
        // is impossible to trace back to its cause later.
        FileHandle.standardError.write(Data(
            "[ARO] Deferred action for '\(binding)' failed: \(error)\n".utf8))
        withExclusiveMutation {
            if _deferredFailure == nil {
                _deferredFailure = error
                _deferredFailureLocation = sourceLocation
            }
        }
    }

    /// Consume the recorded deferred failure, if one was observed.
    public nonisolated func takeDeferredFailure() -> Error? {
        withExclusiveMutation {
            let error = _deferredFailure
            _deferredFailure = nil
            return error
        }
    }

    /// The `line:column` of the statement that created the failing future, if
    /// one was recorded. Read before `takeDeferredFailure()` consumes it.
    public nonisolated var deferredFailureLine: Int? {
        withExclusiveMutation {
            guard let location = _deferredFailureLocation,
                  let lineText = location.split(separator: ":").first else { return nil }
            return Int(lineText)
        }
    }

    /// An immutable rebind that `bindTyped` refused, waiting for the executor
    /// to throw it as a statement error (GitLab #495).
    ///
    /// Same shape as `_deferredFailure`: `bind` is non-throwing (it is called
    /// from every action, plugin bridge, and framework-variable site), so the
    /// violation is parked here and the executor turns it into a thrown,
    /// statement-attributed `AROError` right after the statement that caused
    /// it. First violation wins — it names the binding that actually broke.
    nonisolated(unsafe) private var _rebindViolation: AROError?

    nonisolated func recordRebindViolation(_ error: AROError) {
        let owner = statementScopeOwner
        if owner !== self {
            owner.recordRebindViolation(error)
            return
        }
        withExclusiveMutation {
            if _rebindViolation == nil { _rebindViolation = error }
        }
    }

    /// Consume the recorded rebind violation, if one was observed.
    public nonisolated func takeRebindViolation() -> AROError? {
        let owner = statementScopeOwner
        if owner !== self {
            return owner.takeRebindViolation()
        }
        return withExclusiveMutation {
            let error = _rebindViolation
            _rebindViolation = nil
            return error
        }
    }

    /// The context that owns feature-set-level state — a statement scope defers
    /// to the context it was created from.
    private nonisolated var statementScopeOwner: RuntimeContext {
        var current: RuntimeContext = self
        while current._isStatementScope, let owner = current.parent as? RuntimeContext {
            current = owner
        }
        return current
    }

    /// Force every deferred result bound in this context.
    ///
    /// Two callers: a lookup that missed (a deferred action may bind names beyond
    /// its declared result), and feature-set exit, where forcing is what stops an
    /// unread failure from being silently discarded. Returns the first error
    /// encountered so the caller can decide whether to surface it.
    @discardableResult
    public nonisolated func drainPendingFutures() -> Error? {
        if _isDraining { return nil }
        let pending: [AROFuture] = withExclusiveMutation {
            _isDraining = true
            let snapshot = pendingFutures
            pendingFutures.removeAll()
            return snapshot
        }
        defer { _isDraining = false }
        var firstError: Error?
        for future in pending {
            do {
                _ = try future.force()
            } catch {
                // Record as well as return. A drain triggered by a lookup miss
                // discards the return value, and it has already emptied the
                // list — so without recording here, the failure would be gone
                // by the time feature-set exit drains again.
                recordDeferredFailure(
                    error, binding: future.bindingName, sourceLocation: future.sourceLocation)
                if firstError == nil { firstError = error }
            }
        }
        return firstError
    }

    /// The value an action bound for `name` while it was running, if it differs
    /// from the handle that is being forced.
    ///
    /// An action's return value and the binding it makes for itself are not
    /// always the same object: `Filter` and `Stream` return a raw `AROStream`
    /// but bind an `AnyStreamingValue` wrapper, and only the wrapper is
    /// something `Compute … length` can consume. The eager path never had to
    /// choose — the executor skipped its own bind when the action had already
    /// bound one. Forcing a handle has the same choice to make, and the same
    /// answer: the action's binding wins.
    ///
    /// Without this, which one a reader saw depended on whether the action had
    /// finished yet. DirectoryReplicatorEvents printed
    /// "Found AROStream<…> directories" on Linux and "Found 3 directories" on
    /// macOS, from identical source.
    private nonisolated func bindingProducedWhileForcing(_ name: String) -> (any Sendable)? {
        guard let current = localVariable(name), !(current.value is AROFuture) else { return nil }
        return current.value
    }

    /// Place a deferred result's handle under `name`, unless the action has
    /// already bound its own result there.
    ///
    /// Check and write happen under one lock hold, and that is the entire point.
    /// `AROFuture` starts its task in `init`, so between "is anything there
    /// yet?" and "put the handle there" the action can finish and bind — and the
    /// handle would then overwrite the real result. `Filter` binds a wrapped
    /// lazy stream and *returns* a raw one, so losing its binding downgraded
    /// `<directories>` to something `Compute … length` cannot consume, and the
    /// program printed "Found AROStream<…> directories". Linux won that window
    /// every time; macOS never did.
    ///
    /// A placeholder never marks the name immutable — the value that lands does.
    public nonisolated func bindDeferredPlaceholder(_ name: String, future: AROFuture) {
        withExclusiveMutation {
            if let existing = variables[name], !(existing.value is AROFuture) { return }
            variables[name] = TypedValue.infer(future)
        }
    }

    /// True when this context holds `name` locally with a real value rather than
    /// a still-pending handle.
    ///
    /// Used to close a race in the deferred path: the future starts running the
    /// moment it is created, so a fast action can bind its own result before the
    /// executor gets to bind the placeholder. Overwriting a materialized value
    /// with a handle is pointless at best; binding over it trapped the
    /// immutability backstop outright.
    public nonisolated func holdsMaterializedValue(_ name: String) -> Bool {
        guard let typed = localVariable(name) else { return false }
        return !(typed.value is AROFuture)
    }

    /// Whether any deferred result is still outstanding here or in a parent.
    public nonisolated var hasPendingFutures: Bool {
        var current: RuntimeContext = self
        while true {
            if !current.pendingFutures.isEmpty { return true }
            guard !current._isCallFrameRoot,
                  let runtimeParent = current.parent as? RuntimeContext else { return false }
            current = runtimeParent
        }
    }

    /// Drain this context and every ancestor. A statement scope registers nothing
    /// itself, so a miss inside one has to reach the feature-set context.
    @discardableResult
    public nonisolated func drainPendingFuturesUpChain() -> Error? {
        var firstError: Error?
        var current: RuntimeContext = self
        while true {
            if let error = current.drainPendingFutures(), firstError == nil {
                firstError = error
            }
            // Stop at a call frame. A callee draining its caller's outstanding
            // work would force statements the caller has not read yet, which is
            // the opposite of what ARO-0088 promises — and it made the walk
            // O(live calls) on top of that. The caller drains its own chain when
            // it exits.
            guard !current._isCallFrameRoot,
                  let runtimeParent = current.parent as? RuntimeContext else { return firstError }
            current = runtimeParent
        }
    }

    // MARK: - Child Context

    public nonisolated func createChild(featureSetName: String) -> ExecutionContext {
        RuntimeContext(
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            outputContext: _outputContext,
            eventBus: eventBus,
            container: container,
            parent: self,
            isCompiled: _isCompiled,
            isTemplateContext: false,
            driverChannel: driverChannel
        )
    }

    /// Create a child context with a different business activity
    public nonisolated func createChild(featureSetName: String, businessActivity: String) -> ExecutionContext {
        RuntimeContext(
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            outputContext: _outputContext,
            eventBus: eventBus,
            container: container,
            parent: self,
            isCompiled: _isCompiled,
            isTemplateContext: false,
            driverChannel: driverChannel
        )
    }

    /// Create a child context for template rendering (ARO-0050).
    ///
    /// The child has its own isolated template buffer and variable storage,
    /// but inherits read-only access to the parent via the existing
    /// `resolve`/`resolveAny`/`service` fall-through chain. Mutations made
    /// during rendering stay local to the child and are discarded when the
    /// render completes, so concurrent renders off the same parent — e.g.
    /// two HTTP handlers rendering templates at the same time — cannot see
    /// each other's intermediate bindings (issue #166).
    public nonisolated func createTemplateContext() -> RuntimeContext {
        return RuntimeContext(
            featureSetName: "template:\(featureSetName)",
            businessActivity: businessActivity,
            outputContext: _outputContext,
            eventBus: eventBus,
            container: container,
            parent: self,
            isCompiled: _isCompiled,
            isTemplateContext: true
        )
    }

    // MARK: - Wait State Management

    public nonisolated func enterWaitState() {
        withExclusiveMutation { _isWaiting = true }
    }

    public nonisolated func waitForShutdown() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            shutdownContinuation = continuation
        }
    }

    public nonisolated var isWaiting: Bool {
        return _isWaiting
    }

    public nonisolated func signalShutdown() {
        let continuation = shutdownContinuation
        shutdownContinuation = nil
        _isWaiting = false
        continuation?.resume(returning: ())
    }

    // MARK: - Output Context

    public nonisolated var outputContext: OutputContext {
        _outputContext
    }

    public nonisolated var isDebugMode: Bool {
        _outputContext == .developer
    }

    public nonisolated var isTestMode: Bool {
        _outputContext == .developer
    }

    public nonisolated var isCompiled: Bool {
        _isCompiled
    }


    // MARK: - Template Buffer (ARO-0050)

    public nonisolated func appendToTemplateBuffer(_ value: String) {
        // The render buffer belongs to the template context, not to the
        // statement that printed into it — the engine flushes the former.
        if _isStatementScope, let owner = parent as? RuntimeContext {
            owner.appendToTemplateBuffer(value)
            return
        }
        withExclusiveMutation {
            // #317: soft cap. Check current size + incoming bytes before
            // committing the append. UTF-8 byte counts are O(1) on Swift
            // String (cached on the storage), so the guard is cheap.
            let incoming = value.utf8.count
            let current = _templateBuffer.utf8.count
            guard current + incoming <= templateBufferMaxBytes else {
                templateBufferOverflowed = true
                if !_templateBufferOverflowWarned {
                    _templateBufferOverflowWarned = true
                    let cap = templateBufferMaxBytes
                    FileHandle.standardError.write(Data(
                        "[ARO runtime] template buffer exceeded \(cap) bytes; subsequent appends dropped until flushTemplateBuffer()\n".utf8
                    ))
                }
                return
            }
            _templateBuffer.append(value)
        }
    }

    public nonisolated func flushTemplateBuffer() -> String {
        if _isStatementScope, let owner = parent as? RuntimeContext {
            return owner.flushTemplateBuffer()
        }
        return withExclusiveMutation {
            let result = _templateBuffer
            _templateBuffer = ""
            templateBufferOverflowed = false
            _templateBufferOverflowWarned = false
            return result
        }
    }

    public nonisolated var isTemplateContext: Bool {
        if _isTemplateContext { return true }
        // A statement inside a template render is still inside that render.
        if _isStatementScope, let owner = parent as? RuntimeContext {
            return owner.isTemplateContext
        }
        return false
    }

    /// How values printed into the template buffer are escaped (GitLab #476).
    ///
    /// Inherited from the parent so a template that `Include`s another keeps the
    /// outer template's escaping unless the inner one sets its own.
    public nonisolated var templateEscaping: TemplateEscaping {
        firstInChain { $0._templateEscaping != .none ? $0._templateEscaping : nil } ?? .none
    }

    /// Sets the escaping mode for this render. Called by the template engine.
    public nonisolated func setTemplateEscaping(_ mode: TemplateEscaping) {
        withExclusiveMutation {
            _templateEscaping = mode
        }
    }

    // MARK: - Schema Registry (ARO-0046)

    /// Get the schema registry for typed event extraction
    /// Falls back to parent context if not set locally
    ///
    /// Iterative for the reason given on `firstInChain`; a parent that is not a
    /// `RuntimeContext` answers for itself, as it did when this recursed.
    public nonisolated var schemaRegistry: SchemaRegistry? {
        var current: RuntimeContext = self
        while true {
            if let registry = current._schemaRegistry { return registry }
            guard let parent = current.parent else { return nil }
            guard let runtimeParent = parent as? RuntimeContext else { return parent.schemaRegistry }
            current = runtimeParent
        }
    }

    /// Set the schema registry (called during application startup)
    /// - Parameter registry: The schema registry to use
    public nonisolated func setSchemaRegistry(_ registry: SchemaRegistry) {
        withExclusiveMutation { _schemaRegistry = registry }
    }

    // MARK: - Streaming Support (ARO-0051)

    /// Bind a lazy stream without materializing it
    ///
    /// The stream will only be consumed when a drain action (Log, Return, etc.)
    /// is executed on the variable.
    ///
    /// - Parameters:
    ///   - name: Variable name
    ///   - stream: The lazy stream to bind
    public nonisolated func bindLazy<T: Sendable>(_ name: String, stream: AROStream<T>) {
        let value = AROValue<T>.lazy(stream)
        bindStreamingValue(name, value: value)
    }

    /// Bind a streaming value (can be eager or lazy)
    public nonisolated func bindStreamingValue<T: Sendable>(_ name: String, value: AROValue<T>) {
        // Wrap in AnyStreamingValue for type-erased storage
        let anyValue = AnyStreamingValue(value)
        bind(name, value: anyValue)
    }

    /// Resolve a variable as a stream
    ///
    /// This preserves laziness - if the variable is a lazy stream, it returns
    /// the stream without materializing. If it's an eager array, it wraps it.
    ///
    /// - Parameter name: Variable name
    /// - Returns: An AROStream, or nil if variable doesn't exist
    public nonisolated func resolveAsStream<T: Sendable>(_ name: String, as type: T.Type = T.self) -> AROStream<T>? {
        guard let value = resolveAny(name) else {
            return nil
        }

        // If already a streaming value, get stream
        if let anyStreaming = value as? AnyStreamingValue {
            // Try to get typed stream
            if let typedStream = anyStreaming.asStream() as? AROStream<T> {
                return typedStream
            }
            // Fall back to mapping
            return anyStreaming.asStream().compactMap { $0 as? T }
        }

        // If it's an AROValue, unwrap
        if let aroValue = value as? AROValue<T> {
            return aroValue.asStream()
        }

        // If it's an array, wrap as stream
        if let array = value as? [T] {
            return AROStream.from(array)
        }

        // If it's an array of dictionaries (common case)
        if let dictArray = value as? [[String: any Sendable]] {
            if T.self == [String: any Sendable].self,
               let typed = dictArray as? [T] {
                return AROStream.from(typed)
            }
        }

        return nil
    }

    /// Resolve a variable as a stream of dictionaries (common case for CSV/JSON)
    public nonisolated func resolveAsRowStream(_ name: String) -> AROStream<[String: any Sendable]>? {
        resolveAsStream(name, as: [String: any Sendable].self)
    }

    /// Check if a variable is a lazy stream (not yet materialized)
    ///
    /// - Parameter name: Variable name
    /// - Returns: true if the variable is a lazy stream
    public nonisolated func isLazy(_ name: String) -> Bool {
        guard let value = resolveAny(name) else {
            return false
        }

        if let anyStreaming = value as? AnyStreamingValue {
            return !anyStreaming.isMaterialized
        }

        return false
    }

    /// Materialize a lazy variable (collect stream into array)
    ///
    /// If the variable is already materialized, this is a no-op.
    /// Otherwise, it consumes the stream and replaces the binding with the array.
    ///
    /// - Parameter name: Variable name
    public nonisolated func materialize(_ name: String) async throws {
        guard let value = resolveAny(name) else {
            return
        }

        if let anyStreaming = value as? AnyStreamingValue, !anyStreaming.isMaterialized {
            let array = try await anyStreaming.materialize()
            // Rebind as eager (using allowRebind since we're replacing the same variable)
            bind(name, value: array, allowRebind: true)
        }
    }
}

// MARK: - Convenience Extensions

extension RuntimeContext {
    /// Bind multiple values at once (auto-infers types)
    /// - Parameter bindings: Dictionary of name-value pairs
    public nonisolated func bindAll(_ bindings: [String: any Sendable]) {
        for (name, value) in bindings {
            bind(name, value: value)
        }
    }

    /// Bind multiple typed values at once
    /// - Parameter bindings: Dictionary of name-TypedValue pairs
    public nonisolated func bindAllTyped(_ bindings: [String: TypedValue]) {
        for (name, value) in bindings {
            bindTyped(name, value: value)
        }
    }

    /// Create a context with initial bindings
    /// - Parameters:
    ///   - featureSetName: Name of the feature set
    ///   - businessActivity: Business activity this feature set belongs to
    ///   - outputContext: Output context for formatting
    ///   - eventBus: Optional event bus
    ///   - initialBindings: Initial variable bindings
    /// - Returns: A new context with the bindings
    public static func with(
        featureSetName: String,
        businessActivity: String = "",
        outputContext: OutputContext = .human,
        eventBus: EventBus? = nil,
        initialBindings: [String: any Sendable]
    ) -> RuntimeContext {
        let context = RuntimeContext(
            featureSetName: featureSetName,
            businessActivity: businessActivity,
            outputContext: outputContext,
            eventBus: eventBus
        )
        context.bindAll(initialBindings)
        return context
    }
}

// MARK: - Single-Driver Exclusivity Enforcement (issue #323)

extension RuntimeContext {
    @inline(__always)
    /// Serialize access to this context's mutable storage.
    ///
    /// This used to be a DEBUG-only *detector* for concurrent mutation, resting
    /// on the invariant that exactly one flow drives a context at a time. Under
    /// ARO-0088 that invariant no longer holds: deferred actions run
    /// concurrently and write their results through to the feature-set context
    /// they belong to, so two of them can bind at the same moment. Two
    /// concurrent `Compute`s corrupting the variables dictionary is how this was
    /// found — the detector could only have reported the race, not prevented it.
    ///
    /// Recursive because binding can re-enter (write-through from a statement
    /// scope takes the owner's lock while holding its own).
    fileprivate nonisolated func withExclusiveMutation<T>(_ body: () throws -> T) rethrows -> T {
        storageLock.lock()
        defer { storageLock.unlock() }
        return try body()
    }

    /// Read a binding from this context's own storage under the lock.
    private nonisolated func localVariable(_ name: String) -> TypedValue? {
        storageLock.lock()
        defer { storageLock.unlock() }
        return variables[name]
    }
}

