// ============================================================
// FeatureSetExecutor.swift
// ARO Runtime - Feature Set Executor
// ============================================================
//
// ARO-0011: Data-Flow Driven Execution
// ------------------------------------
// The executor supports two modes:
// 1. Sequential (default): Statements execute one after another
// 2. Optimized: I/O operations run in parallel based on data dependencies
//
// The optimized mode maintains sequential semantics from the programmer's
// perspective while overlapping I/O operations under the hood.

import Foundation
import AROParser

/// Executes a single feature set
///
/// The FeatureSetExecutor processes statements within a feature set,
/// managing variable bindings and action execution.
///
/// Statements execute sequentially by source order, but action results
/// are produced lazily under the lazy-handle model (issue #55): each
/// non-effectful action returns an AROFuture that the next consumer
/// transparently forces. This subsumes the older `enableParallelIO`
/// data-flow scheduler — independent I/O calls overlap automatically
/// when their futures are forced by downstream consumers, with no need
/// for a separate DAG-builder.
public final class FeatureSetExecutor: Sendable {
    // MARK: - Properties

    private let actionRegistry: ActionRegistry
    private let eventBus: EventBus
    private let globalSymbols: GlobalSymbolStorage
    private let expressionEvaluator: ExpressionEvaluator

    // Cached VerbSets — copied once at init to avoid repeated static-property indirection
    private let testVerbs: Set<String>
    private let requestVerbs: Set<String>
    private let updateVerbs: Set<String>
    private let createVerbs: Set<String>
    private let mergeVerbs: Set<String>
    private let computeVerbs: Set<String>
    private let extractVerbs: Set<String>
    private let queryVerbs: Set<String>
    private let deleteVerbs: Set<String>
    private let responseVerbs: Set<String>
    private let serverVerbs: Set<String>

    // MARK: - Initialization

    public init(
        actionRegistry: ActionRegistry,
        eventBus: EventBus,
        globalSymbols: GlobalSymbolStorage
    ) {
        self.actionRegistry = actionRegistry
        self.eventBus = eventBus
        self.globalSymbols = globalSymbols
        self.expressionEvaluator = ExpressionEvaluator()
        self.testVerbs = VerbSets.testVerbs
        self.requestVerbs = VerbSets.requestVerbs
        self.updateVerbs = VerbSets.updateVerbs
        self.createVerbs = VerbSets.createVerbs
        self.mergeVerbs = VerbSets.mergeVerbs
        self.computeVerbs = VerbSets.computeVerbs
        self.extractVerbs = VerbSets.extractVerbs
        self.queryVerbs = VerbSets.queryVerbs
        self.deleteVerbs = VerbSets.deleteVerbs
        self.responseVerbs = VerbSets.responseVerbs
        self.serverVerbs = VerbSets.serverVerbs
    }

    // MARK: - Execution

    /// Execute an analyzed feature set
    /// - Parameters:
    ///   - analyzedFeatureSet: The feature set to execute
    ///   - context: The execution context
    /// - Returns: The response from the feature set
    public func execute(
        _ analyzedFeatureSet: AnalyzedFeatureSet,
        context: ExecutionContext
    ) async throws -> Response {
        // The application concurrency ceiling (ARO-0088 §10a, GitLab #862).
        // One choke point, so every triggered feature set is counted — an HTTP
        // request, an event handler, a file change — and not just the loop that
        // `with <concurrency: N>` happens to bound. A no-op unless a ceiling is
        // configured, and a no-op for a feature set already running inside one.
        try await ApplicationLimits.withSlot {
            try await self.executeGated(analyzedFeatureSet, context: context)
        }
    }

    private func executeGated(
        _ analyzedFeatureSet: AnalyzedFeatureSet,
        context: ExecutionContext
    ) async throws -> Response {
        let featureSet = analyzedFeatureSet.featureSet
        let startTime = Date()

        // Determine whether this is an application-lifecycle feature set.
        // Symbols published by Application-Start and Application-End must persist
        // for the entire process lifetime and are therefore excluded from eviction.
        let isLifecycleFeatureSet = featureSet.name == "Application-Start"
            || featureSet.name.hasPrefix("Application-End")

        // Emit start event
        eventBus.publish(FeatureSetStartedEvent(
            featureSetName: featureSet.name,
            businessActivity: featureSet.businessActivity,
            executionId: context.executionId
        ))

        // Bind external dependencies from global symbols in a
        // single actor hop instead of three per dependency
        // (`isAccessDenied`, `businessActivity`, `resolveAny`).
        // For a feature set with N published-symbol dependencies
        // this saves 2N actor turns of overhead (#332).
        let resolutions = await globalSymbols.resolveDependencies(
            analyzedFeatureSet.dependencies,
            forBusinessActivity: context.businessActivity
        )
        for resolution in resolutions {
            switch resolution {
            case .resolved(let name, let value):
                context.bind(name, value: value)
            case .denied(let name, let sourceActivity):
                throw ActionError.scopeViolation(
                    variable: name,
                    sourceActivity: sourceActivity,
                    accessedFrom: context.businessActivity
                )
            case .notFound:
                continue
            }
        }

        // Also eagerly bind all other published variables for this business activity
        // This handles cases where semantic analyzer misses dependencies in map literals
        for (name, entry) in await globalSymbols.allSymbols() {
            // Skip if already bound
            if context.resolveAny(name) != nil {
                continue
            }
            // Only bind if business activity matches
            if !entry.businessActivity.isEmpty && !context.businessActivity.isEmpty &&
               entry.businessActivity == context.businessActivity {
                context.bind(name, value: entry.value)
            }
        }

        // Bind terminal capabilities dict so ARO code can use <terminal: columns> etc.
        if let terminalService = context.service(TerminalService.self) {
            let caps = await terminalService.detectCapabilities()
            let terminalDict: [String: any Sendable] = [
                "rows": caps.rows, "columns": caps.columns,
                "width": caps.columns, "height": caps.rows,
                "supports_color": caps.supportsColor,
                "supports_true_color": caps.supportsTrueColor,
                "is_tty": caps.isTTY, "encoding": caps.encoding
            ]
            context.bind("terminal", value: terminalDict, allowRebind: true)
        } else {
            let terminalDict: [String: any Sendable] = [
                "rows": 24, "columns": 80, "width": 80, "height": 24,
                "supports_color": false, "supports_true_color": false,
                "is_tty": false, "encoding": "UTF-8"
            ]
            context.bind("terminal", value: terminalDict, allowRebind: true)
        }

        // Execute statements sequentially by source order. Independent I/O
        // overlaps automatically: non-effectful actions return AROFutures
        // that the next consumer forces, so the runtime parallelises at
        // the action level without a separate scheduler.
        do {
            // A frame with a tail-call slot is a user-defined action being run
            // by `UserDefinedActionHost`'s trampoline. When the statement in
            // tail position dispatches, it parks the next call instead of
            // nesting one, and this loop stops so the host can reuse the frame
            // (ARO-0081, GitLab #473).
            let frame = context as? RuntimeContext
            let tailCallIndex = frame?.enclosingTailCallSlot == nil
                ? nil
                : TailCallAnalysis.tailCallStatementIndex(of: featureSet)

            for (index, statement) in featureSet.statements.enumerated() {
                if index == tailCallIndex {
                    frame?.setExecutingTailCallStatement(true)
                }
                defer { frame?.setExecutingTailCallStatement(false) }

                try await executeStatement(statement, context: context)

                // A parked tail call replaces both the rest of this frame and
                // the frame itself — there is nothing left to run here.
                if frame?.enclosingTailCallSlot?.isParked == true {
                    break
                }

                // Check if we have a response (Return was called)
                if context.getResponse() != nil {
                    break
                }
            }

            // Feature-set exit is a force point (ARO-0088 §3). Without it a
            // deferred action nobody read would be cancelled when its handle is
            // released, so a failing statement could leave no trace at all.
            try await drainDeferredResults(context: context)

            // Check for response (either from sequential or scheduled execution)
            if let response = context.getResponse() {
                let duration = Date().timeIntervalSince(startTime) * 1000

                eventBus.publish(FeatureSetCompletedEvent(
                    featureSetName: featureSet.name,
                    businessActivity: featureSet.businessActivity,
                    executionId: context.executionId,
                    success: true,
                    durationMs: duration
                ))

                if !isLifecycleFeatureSet {
                    await globalSymbols.evict(executionId: context.executionId)
                }

                return response
            }

            // No explicit return - create default response
            let duration = Date().timeIntervalSince(startTime) * 1000

            eventBus.publish(FeatureSetCompletedEvent(
                featureSetName: featureSet.name,
                businessActivity: featureSet.businessActivity,
                executionId: context.executionId,
                success: true,
                durationMs: duration
            ))

            if !isLifecycleFeatureSet {
                await globalSymbols.evict(executionId: context.executionId)
            }

            return Response.ok()

        } catch {
            let duration = Date().timeIntervalSince(startTime) * 1000

            eventBus.publish(FeatureSetCompletedEvent(
                featureSetName: featureSet.name,
                businessActivity: featureSet.businessActivity,
                executionId: context.executionId,
                success: false,
                durationMs: duration
            ))

            if !isLifecycleFeatureSet {
                await globalSymbols.evict(executionId: context.executionId)
            }

            throw error
        }
    }

