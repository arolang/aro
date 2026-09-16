// REPLSession.swift
// ARO REPL Session Management
//
// Manages the state of an interactive REPL session including:
// - Variable persistence across statements
// - Feature set definitions
// - History tracking
// - Session export

import Foundation
import AROParser
import ARORuntime

/// Result of executing a REPL input
public enum REPLResult: Sendable {
    case value(any Sendable)
    case ok
    case featureSetStarted(String)
    case featureSetDefined(String)
    case statementAdded
    case commandOutput(String)
    case table([[String]])
    case exit
    case error(String)

    public var isSuccess: Bool {
        switch self {
        case .error:
            return false
        default:
            return true
        }
    }
}

/// Entry in the session history
public struct HistoryEntry: Sendable {
    public let input: String
    public let timestamp: Date
    public let type: HistoryEntryType
    public var result: REPLResult?
    public var duration: TimeInterval?

    public init(input: String, type: HistoryEntryType) {
        self.input = input
        self.timestamp = Date()
        self.type = type
        self.result = nil
        self.duration = nil
    }
}

public enum HistoryEntryType: Sendable {
    case statement
    case featureSetStart
    case featureSetEnd
    case metaCommand
    case expression
}

/// The current mode of the REPL
public enum REPLMode: Sendable {
    case direct
    case featureSetDefinition(name: String, activity: String, statements: [String])
}

/// Manages an interactive REPL session
public final class REPLSession: @unchecked Sendable {
    public let id = UUID()

    /// The runtime context for this session
    public private(set) var context: RuntimeContext

    /// Event bus for the session
    public let eventBus: EventBus

    /// Global symbol storage
    public let globalSymbols: GlobalSymbolStorage

    /// Defined feature sets (thread-safe access via methods)
    private var _featureSets: [String: AnalyzedFeatureSet] = [:]

    /// Raw feature set sources for export
    private var _featureSetSources: [String: String] = [:]

    /// EventBus subscription per handler feature-set name, so a
    /// redefinition replaces its subscription instead of stacking a
    /// second one — the same rule user-defined actions follow.
    private var handlerSubscriptions: [String: UUID] = [:]

    /// Session history
    private var _history: [HistoryEntry] = []

    /// Current mode
    public var mode: REPLMode = .direct

    /// The compiler instance
    private let compiler = Compiler()

    /// The statement executor
    private let executor: FeatureSetExecutor

    /// The registry statements are executed against. Held so that
    /// `executeStatement(_:companions:)` can register user-defined
    /// actions (ARO-0081) into the same registry the executor uses.
    private let actionRegistry: ActionRegistry

    /// The host for user-defined actions registered from companion
    /// sources. Kept so a redefinition replaces its predecessor
    /// instead of layering a second handler on the same verb.
    private var userActionHost: UserDefinedActionHost?

    /// The flag the session was constructed with. Persisted so that
    /// `clear()` can rebuild the underlying RuntimeContext with the same
    /// formatting behavior.
    private let suppressLogPrefix: Bool