    // MARK: - Trace Replay (#447 — time-travel branch & edit)

    /// One recorded step of a replay: the statement's source line + verb and
    /// the symbol snapshot captured just before it ran.
    public struct ReplayStep: Sendable {
        public let index: Int          // statement index within the feature set
        public let line: Int
        public let verb: String
        public let symbols: [SymbolSnapshot]
        public init(index: Int, line: Int, verb: String, symbols: [SymbolSnapshot]) {
            self.index = index; self.line = line; self.verb = verb; self.symbols = symbols
        }
    }

    public struct ReplayResult: Sendable {
        public let steps: [ReplayStep]
        public let responseSummary: String?
        public let error: String?
    }

    /// Re-run a feature set's statements from `startIndex` onward against a
    /// pre-seeded context, capturing a per-statement symbol snapshot. Powers
    /// SOLARO's time-travel "branch & edit" (#447): seed the context with a
    /// recorded tick's state (one value mutated), replay downstream, and diff
    /// the forked trace against the original.
    ///
    /// Unlike `execute`, this skips dependency/global binding — the caller owns
    /// the seeded state — emits no lifecycle events, and evicts nothing. It is
    /// deliberately side-effect-bearing at the action level (a replayed Store
    /// still writes to its repository), so callers that want an isolated sandbox
    /// should pass a context backed by throwaway storage.
    public func replayTrace(
        _ analyzedFeatureSet: AnalyzedFeatureSet,
        seededContext context: ExecutionContext,
        from startIndex: Int
    ) async -> ReplayResult {
        let statements = analyzedFeatureSet.featureSet.statements
        let start = max(0, min(startIndex, statements.count))
        var steps: [ReplayStep] = []
        func snapshotStep(index: Int, line: Int, verb: String) async {
            let symbols = await Self.snapshotSymbols(from: context)
            steps.append(ReplayStep(index: index, line: line, verb: verb, symbols: symbols))
        }
        do {
            for i in start..<statements.count {
                let stmt = statements[i]
                let verb = (stmt as? AROStatement)?.action.verb ?? String(describing: type(of: stmt))
                await snapshotStep(index: i, line: stmt.span.start.line, verb: verb)
                try await executeStatement(stmt, context: context)
                if context.getResponse() != nil { break }
            }
            // Post-state snapshot after the last executed statement.
            await snapshotStep(index: statements.count, line: -1, verb: "(end)")
            let resp = context.getResponse()
            let summary = resp.map { "\($0.status): \($0.reason)" }
            return ReplayResult(steps: steps, responseSummary: summary, error: nil)
        } catch {
            await snapshotStep(index: statements.count, line: -1, verb: "(error)")
            return ReplayResult(steps: steps, responseSummary: nil, error: String(describing: error))
        }
    }

    // MARK: - Statement Execution

    private func executeStatement(
        _ statement: Statement,
        context: ExecutionContext
    ) async throws {
        // Issue #229 Phase 1: statement-boundary debug hook.
        // Cheap fast-path: TaskLocal pointer load + nil check when no
        // debugger is attached.
        if let controller = Debug.controller {
            let symbols = await Self.snapshotSymbols(from: context)
            try await controller.checkpoint(
                statement: statement,
                featureSetName: context.featureSetName,
                businessActivity: context.businessActivity,
                sourceFile: Debug.sourceFile(forFeatureSet: context.featureSetName),
                symbols: symbols,
                context: context
            )
        }

        do {
            if let aroStatement = statement as? AROStatement {
                try await executeAROStatement(aroStatement, context: context)
            } else if let publishStatement = statement as? PublishStatement {
                try await executePublishStatement(publishStatement, context: context)
            } else if let matchStatement = statement as? MatchStatement {
                try await executeMatchStatement(matchStatement, context: context)
            } else if let whenStatement = statement as? WhenStatement {
                try await executeWhenStatement(whenStatement, context: context)
            } else if let requireStatement = statement as? RequireStatement {
                try await executeRequireStatement(requireStatement, context: context)
            } else if let forEachLoop = statement as? ForEachLoop {
                try await executeForEachLoop(forEachLoop, context: context)
            } else if let whileLoop = statement as? WhileLoop {
                try await executeWhileLoop(whileLoop, context: context)
            } else if statement is BreakStatement {
                throw BreakSignal()
            } else if let rangeLoop = statement as? RangeLoop {
                try await executeRangeLoop(rangeLoop, context: context)
            } else if let pipelineStatement = statement as? PipelineStatement {
                try await executePipelineStatement(pipelineStatement, context: context)
            }

            // GitLab #495: `executeAROStatement` attributes a refused rebind
            // to its own statement; this catches the ones the statement forms
            // above don't check themselves (Publish, loop result bindings).
            try throwRefusedRebind(context: context)
        } catch {
            // Issue #229 / SOLARO error border (#?). The runtime
            // declares `errorCheckpoint` on `DebugController` so a
            // frontend can paint the failing statement red, but no
            // call site ever fired it — SOLARO's `.errorAny`
            // breakpoint was effectively dead. Fire it here so the
            // frontend learns about the failure with the most-recent
            // statement's source position still on its lookback. The
            // hook is gated on the breakpoint being installed, so
            // headless `aro run` pays only the TaskLocal load.
            //
            // BreakSignal isn't a real error — it's the control-flow
            // signal for `break inner` etc. — so we skip it.
            if !(error is BreakSignal),
               let controller = Debug.controller {
                // Pass the failing statement's line directly — the
                // frontend's lookback only sees lines from
                // checkpoints that actually called `didPause`, and a
                // .continue / sampled run skips most of them.
                let span = statement.span
                let resolvedSourceFile = Debug.sourceFile(forFeatureSet: context.featureSetName)
                let basename = resolvedSourceFile.isEmpty
                    ? "" : URL(fileURLWithPath: resolvedSourceFile).lastPathComponent
                await controller.errorCheckpoint(
                    message: "\(error)",
                    featureSetName: context.featureSetName,
                    businessActivity: context.businessActivity,
                    line: span.start.line,
                    file: basename
                )
            }
            throw error
        }
    }

    /// Fire `.errorAny` for a failure, if a debugger is attached.
    ///
    /// Shared by the statement catch and the deferred-failure drain so both
    /// kinds of failure reach the same breakpoint (GitLab #561). `BreakSignal`
    /// is control flow for `break inner`, not an error, and never fires.
    private func fireErrorCheckpoint(
        error: Error,
        context: ExecutionContext,
        line: Int?
    ) async {
        guard !(error is BreakSignal), let controller = Debug.controller else { return }
        let resolved = Debug.currentSourceFile
        let basename = resolved.isEmpty
            ? "" : URL(fileURLWithPath: resolved).lastPathComponent
        await controller.errorCheckpoint(
            message: "\(error)",
            featureSetName: context.featureSetName,
            businessActivity: context.businessActivity,
            line: line ?? 0,
            file: basename
        )
    }

    /// Build a `SymbolSnapshot` array from the visible bindings on a
    /// context. Values are previewed with truncation so the TUI / DAP
    /// frontend can print them safely. Internal underscore-prefixed
    /// bookkeeping bindings are filtered out — they are noise to a
    /// debugger user.
    private static func snapshotSymbols(from context: ExecutionContext) async -> [SymbolSnapshot] {
        var out: [SymbolSnapshot] = []
        var emittedRepoNames = Set<String>()
        let names = context.variableNames.filter { !$0.hasPrefix("_") }
        for name in names.sorted() {
            let typed = context.resolveTyped(name)
            let typeName = typed.map { "\($0.type)" } ?? "?"
            let preview: String
            if let raw = context.resolveAny(name) {
                preview = Self.previewValue(raw, maxLength: 80)
            } else {
                preview = "nil"
            }
            let records: [[String: String]]? = await Self.snapshotRecords(
                forSymbol: name, context: context
            )
            if records != nil { emittedRepoNames.insert(name) }
            out.append(SymbolSnapshot(
                name: name,
                typeName: typeName,
                valuePreview: preview,
                records: records
            ))
        }
        // Repositories are global state, not symbol-table entries —
        // a feature set that only writes to (or never references)
        // a repo won't have it in `context.variableNames`. To keep
        // SOLARO's repository cards live regardless of which feature
        // set fired the checkpoint, walk every known repo and emit
        // a synthetic snapshot for any we haven't already covered
        // via the symbol-table path above (#284 step 3).
        // Prefer the context-scoped storage override when one is
        // registered (mirrors how Store/Retrieve actions resolve it
        // — without that fallback, a test that swaps in a custom
        // storage would see the canvas reading from the wrong one).
        let storage = context.service(RepositoryStorageService.self)
            ?? context.container.repositoryStorage
        let knownRepos = await storage.knownRepositoryNames()
        for repoName in knownRepos where !emittedRepoNames.contains(repoName) {
            let rows = await storage.retrieve(
                from: repoName,
                businessActivity: context.businessActivity
            )
            let projected = rows.map { Self.flattenRow($0) }
            out.append(SymbolSnapshot(
                name: repoName,
                typeName: "Repository",
                valuePreview: "\(projected.count) row\(projected.count == 1 ? "" : "s")",
                records: projected
            ))
        }
        return out
    }

    private static func previewValue(_ value: any Sendable, maxLength: Int) -> String {
        let s = String(describing: value)
        if s.count <= maxLength { return s }
        let idx = s.index(s.startIndex, offsetBy: maxLength)
        return String(s[..<idx]) + "…"
    }

    /// Snapshot the current contents of a repository for symbols
    /// whose name ends in `-repository` / `-repo` / `-store`. Rows
    /// are flattened to `[String: String]` so the wire format stays
    /// flat-strings (see `DebugEventLog.swift` and SOLARO's repo
    /// card, which renders the result as a table). Returns nil for
    /// non-repository symbols so the snapshot stays compact.
    private static func snapshotRecords(
        forSymbol name: String,
        context: ExecutionContext
    ) async -> [[String: String]]? {
        let lower = name.lowercased()
        guard lower.hasSuffix("-repository")
            || lower.hasSuffix("-repo")
            || lower.hasSuffix("-store")
        else { return nil }
        let storage = context.container.repositoryStorage
        let rows = await storage.retrieve(
            from: name,
            businessActivity: context.businessActivity
        )
        return rows.map { Self.flattenRow($0) }
    }

    /// Project a single repository row to flat string values. Top-level
    /// dictionaries keep their keys; other shapes collapse into a
    /// single `value` column so the table view always has something to
    /// render.
    private static func flattenRow(_ row: any Sendable) -> [String: String] {
        if let dict = row as? [String: any Sendable] {
            var out: [String: String] = [:]
            for (k, v) in dict {
                out[k] = Self.previewValue(v, maxLength: 120)
            }
            return out
        }
        return ["value": Self.previewValue(row, maxLength: 120)]
    }

    /// ARO-0067: Execute pipeline statement
    /// Each stage receives the result from the previous stage
    private func executePipelineStatement(
        _ pipeline: PipelineStatement,
        context: ExecutionContext
    ) async throws {
        guard !pipeline.stages.isEmpty else { return }

        // Execute all stages sequentially
        // Each stage's result becomes available as the next stage's object
        for stage in pipeline.stages {
            try await executeAROStatement(stage, context: context)
        }

        // No special binding needed - each stage explicitly names its object
        // which should match the previous stage's result variable name
    }