    /// Construct a REPL session. The action registry defaults to
    /// the process-wide singleton; tests can pass an isolated
    /// instance so concurrent sessions don't see each other's
    /// dynamic registrations (#363).
    public init(
        suppressLogPrefix: Bool = false,
        actionRegistry: ActionRegistry = .shared
    ) {
        self.suppressLogPrefix = suppressLogPrefix
        self.actionRegistry = actionRegistry
        self.eventBus = EventBus()
        self.globalSymbols = GlobalSymbolStorage()
        self.context = RuntimeContext(
            featureSetName: "_repl_session_",
            businessActivity: "Interactive",
            outputContext: .human,
            eventBus: eventBus,
            suppressLogPrefix: suppressLogPrefix
        )

        // Register services for REPL session
        let fileService = AROFileSystemService(eventBus: eventBus)
        self.context.register(fileService as FileSystemService)

        // Register terminal service so <terminal> reflects the real TTY
        // (issue #172). Mirrors Application.registerDefaultServices().
        #if !os(Windows)
        if isatty(STDOUT_FILENO) != 0 {
            self.context.register(TerminalService())
        }
        #else
        if ProcessInfo.processInfo.environment["WT_SESSION"] != nil {
            self.context.register(TerminalService())
        }
        #endif

        self.executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )
    }

    // MARK: - Thread-safe accessors

    public var featureSets: [String: AnalyzedFeatureSet] {
        _featureSets
    }

    public var featureSetSources: [String: String] {
        _featureSetSources
    }

    public var history: [HistoryEntry] {
        _history
    }

    public func addFeatureSet(name: String, featureSet: AnalyzedFeatureSet, source: String? = nil) {
        _featureSets[name] = featureSet
        if let source = source {
            _featureSetSources[name] = source
        }
        registerDomainHandlerIfNeeded(name: name, featureSet: featureSet)
    }

    // MARK: - Event dispatch (interactive sessions)

    /// Handler families that hang off a running service. Their events
    /// come from a server the session never starts (the REPL runs no
    /// Keepalive loop), so subscribing them would promise dispatch that
    /// can never arrive. `aro run` remains their home.
    private static let serviceBoundHandlerActivities: [String] = [
        "Socket Event Handler",
        "WebSocket Event Handler",
        "File Event Handler",
        "KeyPress Handler",
    ]

    /// Whether `businessActivity` names a domain event handler this
    /// session will dispatch to (`{EventName} Handler`, optionally with
    /// state guards). Exposed for the front-ends, so they can tell the
    /// user a definition went live rather than merely registered.
    public static func domainHandlerEventType(for businessActivity: String) -> String? {
        guard let range = businessActivity.range(of: " Handler") else { return nil }
        guard !serviceBoundHandlerActivities.contains(where: businessActivity.contains) else {
            return nil
        }
        let eventType = String(businessActivity[..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return eventType.isEmpty ? nil : eventType
    }

    /// Subscribe a `{EventName} Handler` feature set to this session's
    /// EventBus, so an `Emit` in a later input actually dispatches to it
    /// (ARO-0091: event dispatch in interactive sessions).
    ///
    /// Dispatch mirrors `ExecutionEngine.registerDomainEventHandlers`:
    /// filter by the event type named in the business activity, apply
    /// state guards (ARO-0022), bind the payload as `event` /
    /// `event:key`, and run the handler body through the same executor
    /// statements use. Handler errors are reported on stderr — the
    /// emitting statement already succeeded, so they must not fail it
    /// retroactively; ARO-0006 still applies inside the handler's text.
    private func registerDomainHandlerIfNeeded(name: String, featureSet: AnalyzedFeatureSet) {
        guard let eventType = Self.domainHandlerEventType(
            for: featureSet.featureSet.businessActivity) else { return }

        let guardSet = StateGuardSet.parse(from: featureSet.featureSet.businessActivity)

        if let previous = handlerSubscriptions.removeValue(forKey: name) {
            eventBus.unsubscribe(previous)
        }

        handlerSubscriptions[name] = eventBus.subscribe(to: DomainEvent.self) { [weak self] event in
            guard let self, event.domainEventType == eventType else { return }
            if !guardSet.isEmpty, !guardSet.allMatch(payload: event.payload) { return }
            await self.runDomainHandler(featureSet, event: event)
        }
    }

    private func runDomainHandler(_ featureSet: AnalyzedFeatureSet, event: DomainEvent) async {
        // `context` is read at dispatch time, not capture time, so a
        // handler defined before `clear()` runs against the current
        // session state — or is gone entirely, since clear() drops the
        // subscription.
        let child = context.createChild(
            featureSetName: featureSet.featureSet.name,
            businessActivity: featureSet.featureSet.businessActivity
        )
        child.bind("event", value: event.payload)
        for (key, value) in event.payload {
            child.bind("event:\(key)", value: value)
        }
        do {
            _ = try await executor.execute(featureSet, context: child)
        } catch {
            FileHandle.standardError.write(Data(
                "\(formatError(error))\n".utf8))
        }
    }

    /// Wait for every event handler triggered so far — including
    /// cascades, where a handler emits an event of its own — to finish.
    ///
    /// Called after each executed input so a handler's output lands with
    /// the statement that emitted the event, in both the terminal REPL
    /// and a notebook cell (the protocol's stream-before-result ordering
    /// depends on it). Returns false when the bus timed out with work
    /// still pending, which the caller surfaces as a warning rather than
    /// an error: the emitting statement itself succeeded.
    @discardableResult
    public func settleEvents() async -> Bool {
        await eventBus.awaitPendingEvents()
    }

    private func addHistory(_ entry: HistoryEntry) {
        _history.append(entry)
    }

    // MARK: - Statement Execution

    /// Execute a single ARO statement
    public func executeStatement(_ source: String) async throws -> REPLResult {
        try await executeStatement(source, companions: [])
    }

    /// Execute a statement (or block of statements) with `companions`
    /// compiled into the same program.
    ///
    /// A companion is the source of a feature set defined earlier in the
    /// session. Compiling them together is what lets a statement call a
    /// user-defined action (ARO-0081) that an earlier input defined —
    /// semantic analysis resolves `Application.<Name>` against the program
    /// it is given, and a lone wrapped statement is a program of one.
    ///
    /// Companions are appended *after* the wrapper, never prepended, so the
    /// statement keeps the line numbers the caller sees. Diagnostics stay
    /// pointing at the input the user actually typed.
    public func executeStatement(_ source: String, companions: [String]) async throws -> REPLResult {
        let startTime = Date()

        // Record in history
        var entry = HistoryEntry(input: source, type: .statement)

        // Wrap statement in a temporary feature set for compilation
        var wrappedSource = """
        (_repl_temp_: Interactive) {
            \(source)
        }
        """
        if !companions.isEmpty {
            wrappedSource += "\n\n" + companions.joined(separator: "\n\n")
        }

        let result = compiler.compile(wrappedSource)

        if !result.isSuccess {
            let errorMsg = result.diagnostics.map { $0.message }.joined(separator: "\n")
            entry.result = .error(errorMsg)
            entry.duration = Date().timeIntervalSince(startTime)
            addHistory(entry)
            return .error(errorMsg)
        }

        // Register any user-defined actions the companions declare, so the
        // statement can call them. Replaces the previous registration rather
        // than stacking on it — a redefined action must not keep answering
        // with its old body.
        await registerUserActions(from: result.analyzedProgram)

        guard let analyzedFS = result.analyzedProgram.byName["_repl_temp_"]
            ?? result.analyzedProgram.featureSets.first else {
            let errorMsg = "No feature set found in compiled result"
            entry.result = .error(errorMsg)
            entry.duration = Date().timeIntervalSince(startTime)
            addHistory(entry)
            return .error(errorMsg)
        }

        do {
            let response = try await executor.execute(analyzedFS, context: context)

            // Any event this input emitted dispatches to the session's
            // handlers now, before the result is reported — so handler
            // output belongs to the input that caused it.
            if await !settleEvents() {
                FileHandle.standardError.write(Data(
                    "[repl] Warning: event handlers still running after timeout; their output may arrive late.\n".utf8))
            }

            entry.duration = Date().timeIntervalSince(startTime)

            // Check if there's a meaningful return value
            if !response.data.isEmpty {
                // Convert response data to a displayable format
                let data = convertResponseData(response.data)
                entry.result = .value(data)
                addHistory(entry)
                return .value(data)
            } else {
                entry.result = .ok
                addHistory(entry)
                return .ok
            }
        } catch {
            // Statements before the failing one may have emitted; let
            // those handlers finish so their output isn't attributed to
            // the *next* input.
            await settleEvents()
            let errorMsg = formatError(error)
            entry.result = .error(errorMsg)
            entry.duration = Date().timeIntervalSince(startTime)
            addHistory(entry)
            return .error(errorMsg)
        }
    }

    /// Register the user-defined actions (ARO-0081) found in `program`.
    ///
    /// No-op when the program declares none, so the common case — a plain
    /// statement with no companions — costs nothing.
    private func registerUserActions(from program: AnalyzedProgram) async {
        let host = UserDefinedActionHost(
            analyzedProgram: program,
            globalSymbols: globalSymbols,
            actionRegistry: actionRegistry,
            eventBus: eventBus
        )
        guard !host.isEmpty else { return }
        await userActionHost?.unregister()
        await host.register()
        userActionHost = host
    }

    /// Convert AnySendable response data to displayable format
    private func convertResponseData(_ data: [String: AnySendable]) -> any Sendable {
        // Try to extract single value if there's only one key
        if data.count == 1, let first = data.first {
            // Try common types
            if let str: String = first.value.get() { return str }
            if let num: Int = first.value.get() { return num }
            if let num: Double = first.value.get() { return num }
            if let bool: Bool = first.value.get() { return bool }
            if let arr: [String] = first.value.get() { return arr }
            if let dict: [String: String] = first.value.get() { return dict }
        }

        // Return the whole dictionary as a string representation
        var result: [String: String] = [:]
        for (key, value) in data {
            if let str: String = value.get() { result[key] = str }
            else if let num: Int = value.get() { result[key] = String(num) }
            else if let num: Double = value.get() { result[key] = String(num) }
            else if let bool: Bool = value.get() { result[key] = String(bool) }
            else { result[key] = String(describing: value) }
        }
        return result
    }

    /// Execute an expression and return the result.
    ///
    /// The expression runs in a *child* context: it reads the
    /// session's variables through the parent chain, but its own
    /// binding is discarded with the child — so evaluating twice
    /// never rebinds anything (the runtime treats a rebind as a
    /// fatal compiler bug), and `:vars` stays free of expression
    /// residue. The value comes back through the Return's response
    /// data rather than a context lookup, because `_`-prefixed
    /// names are statement-scoped framework variables and plain
    /// names would leak.
    ///
    /// (This used the retired `<Compute>` bracketed-verb spelling
    /// for a while, which no longer parses — every expression
    /// errored.)
    public func evaluateExpression(_ source: String) async throws -> REPLResult {
        let wrapped = """
        (_repl_expr_: Interactive) {
            Compute the <result> from \(source).
            Return an <OK: status> with <result>.
        }
        """
        let compiled = compiler.compile(wrapped)
        guard compiled.isSuccess,
              let featureSet = compiled.analyzedProgram.byName["_repl_expr_"]
                ?? compiled.analyzedProgram.featureSets.first else {
            let message = compiled.diagnostics.map { $0.message }.joined(separator: "\n")
            return .error(message.isEmpty ? "Not a valid expression: \(source)" : message)
        }

        let child = context.createChild(
            featureSetName: "_repl_expr_",
            businessActivity: "Interactive"
        )
        do {
            let response = try await executor.execute(featureSet, context: child)
            if !response.data.isEmpty {
                return .value(convertResponseData(response.data))
            }
            return .ok
        } catch {
            return .error(formatError(error))
        }
    }

    /// Define a feature set from accumulated statements
    public func defineFeatureSet(name: String, activity: String, statements: [String]) async throws -> REPLResult {
        let statementsSource = statements.map { "    \($0)" }.joined(separator: "\n")
        let source = """
        (\(name): \(activity)) {
        \(statementsSource)
        }
        """

        // Compile with the session's other definitions as companions
        // (GitLab #503): an action must be able to call the sibling
        // actions defined before it, in the terminal REPL exactly as in
        // a notebook cell. The definition's own previous source is
        // excluded so a redefinition never resolves against its old body.
        let companions = _featureSetSources
            .filter { $0.key != name }
            .map(\.value)
        var compiledSource = source
        if !companions.isEmpty {
            compiledSource += "\n\n" + companions.joined(separator: "\n\n")
        }
        let result = compiler.compile(compiledSource)

        if !result.isSuccess {
            let errorMsg = result.diagnostics.map { $0.message }.joined(separator: "\n")
            return .error(errorMsg)
        }

        guard let analyzedFS = result.analyzedProgram.byName[name] else {
            return .error("No feature set found in compiled result")
        }

        addFeatureSet(name: name, featureSet: analyzedFS, source: source)

        // Register the user-defined actions this program declares, so a
        // define→invoke flow (no statement in between) can already call
        // `Application.<Name>` (#503).
        await registerUserActions(from: result.analyzedProgram)

        // Record in history
        let entry = HistoryEntry(input: "(\(name): \(activity)) { ... }", type: .featureSetEnd)
        addHistory(entry)

        return .featureSetDefined(name)
    }

    /// Invoke a defined feature set
    public func invokeFeatureSet(named name: String, input: [String: any Sendable]? = nil) async throws -> REPLResult {
        guard let featureSet = _featureSets[name] else {
            return .error("Feature set '\(name)' not found. Use :fs to list defined feature sets.")
        }

        // Create a child context for the invocation
        let childContext = context.createChild(
            featureSetName: name,
            businessActivity: featureSet.featureSet.businessActivity
        )

        // Bind input values if provided.
        //
        // Both shapes. ARO-0081 says a user-defined action reads its arguments
        // off `input` — `Extract the <w> from the <input: width>.` — which is
        // how a feature set written for a file is spelled, so `:invoke` has to
        // offer it or the prompt cannot run the code you just wrote. Binding
        // the keys at top level as well keeps every existing `:invoke` working
        // (GitLab #578).
        if let input {
            childContext.bind("input", value: input)
            for (key, value) in input {
                childContext.bind(key, value: value)
            }
        }

        do {
            let response = try await executor.execute(featureSet, context: childContext)
            await settleEvents()

            if !response.data.isEmpty {
                let data = convertResponseData(response.data)
                return .value(data)
            } else {
                return .ok
            }
        } catch {
            return .error(formatError(error))
        }
    }

    /// Clear session state
    public func clear() {
        _featureSets.removeAll()
        _featureSetSources.removeAll()
        _history.removeAll()

        // Cleared handlers must stop answering events — the definition
        // they came from is gone.
        for (_, subscription) in handlerSubscriptions {
            eventBus.unsubscribe(subscription)
        }
        handlerSubscriptions.removeAll()

        // Drop any user-defined action verbs this session registered.
        // `clear()` is synchronous (the meta-command protocol is), so the
        // unregistration is detached; verbs are replaced wholesale by the
        // next registration anyway, this just stops a cleared session from
        // leaving `Application.<Name>` answering from a discarded body.
        if let host = userActionHost {
            userActionHost = nil
            Task { await host.unregister() }
        }
        // Reset the runtime context to clear all variables
        context = RuntimeContext(
            featureSetName: "_repl_session_",
            businessActivity: "Interactive",
            outputContext: .human,
            eventBus: eventBus,
            suppressLogPrefix: suppressLogPrefix
        )

        // Re-register services after context reset
        let fileService = AROFileSystemService(eventBus: eventBus)
        context.register(fileService as FileSystemService)

        #if !os(Windows)
        if isatty(STDOUT_FILENO) != 0 {
            context.register(TerminalService())
        }
        #else
        if ProcessInfo.processInfo.environment["WT_SESSION"] != nil {
            context.register(TerminalService())
        }
        #endif
    }

    /// Get all variable names
    public var variableNames: [String] {
        context.variableNames.filter { !$0.hasPrefix("_") }.sorted()
    }

    /// Get variable value
    public func getVariable(_ name: String) -> (any Sendable)? {
        context.resolveAny(name)
    }

    /// Release a binding so the name is free again.
    ///
    /// Immutability is a property of a program; a notebook cell run a
    /// second time is not a second statement, it is the same statement
    /// evaluated again (GitLab #544). The engine releases what a cell
    /// bound before re-running it, and nothing else in the session.
    public func unbindVariable(_ name: String) {
        context.unbind(name)
    }

    /// Set a variable
    public func setVariable(_ name: String, value: any Sendable) {
        context.bind(name, value: value, allowRebind: true)
    }

    /// Get feature set names
    public var featureSetNames: [String] {
        Array(_featureSets.keys).sorted()
    }

    /// Format error for display
    private func formatError(_ error: Error) -> String {
        if let aroError = error as? AROError {
            return aroError.message
        }
        if let assertion = error as? AssertionError {
            // The struct dump ('AssertionError(message: …, expected:
            // Optional(99) …)') buried the one line that matters
            // (GitLab #514).
            return assertion.message
        }
        return String(describing: error)
    }
}