    private func executeAROStatement(
        _ statement: AROStatement,
        context outerContext: ExecutionContext
    ) async throws {
        // Every statement gets its own scope for the `_`-prefixed framework
        // variables below (ARO-0088 §2). A deferred action runs after later
        // statements have rebound them, so reading them from a shared context
        // would hand it the wrong `_with_`, `_where_value_`, or `_literal_`.
        // Non-framework binds — including the action's own result — write
        // through to `outerContext`, so consumers are unaffected.
        let context: ExecutionContext
        if let runtime = outerContext as? RuntimeContext {
            context = runtime.createStatementScope()
        } else {
            context = outerContext
        }

        // Clear transient bindings from previous statements. These are
        // statement-local and must not persist between statements — a `with`
        // clause nobody cleared is a modifier the next statement inherits.
        //
        // The names come from `FrameworkVariables.transientKeys` rather than a
        // list written out here, because the compiled path
        // (`LLVMCodeGenerator.generateAROStatement`) has to sweep exactly the
        // same set and a second hand-maintained copy drifted for seven of them
        // (GitLab #552).
        for key in FrameworkVariables.transientKeys {
            context.unbind(key)
        }
        // `unbind` only removes a binding from this scope, so it cannot hide an
        // inherited one. `_expression_name_` is the one name a parent scope may
        // legitimately still hold (EmitAction reads it to key its payload), so
        // it is additionally shadowed with an empty value.
        context.bind("_expression_name_", value: "")

        // ARO-0004: Evaluate when condition before processing statement
        // If condition is present and evaluates to false, skip this statement entirely
        if let whenCondition = statement.statementGuard.condition {
            let conditionResult = try await expressionEvaluator.evaluate(whenCondition, context: context)
            guard asBool(conditionResult) else {
                return  // Condition is false - skip this statement
            }
        }

        let verb = statement.action.verb
        let resultDescriptor = ResultDescriptor(from: statement.result)
        let objectDescriptor = ObjectDescriptor(from: statement.object)

        // ARO-0002: Evaluate expression if present
        if case .expression(let expression) = statement.valueSource {
            // GitLab #475: an `as Float` / `as Double` result annotation puts the
            // expression in floating-point mode, so `<x> / 2 as Float` is 3.5
            // instead of truncating to 3. Coercing after the fact cannot work —
            // by then the integer division has already happened.
            let evaluator = ResultTypeCoercion.evaluator(
                for: statement.result.asType,
                default: expressionEvaluator
            )
            let expressionValue = try await evaluator.evaluate(expression, context: context)
            context.bind("_expression_", value: expressionValue)

            // ARO-0042: If preposition is "with" and object is expression, also bind to _with_
            // This handles: <Start> the <http-server> with {}.
            if statement.object.preposition == .with && statement.object.noun.base == "_expression_" {
                context.bind("_with_", value: expressionValue)
            }

            // Store the original expression name if it's a simple variable reference
            // This allows EmitAction to use the variable name as payload key
            if let varRef = expression as? VariableRefExpression {
                context.bind("_expression_name_", value: varRef.noun.base)
            }

            // For expressions, directly bind the result to the expression value
            // This handles cases like: <Set> the <x> to 30 * 2.
            // or: <Compute> the <total> from <price> * <quantity>.
            // NOTE: We only do early return for simple assignment actions, NOT for
            // comparison/assertion actions like Then/Assert that need to run.
            if statement.object.noun.base == "_expression_" {
                // Check if the action needs to be executed (see VerbSets.swift for rationale per category)
                // Check if there's a dynamic handler registered for this verb (plugin-provided action)
                let hasDynamicHandler = actionRegistry.dynamicHandler(for: verb) != nil
                // #316: lowercase the verb once instead of 11 times.
                // `String.lowercased()` allocates a fresh String each
                // call; this loop runs per statement at execution rate.
                let lowerVerb = verb.lowercased()
                let needsExecution = testVerbs.contains(lowerVerb) ||
                    requestVerbs.contains(lowerVerb) ||
                    mergeVerbs.contains(lowerVerb) ||
                    responseVerbs.contains(lowerVerb) ||
                    queryVerbs.contains(lowerVerb) ||
                    deleteVerbs.contains(lowerVerb) ||  // GitLab #493: file deletion takes its path as an expression
                    serverVerbs.contains(lowerVerb) ||
                    hasDynamicHandler ||  // Dynamic plugin actions always need execution
                    updateVerbs.contains(lowerVerb) ||  // Update always needs execution (handles rebind internally)
                    (createVerbs.contains(lowerVerb) && !resultDescriptor.specifiers.isEmpty) ||
                    (computeVerbs.contains(lowerVerb) && !resultDescriptor.specifiers.isEmpty) ||
                    (extractVerbs.contains(lowerVerb) && !resultDescriptor.specifiers.isEmpty)
                if !needsExecution {
                    // The fast path bypasses the action — and used to bypass
                    // the `as <Type>` annotation with it, so
                    // `Compute the <n> as Float from <s>.` bound the raw
                    // string and `<n> * 2` did string repetition
                    // (GitLab #501). Coerce exactly like the action path
                    // would (ResultTypeCoercion, GitLab #475).
                    context.bind(
                        resultDescriptor.base,
                        value: ResultTypeCoercion.coerce(
                            expressionValue, to: resultDescriptor.asType))
                    // GitLab #495: the bind above is refused (not fatal) when
                    // the name is already immutable — e.g. a REPL cell
                    // rebinding an earlier cell's variable, which the
                    // per-program analyzer cannot see. Surface it here as this
                    // statement's error.
                    try throwRefusedRebind(
                        context: context,
                        statementText: Self.statementText(statement, verb: verb)
                    )

                    // Still need to run the action for side effects (like Return, Log, etc.).
                    // Goes through the registry so middleware sees it too (#107).
                    //
                    // Asks the predicate directly rather than
                    // `semanticRole == .response`. The role is a taxonomy for
                    // *data flow*; "must run for its effect" is a different
                    // question, and using the role as a proxy is why correcting
                    // `emit` to EXPORT — which is what the registry has always
                    // said — would otherwise have stopped an Emit running here
                    // (GitLab #585). Same verb set as before, named for what it
                    // means.
                    if ActionRoleCatalog.mustRunForEffect(verb),
                       actionRegistry.isRegistered(verb) {
                        _ = try await actionRegistry.execute(
                            verb: verb,
                            result: resultDescriptor,
                            object: objectDescriptor,
                            context: context
                        )
                    }
                    return
                }
                // For test verbs (then, assert), fall through to normal execution
                // The _expression_ binding is already set for ThenAction/AssertAction to use
            }
        }

        // Bind everything else the statement carries — literal, where, by,
        // matching, to, with, against, default, sink expression — into this
        // statement's scope (StatementModifiers.swift).
        try await StatementModifiers.bind(statement, into: context, evaluator: expressionEvaluator)

        // An unread request body reaching a verb that needs a value (GitLab
        // #477). Extract, Write, Send and Return take the stream as it is;
        // anything else has to look inside, so the body is read here — bounded
        // by the route's limit, and reported against the statement that asked.
        // The materialization analysis normally prevents a streamed route from
        // ever reaching this, so it is the safety net rather than the path.
        try await materializeRequestBodyIfNeeded(
            statement: statement,
            verb: verb,
            objectDescriptor: objectDescriptor,
            context: context
        )

        // Deferred execution (ARO-0088 §2): the action starts here, but the wait
        // for its result moves to the first read of the binding. Statements that
        // follow run while it is in flight; a read forces it.
        let canonicalVerb = ActionRunner.canonicalizeVerb(verb)
        if LazyActionPolicy.deferrable(canonicalVerb),
           // `deferrableVerbs` is already an allowlist, so this is
           // belt-and-braces — but it is the effect question, not the role
           // one, so it asks the predicate (GitLab #585).
           !ActionRoleCatalog.mustRunForEffect(canonicalVerb),
           !testVerbs.contains(canonicalVerb),
           let owner = outerContext as? RuntimeContext,
           let scope = context as? RuntimeContext {
            scope.markDeferredScope()
            let future = deferredResult(
                statement: statement,
                verb: verb,
                resultDescriptor: resultDescriptor,
                objectDescriptor: objectDescriptor,
                statementScope: context
            )
            owner.registerPendingFuture(future)

            // Atomic: the future is already running, so the action can finish
            // and bind its own result between any separate check and bind.
            owner.bindDeferredPlaceholder(resultDescriptor.base, future: future)
            return
        }

        // Execute action with ARO-0008 error wrapping
        do {
            // Dispatch through the registry rather than resolving built-in and
            // dynamic handlers here. The registry performs the identical lookup
            // (`action(for:)` then `dynamicHandler(for:)`, else `unknownAction`)
            // and is the single place middleware wraps (#107) — resolving locally
            // meant `aro run` bypassed every registered hook.
            let result = try await actionRegistry.execute(
                verb: verb,
                result: resultDescriptor,
                object: objectDescriptor,
                context: context
            )

            // A Configure statement marks its category, so a later read of
            // an UNSET setting answers nil instead of the happy-path error —
            // configuration is optional by definition (ARO-0035 §3.2,
            // GitLab #506). The mark lives here rather than in the action
            // because it has to outlive the statement scope the action runs
            // in; which verbs mean "configure" is the action's own business.
            if ConfigureAction.handles(verb) {
                (outerContext as? RuntimeContext)?.markConfigured(resultDescriptor.base)
            }

            // Bind result to context (unless the action is an effect that
            // already set the response) and skip binding if the action already
            // bound the result, to avoid double-binding.
            //
            // The predicate, not the role — see the note at the side-effect
            // re-run above (GitLab #585).
            if !ActionRoleCatalog.mustRunForEffect(verb) {
                // Check if this is a rebinding action (accept, update, delete, merge, etc.)
                // Also include REQUEST actions (retrieve, fetch, etc.) since they always get fresh data
                // and should override parent context values (fixes event handler variable shadowing)
                let allowRebind = allowsRebinding(verb)

                // Only bind if variable doesn't exist LOCALLY or if this is a rebinding/request action.
                // We check existsLocally (not exists) so event handlers can create local shadow
                // bindings even when a parent context has already bound the same variable name.
                // Without this, e.g. Transform/Compute in a handler would silently skip the bind
                // if Application-Start already bound the same variable in the root context.
                // Against the owning feature-set context, not the statement
                // scope: the scope holds only framework variables, so asking it
                // whether a result already exists always answers "no" and every
                // rebind would trip the immutability check.
                let existsLocally = (outerContext as? RuntimeContext)?.existsLocally(resultDescriptor.base)
                    ?? outerContext.exists(resultDescriptor.base)
                if allowRebind || !existsLocally {
                    context.bind(resultDescriptor.base, value: result, allowRebind: allowRebind)
                }
            }
        } catch let assertionError as AssertionError {
            // Re-throw assertion errors directly for test framework
            throw assertionError
        } catch let templateError as TemplateError {
            // Re-throw template errors directly for proper HTTP status codes (404 for not found)
            throw templateError
        } catch let aroError as AROError {
            // Already an AROError, re-throw
            throw ActionError.statementFailed(aroError)
        } catch ActionError.callDepthExceeded(let message) {
            // Runaway recursion: every frame on the way out is a call site of
            // the same recursion, so wrapping it here would report the last
            // statement that noticed instead of what happened (GitLab #473).
            throw ActionError.callDepthExceeded(message)
        } catch {
            // Wrap other errors with statement context (ARO-0008: Code Is The Error Message)
            let aroError = AROError.fromStatement(
                verb: verb,
                result: resultDescriptor.fullName,
                preposition: statement.object.preposition.rawValue,
                object: objectDescriptor.fullName,
                condition: statement.statementGuard.isPresent ? "when <condition>" : nil,
                featureSet: context.featureSetName,
                businessActivity: context.businessActivity,
                resolvedValues: gatherResolvedValues(for: statement, context: context),
                hint: Self.statementHint(for: error)
            )
            throw ActionError.statementFailed(aroError)
        }

        // GitLab #495: covers both the executor's own result bind above and
        // any bind the action performed internally (plugins included) that
        // `RuntimeContext.bindTyped` refused as an immutable rebind.
        try throwRefusedRebind(
            context: context,
            statementText: Self.statementText(statement, verb: verb)
        )
    }

    /// The statement in the form `AROError.fromStatement` renders it, for
    /// attributing an error that was detected outside the action's own throw
    /// path (GitLab #495).
    private static func statementText(_ statement: AROStatement, verb: String) -> String {
        let result = ResultDescriptor(from: statement.result).fullName
        let object = ObjectDescriptor(from: statement.object).fullName
        let condition = statement.statementGuard.isPresent ? " when <condition>" : ""
        return "<\(verb)> the <\(result)> \(statement.object.preposition.rawValue) the <\(object)>\(condition)."
    }

    /// Extra sentence appended to a statement-shaped error when the
    /// statement alone can't convey what went wrong (GitLab #486).
    private static func statementHint(for error: any Error) -> String? {
        // A file-system failure is the second exception (GitLab #493): the
        // statement `Delete the <gone> from "./f.txt"` reads fine, but only
        // the underlying error says *why* it failed — the path is missing,
        // not merely undeletable. Same for read/copy/move on missing paths.
        if let fsError = error as? FileSystemError {
            return fsError.description
        }
        guard let actionError = error as? ActionError,
              case .unknownComputation = actionError
        else { return nil }
        return actionError.description
    }

    /// Force everything still outstanding and rethrow the first failure.
    ///
    /// Also surfaces a failure that a read already swallowed: `resolveAny` keeps
    /// reads total by handing back `""` when a deferred action failed, and this
    /// is where that gets reported instead of disappearing.
    private func drainDeferredResults(context: ExecutionContext) async throws {
        guard let runtime = context as? RuntimeContext else { return }
        let drainError = runtime.drainPendingFutures()
        if let observed = runtime.takeDeferredFailure() {
            // Fire the error-any checkpoint here too. Under ARO-0088 deferral a
            // value-producing action that fails does not throw at
            // `executeStatement`'s catch — the `AROFuture` carries the failure
            // and this is where it surfaces — so `.errorAny` never matched, and
            // `berror`, which the debugging guide bills as the breakpoint to
            // reach for when you do not yet know *where* the bug is, silently
            // did nothing for the majority of runtime failures (GitLab #561).
            //
            // The line is the statement that *created* the future, not the one
            // that noticed the empty value, so the pause points at the cause.
            await fireErrorCheckpoint(
                error: observed,
                context: context,
                line: runtime.deferredFailureLine
            )
            throw observed
        }
        if let drainError {
            await fireErrorCheckpoint(error: drainError, context: context, line: nil)
            throw drainError
        }
        // Backstop for a refused rebind no statement check observed — a
        // deferred action or event-driven bind that landed after its statement
        // was checked (GitLab #495). Less precise attribution than the
        // per-statement check, but the violation still surfaces as an error
        // instead of disappearing.
        try throwRefusedRebind(context: context)
    }

    /// Throw the rebind violation `RuntimeContext.bindTyped` refused during
    /// this statement, if there was one (GitLab #495).
    ///
    /// `bind` is non-throwing — it is called from every action, plugin bridge,
    /// and framework-variable site — so an immutable rebind is refused inside
    /// `bindTyped` (the existing value stays) and recorded on the feature-set
    /// context. This is where the record becomes a thrown error, attributed to
    /// the statement that attempted the rebind when the caller knows it.
    private func throwRefusedRebind(
        context: ExecutionContext,
        statementText: String? = nil
    ) throws {
        guard let runtime = context as? RuntimeContext,
              let violation = runtime.takeRebindViolation() else { return }
        guard let statementText else {
            throw ActionError.statementFailed(violation)
        }
        throw ActionError.statementFailed(AROError(
            message: violation.message,
            featureSet: violation.featureSet,
            businessActivity: violation.businessActivity,
            statement: statementText,
            resolvedValues: violation.resolvedValues
        ))
    }

    /// Verbs that may overwrite an existing binding rather than shadow it.
    ///
    /// Rebinding actions replace a value in place; REQUEST actions always
    /// produce fresh external data and must override a parent binding so an
    /// event handler doesn't read the value Application-Start left behind.
    private func allowsRebinding(_ verb: String) -> Bool {
        let rebindingVerbs: Set<String> = [
            "accept", "update", "modify", "change", "set", "configure",
            "delete", "remove", "destroy", "clear", "show",
            "merge", "combine", "join", "concat"
        ]
        let requestVerbs: Set<String> = [
            "retrieve", "fetch", "load", "find", "extract", "parse", "get",
            "request", "probe", "receive", "read"
        ]
        let lowerVerb = verb.lowercased()
        return rebindingVerbs.contains(lowerVerb) || requestVerbs.contains(lowerVerb)
    }

    /// Start a deferred action and hand back the handle to bind (ARO-0088 §2).
    ///
    /// The work begins immediately on `ActionTaskExecutor` — "eager start, lazy
    /// join". That matters for more than throughput: a `Retrieve` reads the
    /// repository at the point in time its statement implies, not at whatever
    /// later moment someone happens to read the binding.
    ///
    /// Failures are wrapped in the same `AROError` the eager path produces, at
    /// construction time, so the message names the statement that failed rather
    /// than the read that observed it (ARO-0088 §4).
    private func deferredResult(
        statement: AROStatement,
        verb: String,
        resultDescriptor: ResultDescriptor,
        objectDescriptor: ObjectDescriptor,
        statementScope: ExecutionContext
    ) -> AROFuture {
        let registry = actionRegistry
        let resultName = resultDescriptor.fullName
        let objectName = objectDescriptor.fullName
        let preposition = statement.object.preposition.rawValue
        let condition = statement.statementGuard.isPresent ? "when <condition>" : nil
        let featureSet = statementScope.featureSetName
        let activity = statementScope.businessActivity
        let location = "\(statement.span.start.line):\(statement.span.start.column)"

        return AROFuture(bindingName: resultDescriptor.base, sourceLocation: location) {
            do {
                return try await registry.execute(
                    verb: verb,
                    result: resultDescriptor,
                    object: objectDescriptor,
                    context: statementScope
                )
            } catch let assertionError as AssertionError {
                throw assertionError
            } catch let templateError as TemplateError {
                throw templateError
            } catch let aroError as AROError {
                throw ActionError.statementFailed(aroError)
            } catch {
                let aroError = AROError.fromStatement(
                    verb: verb,
                    result: resultName,
                    preposition: preposition,
                    object: objectName,
                    condition: condition,
                    featureSet: featureSet,
                    businessActivity: activity,
                    resolvedValues: [:],
                    // Lazy actions fail here rather than in the
                    // synchronous path above, so the unknown-qualifier
                    // sentence has to be attached in both places or the
                    // message depends on which path ran (#486 × ARO-0088).
                    hint: Self.statementHint(for: error)
                )
                throw ActionError.statementFailed(aroError)
            }
        }
    }

    /// Gather resolved variable values for error context
    private func gatherResolvedValues(
        for statement: AROStatement,
        context: ExecutionContext
    ) -> [String: String] {
        var values: [String: String] = [:]

        // Collect object base value
        let objectBase = statement.object.noun.base
        if let value = context.resolveAny(objectBase) {
            values[objectBase] = String(describing: value)
        }

        // Collect object specifier values
        for specifier in statement.object.noun.specifiers {
            if let value = context.resolveAny(specifier) {
                values[specifier] = String(describing: value)
            }
        }

        // Collect result base value
        let resultBase = statement.result.base
        if let value = context.resolveAny(resultBase) {
            values[resultBase] = String(describing: value)
        }

        // Collect result specifier values
        for specifier in statement.result.specifiers {
            if let value = context.resolveAny(specifier) {
                values[specifier] = String(describing: value)
            }
        }

        return values
    }

    private func executePublishStatement(
        _ statement: PublishStatement,
        context: ExecutionContext
    ) async throws {
        // A false guard skips the publish entirely — the name stays
        // unpublished rather than published with a sentinel, so a reader
        // that looks it up fails the way an absent binding always fails
        // (GitLab #830 item 14).
        if let whenCondition = statement.statementGuard.condition {
            let conditionResult = try await expressionEvaluator.evaluate(whenCondition, context: context)
            guard asBool(conditionResult) else { return }
        }

        // Get the internal value
        guard var value = context.resolveAny(statement.internalVariable) else {
            throw ActionError.undefinedVariable(statement.internalVariable)
        }

        // A published binding outlives the feature set that made it, so an
        // unread request body has to be anchored on the way out (GitLab #477):
        // drained to a file a chunk at a time, readable afterwards by anyone
        // who looks the name up. Publishing the live stream would hand out a
        // handle to a connection that is about to close.
        if let body = value as? RequestBodyValue {
            let statementText = "Publish as <\(statement.externalName)> <\(statement.internalVariable)>"
            value = try await AnchoredBody.anchor(body, statement: statementText)
            context.bind(statement.internalVariable, value: value, allowRebind: true)
        }

        // Publish to global symbols with business activity and execution owner
        await globalSymbols.publish(
            name: statement.externalName,
            value: value,
            fromFeatureSet: context.featureSetName,
            businessActivity: context.businessActivity,
            executionId: context.executionId
        )

        // Also bind the external name locally
        context.bind(statement.externalName, value: value)

        // Emit event
        eventBus.publish(VariablePublishedEvent(
            externalName: statement.externalName,
            internalName: statement.internalVariable,
            featureSet: context.featureSetName
        ))
    }

    // MARK: - Match Statement Execution (ARO-0004)

    private func executeMatchStatement(
        _ statement: MatchStatement,
        context: ExecutionContext
    ) async throws {
        // Resolve the subject value
        guard var subjectValue = context.resolveAny(statement.subject.base) else {
            throw ActionError.undefinedVariable(statement.subject.base)
        }

        // Apply field access specifiers (e.g. <state: mode> -> state.mode)
        for specifier in statement.subject.specifiers {
            subjectValue = try accessCollectionProperty(specifier, on: subjectValue)
        }

        // Try each case in order
        for caseClause in statement.cases {
            if try await matchesPattern(caseClause.pattern, against: subjectValue, context: context) {
                // Check guard condition if present
                if let guardCondition = caseClause.guardCondition {
                    let guardResult = try await expressionEvaluator.evaluate(guardCondition, context: context)
                    guard let boolResult = guardResult as? Bool, boolResult else {
                        continue // Guard failed, try next case
                    }
                }

                // Execute the case body
                for bodyStatement in caseClause.body {
                    try await executeStatement(bodyStatement, context: context)
                    // Check if we have a response
                    if context.getResponse() != nil {
                        return
                    }
                }
                return // Case matched, don't try other cases
            }
        }

        // No case matched, execute otherwise if present
        if let otherwiseBody = statement.otherwise {
            for bodyStatement in otherwiseBody {
                try await executeStatement(bodyStatement, context: context)
                if context.getResponse() != nil {
                    return
                }
            }
        }
    }

    /// Check if a pattern matches a value
    private func matchesPattern(
        _ pattern: Pattern,
        against value: any Sendable,
        context: ExecutionContext
    ) async throws -> Bool {
        switch pattern {
        case .literal(let literalValue):
            return matchesLiteral(literalValue, against: value)
        case .variable(let noun):
            // Resolve variable and compare
            if let varValue = context.resolveAny(noun.base) {
                return valuesEqual(varValue, value)
            }
            return false
        case .wildcard:
            return true
        case .regex(let pattern, let flags):
            guard let stringValue = value as? String else { return false }
            return regexMatches(stringValue, pattern: pattern, flags: flags)
        }
    }

    /// Check if a literal value matches a runtime value
    private func matchesLiteral(_ literal: LiteralValue, against value: any Sendable) -> Bool {
        switch literal {
        case .string(let s):
            if let valueString = value as? String {
                return s == valueString
            }
            return false
        case .integer(let i):
            if let valueInt = value as? Int {
                return i == valueInt
            }
            return false
        case .float(let f):
            if let valueFloat = value as? Double {
                return f == valueFloat
            }
            return false
        case .boolean(let b):
            if let valueBool = value as? Bool {
                return b == valueBool
            }
            return false
        case .null:
            // Check for nil-like values
            // Note: value is already any Sendable, so it can't be nil
            return false
        case .array, .object:
            // Complex types - use string comparison for now
            return String(describing: StatementModifiers.value(of: literal)) == String(describing: value)
        case .regex(let pattern, let flags):
            guard let stringValue = value as? String else { return false }
            return regexMatches(stringValue, pattern: pattern, flags: flags)
        }
    }

    /// Check if a string matches a regex pattern with flags
    private func regexMatches(_ string: String, pattern: String, flags: String) -> Bool {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }

        do {
            let regex = try RegexCache.shared.regex(pattern, options: options)
            let range = NSRange(string.startIndex..., in: string)
            return regex.firstMatch(in: string, range: range) != nil
        } catch {
            // Invalid regex pattern - return false
            return false
        }
    }

    /// Check if two values are equal
    private func valuesEqual(_ a: any Sendable, _ b: any Sendable) -> Bool {
        // Try various type comparisons
        if let aString = a as? String, let bString = b as? String {
            return aString == bString
        }
        if let aInt = a as? Int, let bInt = b as? Int {
            return aInt == bInt
        }
        if let aDouble = a as? Double, let bDouble = b as? Double {
            return aDouble == bDouble
        }
        if let aBool = a as? Bool, let bBool = b as? Bool {
            return aBool == bBool
        }
        // Fall back to string comparison
        return String(describing: a) == String(describing: b)
    }

    // MARK: - Require Statement Execution (ARO-0003)

    private func executeRequireStatement(
        _ statement: RequireStatement,
        context: ExecutionContext
    ) async throws {
        // Require statements are typically handled at analysis/setup time
        // At runtime, we just verify the dependency is available
        switch statement.source {
        case .framework:
            // Framework dependencies are auto-bound (console, http-server, etc.)
            // These are typically already available in the context
            break
        case .environment:
            // Environment variables
            if let envValue = ProcessInfo.processInfo.environment[statement.variableName] {
                context.bind(statement.variableName, value: envValue)
            }
        case .featureSet(let name):
            // Cross-feature-set dependency - resolve from global symbols (with business activity validation)
            if let value = await globalSymbols.resolveAny(statement.variableName, forBusinessActivity: context.businessActivity) {
                context.bind(statement.variableName, value: value)
            }
            // If not found, the dependency might be provided later
            _ = name // Suppress unused warning
        }
    }

    // MARK: - Property Access Helper

    /// Access a property on a collection value (for nested iteration like `<team: members>`)
    private func accessCollectionProperty(_ property: String, on value: any Sendable) throws -> any Sendable {
        // Handle [String: any Sendable] dictionary
        if let dict = value as? [String: any Sendable] {
            guard let propValue = dict[property] else {
                throw ActionError.propertyNotFound(property: property, on: "object")
            }
            return propValue
        }

        // Handle [String: AnySendable] dictionary
        if let dict = value as? [String: AnySendable] {
            guard let propValue = dict[property] else {
                throw ActionError.propertyNotFound(property: property, on: "object")
            }
            return propValue
        }

        throw ActionError.propertyNotFound(property: property, on: String(describing: type(of: value)))
    }

    // MARK: - Request body materialization (GitLab #477)

    /// Read an unread request body when the statement about to run needs it as
    /// a value.
    ///
    /// The classification is `StreamConsumptionPolicy`, the same table the
    /// compile-time analysis uses — one source of truth, so what the analyzer
    /// predicts and what the runtime does cannot drift apart.
    private func materializeRequestBodyIfNeeded(
        statement: AROStatement,
        verb: String,
        objectDescriptor: ObjectDescriptor,
        context: ExecutionContext
    ) async throws {
        let consumption = StreamConsumptionPolicy.consumption(
            ofVerb: verb,
            resultQualifiers: statement.result.specifiers
        )
        let description = "\(statement.action.verb) the <\(statement.result.base)> "
            + "\(objectDescriptor.preposition.rawValue) the <\(objectDescriptor.fullName)>"

        // The body can be in either slot: `Compute … from <upload>` puts it in
        // the object, `Log <upload> to the <console>` in the result.
        if let body = context.resolveAny(objectDescriptor.base) as? any UnreadBody,
           !objectDescriptor.specifiers.isEmpty || consumption == .wholeValue {
            let value = try await body.materializedValue(statement: description)
            context.bind(objectDescriptor.base, value: value, allowRebind: true)
        }

        if let body = context.resolveAny(statement.result.base) as? any UnreadBody,
           !statement.result.specifiers.isEmpty || consumption == .wholeValue {
            let value = try await body.materializedValue(statement: description)
            context.bind(statement.result.base, value: value, allowRebind: true)
        }
    }

    // MARK: - Range Loop Execution (ARO-0072)

    private func executeRangeLoop(_ loop: RangeLoop, context: ExecutionContext) async throws {
        let fromVal = try await expressionEvaluator.evaluate(loop.from, context: context)
        let toVal   = try await expressionEvaluator.evaluate(loop.to,   context: context)

        guard let fromInt = toInt(fromVal), let toInt = toInt(toVal) else {
            throw ActionError.typeMismatch(expected: "Int", actual: "\(type(of: fromVal))", variable: "range bounds")
        }

        for i in fromInt..<toInt {
            let iterationContext = context.createChild(featureSetName: context.featureSetName)
            iterationContext.bind(loop.variable, value: i)
            for stmt in loop.body {
                try await executeStatement(stmt, context: iterationContext)
                if iterationContext.getResponse() != nil { return }
            }
        }
    }

    private func toInt(_ value: any Sendable) -> Int? {
        if let i = value as? Int    { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    // MARK: - For-Each Loop Execution (ARO-0005)

    private func executeForEachLoop(
        _ loop: ForEachLoop,
        context: ExecutionContext
    ) async throws {
        // Resolve the collection: either a noun (with specifier support for
        // property access) or a general expression (GitLab #519).
        var collectionValue: any Sendable
        if let noun = loop.collection {
            guard let resolved: any Sendable = context.resolveAny(noun.base) else {
                throw ActionError.undefinedVariable(noun.base)
            }
            collectionValue = resolved

            // Lazy stream path: iterate without materialising the collection into memory (ARO-0051).
            // Specifiers are not supported on streams — they require an in-memory value.
            if let anyStream = collectionValue as? AnyStreamingValue, noun.specifiers.isEmpty {
                try await executeForEachLazy(loop, stream: anyStream.asStream(), context: context)
                return
            }

            // Handle specifiers as property access (e.g., <team: members> -> team.members)
            for specifier in noun.specifiers {
                collectionValue = try accessCollectionProperty(specifier, on: collectionValue)
            }
        } else if let expression = loop.collectionExpression {
            // Evaluated exactly once, before the first iteration — re-evaluating
            // per element would change both the semantics and the cost.
            collectionValue = try await expressionEvaluator.evaluate(expression, context: context)
        } else {
            throw ActionError.undefinedVariable("for-each collection")
        }

        // ARO-0051: Streaming support — iterate lazy streams without materializing
        if let anyStreaming = collectionValue as? AnyStreamingValue, !anyStreaming.isMaterialized {
            if !loop.isParallel {
                try await executeForEachLazy(loop, stream: anyStreaming.asStream(), context: context)
                return
            }
            // Parallel loops must materialize (no streaming support for concurrent iteration)
            collectionValue = try await anyStreaming.materialize() as any Sendable
        }

        // Convert to array
        let items: [any Sendable]
        if let array = collectionValue as? [any Sendable] {
            items = array
        } else if let array = collectionValue as? [String] {
            items = array
        } else if let array = collectionValue as? [Int] {
            items = array
        } else if let array = collectionValue as? [Double] {
            items = array
        } else {
            // Single item
            items = [collectionValue]
        }

        // Execute loop body for each item
        if loop.isParallel {
            // Parallel execution.
            // Default cap prevents pathological fan-out — without an explicit
            // `with <concurrency: N>` clause this used to spawn one Task per
            // item, so a page with 500 links spawned 500 Tasks. Falls back to
            // a multiple of the core count when the program does not specify.
            let concurrency = loop.concurrency ?? min(items.count, max(4, ProcessInfo.processInfo.activeProcessorCount * 4))
            try await withThrowingTaskGroup(of: Void.self) { group in
                var activeCount = 0
                for (index, item) in items.enumerated() {
                    // Create a child context for filter evaluation
                    // This ensures the filter check doesn't violate immutability
                    let filterContext = context.createChild(featureSetName: context.featureSetName)
                    filterContext.bind(loop.itemVariable, value: item)
                    if let indexVar = loop.indexVariable {
                        filterContext.bind(indexVar, value: index)
                    }

                    // Check filter condition if present
                    if let filter = loop.filter {
                        let filterResult = try await expressionEvaluator.evaluate(filter, context: filterContext)
                        guard let passes = filterResult as? Bool, passes else {
                            continue
                        }
                    }

                    group.addTask {
                        // The loop's own bound is `concurrency`; the
                        // application ceiling (ARO-0088 §10a, GitLab #862) is
                        // the one that also counts the handlers this body
                        // wakes. Nested work runs under this slot.
                        try await ApplicationLimits.withSlot {
                            // Create a child context for this iteration
                            let childContext = context.createChild(featureSetName: context.featureSetName)
                            childContext.bind(loop.itemVariable, value: item)
                            if let indexVar = loop.indexVariable {
                                childContext.bind(indexVar, value: index)
                            }

                            for bodyStatement in loop.body {
                                try await self.executeStatement(bodyStatement, context: childContext)
                            }
                        }
                    }

                    activeCount += 1
                    if activeCount >= concurrency {
                        try await group.next()
                        activeCount -= 1
                    }
                }
            }
        } else {
            // Sequential execution
            for (index, item) in items.enumerated() {
                // Cooperative scheduling: yield every 500 iterations so other Swift tasks
                // can run and the process does not pin a single CPU core at 100%.
                if index % 500 == 0 { await Task.yield() }

                // Create fresh child context for this iteration
                // This gives us fresh immutable bindings per iteration
                let iterationContext = context.createChild(featureSetName: context.featureSetName)

                // Bind loop variables in iteration context
                iterationContext.bind(loop.itemVariable, value: item)
                if let indexVar = loop.indexVariable {
                    iterationContext.bind(indexVar, value: index)
                }

                // Check filter condition if present
                if let filter = loop.filter {
                    let filterResult = try await expressionEvaluator.evaluate(filter, context: iterationContext)
                    guard let passes = filterResult as? Bool, passes else {
                        continue
                    }
                }

                // Execute loop body in iteration context
                for bodyStatement in loop.body {
                    try await executeStatement(bodyStatement, context: iterationContext)
                    if iterationContext.getResponse() != nil {
                        return
                    }
                }
            }
        }
    }

    // MARK: - Lazy Streaming For-Each (ARO-0051)

    /// Iterate a lazy AROStream one element at a time without materializing the full collection.
    /// Memory footprint is O(1) — only the current iteration's child context is live.
    private func executeForEachLazy(
        _ loop: ForEachLoop,
        stream: AROStream<any Sendable>,
        context: ExecutionContext
    ) async throws {
        var index = 0
        for try await item in stream.stream {
            let iterationContext = context.createChild(featureSetName: context.featureSetName)
            iterationContext.bind(loop.itemVariable, value: item)
            if let indexVar = loop.indexVariable {
                iterationContext.bind(indexVar, value: index)
            }

            if let filter = loop.filter {
                let filterResult = try await expressionEvaluator.evaluate(filter, context: iterationContext)
                guard let passes = filterResult as? Bool, passes else {
                    index += 1
                    continue
                }
            }

            for bodyStatement in loop.body {
                try await executeStatement(bodyStatement, context: iterationContext)
                if iterationContext.getResponse() != nil {
                    return
                }
            }
            index += 1
        }
    }

    // MARK: - When Clause Helpers

    /// Evaluate a value as a boolean for when clause conditions
    /// Follows JavaScript-like truthiness rules for convenience
    private func asBool(_ value: any Sendable) -> Bool {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        if let s = value as? String { return !s.isEmpty }
        if let array = value as? [any Sendable] { return !array.isEmpty }
        return true  // Non-nil values are truthy
    }

    // MARK: - While Loop Execution (GitLab #131)

    /// `when <condition> { … }` — the block spelling of the guard
    /// ARO has always had as a statement suffix (GitLab #516).
    ///
    /// The body runs in the enclosing scope, not a child one: a
    /// guarded block groups statements, it does not introduce a new
    /// place for names to live, so what it binds is visible after it
    /// exactly as if the statements had carried the guard each.
    private func executeWhenStatement(
        _ statement: WhenStatement,
        context: ExecutionContext
    ) async throws {
        let condition = try await expressionEvaluator.evaluate(statement.condition, context: context)
        guard asBool(condition) else { return }

        for bodyStatement in statement.body {
            try await executeStatement(bodyStatement, context: context)
            // A response inside the block ends the feature set, the
            // same way it does inside a loop body.
            if context.getResponse() != nil { return }
        }
    }

    private func executeWhileLoop(
        _ loop: WhileLoop,
        context: ExecutionContext
    ) async throws {
        context.enterMutableScope()
        defer { context.exitMutableScope() }

        while true {
            // Evaluate condition
            let condValue = try await expressionEvaluator.evaluate(loop.condition, context: context)
            guard asBool(condValue) else { break }

            // Execute body statements
            do {
                for statement in loop.body {
                    try await executeStatement(statement, context: context)
                    // Stop body early if a response was set
                    if context.getResponse() != nil { return }
                }
            } catch is BreakSignal {
                break
            }
        }
    }
}

/// Thrown by `break` statements to exit the enclosing while loop
struct BreakSignal: Error {}
