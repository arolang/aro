// ============================================================
// DataFlowAnalyzer.swift
// ARO Parser - Data Flow Analysis and Statement Analysis
// ============================================================
//
// Error-handling contract (#340): nonthrowing, exactly like
// SemanticAnalyzer (see Parser.swift for the module summary).
// Missing dependencies, unresolved identifiers, and shadowed
// publishes become diagnostics in the shared collector instead
// of exceptions. The empty-result fallback that some helpers
// return on missing inputs is the analyzer's way of letting
// downstream passes still observe partial structure — the real
// signal of failure is on the diagnostics bag, not the return
// value.

import Foundation

// MARK: - Data Flow Analyzer

/// Analyzes data flow through statements: variable tracking, immutability,
/// dependency detection, and streaming optimizations (ARO-0051)
public struct DataFlowAnalyzer {

    private let diagnostics: DiagnosticCollector

    /// Names that are already bound outside the source being analyzed.
    ///
    /// A REPL or notebook cell is compiled on its own, wrapped in a throwaway
    /// feature set, while the values it refers to live in the session. Reading
    /// such a name is only a warning, so every other statement worked — but
    /// `Publish` *errors* on an undefined variable, so `Publish as <x> <w>.`
    /// failed for a `<w>` bound in an earlier cell, which is precisely the
    /// cross-cell operation `Publish` exists for (GitLab #689).
    ///
    /// Empty for an ordinary compile, where a name not defined in the source
    /// genuinely is not defined.
    private let preboundSymbols: Set<String>

    public init(diagnostics: DiagnosticCollector, preboundSymbols: Set<String> = []) {
        self.diagnostics = diagnostics
        self.preboundSymbols = preboundSymbols
    }

    // MARK: - Feature Set Analysis

    /// Analyzes a single feature set, returning symbol table, data flows, dependencies, and exports
    public func analyzeFeatureSet(_ featureSet: FeatureSet) -> AnalyzedFeatureSet {
        let builder = SymbolTableBuilder(
            // The name, not its `hashValue` (GitLab #667). Swift seeds
            // `hashValue` per process, so the same feature set got a different
            // scope id on every run — and anything that compares or persists
            // one across runs (debug recordings, LSP snapshots, `aro diff`
            // output) saw two unrelated scopes where there was one. A feature
            // set's name is already unique within an application, which is
            // what the id needs to be.
            scopeId: "fs-\(featureSet.name)",
            scopeName: featureSet.name
        )

        var dataFlows: [DataFlowInfo] = []
        var dependencies: Set<String> = []
        var exports: Set<String> = []
        var definedSymbols: Set<String> = []

        for statement in featureSet.statements {
            let (flow, newDeps) = analyzeStatement(
                statement,
                builder: builder,
                definedSymbols: &definedSymbols
            )
            dataFlows.append(flow)
            dependencies.formUnion(newDeps)

            if let publish = statement as? PublishStatement {
                exports.insert(publish.externalName)
            }

            if let require = statement as? RequireStatement {
                dependencies.insert(require.variableName)
            }
        }

        // Detect unused variables (ARO-0003)
        let symbolTable = builder.build()
        var usedVariables: Set<String> = []
        for flow in dataFlows {
            usedVariables.formUnion(flow.inputs)
        }

        // Result names produced by a side-effect verb are intentionally
        // discardable — Make, Append, Write, Log, Emit, Start, Stop,
        // Send, Notify, Schedule and user-defined `Application.X` calls
        // are all "do something" rather than "compute a value". Mark
        // them used so the unused-var warning doesn't shame intentional
        // fire-and-forget calls.
        // Walk the whole statement tree (descending into match cases and
        // for-each bodies) — the checks below need to see every action,
        // not just top-level ones.
        let allAros = collectAROStatements(featureSet.statements)

        var sideEffectResults: Set<String> = []
        for aro in allAros where isSideEffectVerb(aro.action.verb) {
            sideEffectResults.insert(aro.result.base)
        }

        // ARO-0015 fixtures (GitLab #823). `Given the <text> with "hello".`
        // binds the input that the feature set *under test* reads, so the
        // read is in another feature set by construction and looking for it
        // here will never find one.
        for aro in allAros where aro.action.verb.lowercased() == "given" {
            sideEffectResults.insert(aro.result.base)
        }

        // Variables consumed as the *base* of another statement's result
        // qualifier (e.g. the `defaults` in `Merge the <opts: defaults>
        // with <raw>.`) are real uses too — the data-flow visitor only
        // records the right-hand side as input, so flag the qualifier
        // bases explicitly here.
        var qualifierBaseRefs: Set<String> = []
        for aro in allAros {
            for specifier in aro.result.specifiers {
                qualifierBaseRefs.insert(specifier)
            }
        }

        // If the feature set renders a template via Transform/Include
        // (object base == "template"), the template body reads variables
        // from the calling scope at runtime — static analysis can't see
        // those reads, so suppress unused warnings for every local in
        // this feature set.
        let rendersTemplate = allAros.contains { aro in
            let verb = aro.action.verb.lowercased()
            return (verb == "transform" || verb == "include" || verb == "render")
                && aro.object.noun.base.lowercased() == "template"
        }

        for (name, symbol) in symbolTable.symbols {
            if symbol.visibility == .published { continue }
            if case .alias = symbol.source { continue }
            if symbol.visibility == .external { continue }
            if isSideEffectBinding(name) { continue }
            if sideEffectResults.contains(name) { continue }
            if qualifierBaseRefs.contains(name) { continue }
            if rendersTemplate { continue }

            if !usedVariables.contains(name) {
                diagnostics.warning(
                    "Variable '\(name)' is defined but never used",
                    at: symbol.definedAt.start,
                    // Consequential (GitLab #509): when the statement that
                    // was meant to use the variable itself errored, this is
                    // fallout, not the finding — rank it below root causes.
                    category: .consequential,
                    code: .unusedVariable
                )
            }
        }

        // ARO-0051: Detect streaming optimizations
        let aggregationFusions = detectAggregationFusions(featureSet.statements)
        let streamConsumers = detectStreamConsumers(dataFlows, statements: featureSet.statements)

        return AnalyzedFeatureSet(
            featureSet: featureSet,
            symbolTable: symbolTable,
            dataFlows: dataFlows,
            dependencies: dependencies,
            exports: exports,
            aggregationFusions: aggregationFusions,
            streamConsumers: streamConsumers,
            // #339: reuse the tree walk already performed above (`allAros`) so
            // later passes don't re-traverse. `allAros` is every AROStatement in
            // source order, descending into match cases/otherwise and for-each
            // bodies — exactly the traversal the emitted-event scan needs.
            flattenedAROStatements: allAros
        )
    }

    // MARK: - Statement Analysis

    private func analyzeStatement(
        _ statement: Statement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>,
        inMutableScope: Bool = false
    ) -> (DataFlowInfo, Set<String>) {

        // #338: dispatch on the concrete node type via the visitor instead of
        // an `as?` cast chain. The visitor threads the same mutable analysis
        // state (`builder`, `definedSymbols`, `inMutableScope`) that the old
        // chain passed by hand, then writes any newly-defined symbols back
        // into the caller's `inout` set — reproducing the `inout` semantics of
        // the previous helper calls exactly.
        let visitor = StatementDataFlowVisitor(
            analyzer: self,
            builder: builder,
            definedSymbols: definedSymbols,
            inMutableScope: inMutableScope
        )
        let result = statement.accept(visitor)
        definedSymbols = visitor.definedSymbols
        return result
    }

    // MARK: - Statement Data-Flow Visitor (#338)

    /// Dispatches each `Statement` node to the analyzer's per-node routine.
    ///
    /// Holds the mutable analysis state as instance properties because
    /// `StatementVisitor.visit` takes no extra parameters. `definedSymbols`
    /// starts as a copy of the caller's set; nodes that define symbols mutate
    /// it in place (matching the old `inout` calls), and `analyzeStatement`
    /// copies it back out afterwards.
    ///
    /// Every `Statement` node has an explicit `visit`. `RangeLoop`,
    /// `PipelineStatement` and `ErrorStatement` — which the old `as?`-chain
    /// never matched and so fell through to its trailing `return
    /// (DataFlowInfo(), [])` — return that same empty result here, preserving
    /// the fallback semantics precisely. `BreakStatement` did the same in the
    /// old chain and continues to.
    private final class StatementDataFlowVisitor: StatementVisitor {
        typealias Result = (DataFlowInfo, Set<String>)

        let analyzer: DataFlowAnalyzer
        let builder: SymbolTableBuilder
        var definedSymbols: Set<String>
        let inMutableScope: Bool

        init(
            analyzer: DataFlowAnalyzer,
            builder: SymbolTableBuilder,
            definedSymbols: Set<String>,
            inMutableScope: Bool
        ) {
            self.analyzer = analyzer
            self.builder = builder
            self.definedSymbols = definedSymbols
            self.inMutableScope = inMutableScope
        }

        func visit(_ node: AROStatement) -> Result {
            analyzer.analyzeAROStatement(
                node, builder: builder,
                definedSymbols: &definedSymbols, inMutableScope: inMutableScope
            )
        }

        func visit(_ node: PublishStatement) -> Result {
            analyzer.analyzePublishStatement(
                node, builder: builder, definedSymbols: definedSymbols
            )
        }

        func visit(_ node: RequireStatement) -> Result {
            analyzer.analyzeRequireStatement(
                node, builder: builder, definedSymbols: &definedSymbols
            )
        }

        func visit(_ node: WhenStatement) -> Result {
            analyzer.analyzeWhenStatement(
                node, builder: builder, definedSymbols: &definedSymbols
            )
        }

        func visit(_ node: MatchStatement) -> Result {
            analyzer.analyzeMatchStatement(
                node, builder: builder, definedSymbols: &definedSymbols
            )
        }

        func visit(_ node: ForEachLoop) -> Result {
            analyzer.analyzeForEachLoop(
                node, builder: builder, definedSymbols: &definedSymbols
            )
        }

        func visit(_ node: WhileLoop) -> Result {
            analyzer.analyzeWhileLoop(
                node, builder: builder, definedSymbols: &definedSymbols
            )
        }

        func visit(_ node: BreakStatement) -> Result {
            (DataFlowInfo(), [])
        }

        func visit(_ node: RangeLoop) -> Result {
            analyzer.analyzeRangeLoop(
                node, builder: builder, definedSymbols: &definedSymbols
            )
        }

        /// A pipeline is its stages (GitLab #666).
        ///
        /// This returned an empty result, so every `|>` stage was invisible:
        /// the results they bind were never defined in the symbol table, and a
        /// later `Compute … from <stage-result>` warned "used before
        /// definition" about a variable the pipeline had just produced. The
        /// variables a pipeline *reads* were equally invisible, so a genuinely
        /// undefined name inside one went unreported.
        ///
        /// Each stage is an ordinary `AROStatement`, analysed in order exactly
        /// as it would be outside a pipeline — the stages run in sequence and
        /// each sees what the previous one bound.
        func visit(_ node: PipelineStatement) -> Result {
            var inputs: Set<String> = []
            var outputs: Set<String> = []
            var sideEffects: [String] = []
            var dependencies: Set<String> = []
            for stage in node.stages {
                let (stageInfo, stageDependencies) = analyzer.analyzeAROStatement(
                    stage, builder: builder,
                    definedSymbols: &definedSymbols, inMutableScope: inMutableScope
                )
                inputs.formUnion(stageInfo.inputs)
                outputs.formUnion(stageInfo.outputs)
                sideEffects.append(contentsOf: stageInfo.sideEffects)
                dependencies.formUnion(stageDependencies)
            }
            return (DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
                    dependencies)
        }

        // Fallback nodes — the old `as?`-chain matched none of these and so
        // returned the empty default. Keep that behaviour explicit.
        func visit(_ node: ErrorStatement) -> Result { (DataFlowInfo(), []) }
    }

    // MARK: - ARO Statement

    private func analyzeAROStatement(
        _ statement: AROStatement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>,
        inMutableScope: Bool = false
    ) -> (DataFlowInfo, Set<String>) {

        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        let resultName = statement.result.base
        let objectName = statement.object.noun.base

        // `with 2 seconds.` / `for 300ms.` stores the time unit as the
        // object base (the runtime reads it as an interval multiplier — see
        // ScheduleAction and SleepAction). The unit word is not a variable
        // reference: without this guard the analyzer reports
        // "Variable 'seconds' used before definition" and records a phantom
        // external dependency for every `Schedule … with N <unit>` statement.
        // The vocabulary is DurationUnitCatalog (GitLab #502) — a partial
        // copy here missed `milliseconds`, `ms`, `s`, `m`, `min` and `h`,
        // so exactly the short suffixes the Sleep fix recommends drew the
        // phantom warning.
        let objectIsTimeUnit: Bool = {
            guard DurationUnitCatalog.isUnit(objectName) else { return false }
            switch statement.valueSource {
            case .literal(.integer), .literal(.float):
                return true
            case .expression:
                return true
            default:
                return false
            }
        }()

        // Track object qualifier as input if it looks like a variable reference
        if let objectQualifier = statement.object.noun.typeAnnotation,
           looksLikeVariable(objectQualifier) {
            inputs.insert(objectQualifier)
        }

        // ARO-0002: Extract variables from expression if present
        if let expr = statement.valueSource.asExpression {
            let exprVars = extractVariables(from: expr)
            for varName in exprVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // ARO-0004: Extract variables from when condition if present
        if let whenExpr = statement.statementGuard.condition {
            let condVars = extractVariables(from: whenExpr)
            for varName in condVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // ARO-0018: Extract variables from every where predicate (GitLab #498:
        // a compound condition carries one value expression per predicate)
        if let whereCondition = statement.queryModifiers.whereCondition {
            for predicate in whereCondition.predicates {
                let whereVars = extractVariables(from: predicate.value)
                for varName in whereVars {
                    if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                        dependencies.insert(varName)
                    }
                    inputs.insert(varName)
                }
            }
        }

        // ARO-0036: `matching <pattern>` reads the glob out of a variable, so
        // that variable is an input like any other (GitLab #518).
        if let matching = statement.queryModifiers.matchingPattern {
            let matchVars = extractVariables(from: matching)
            for varName in matchVars {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // Every range-modifier operand is a read (GitLab #823).
        //
        // Only `with` was walked, so the operand of the other two was
        // invisible: `Compare the <same> from the <expected> against the
        // <actual>.` reported `actual` "defined but never used" — a variable
        // the statement on the line above reads — and
        // `Create the <span: date-range> from <start> to <end>.` did the same
        // to `end`. `RangeModifiers` has carried all three since GitLab #469;
        // this walk had not caught up.
        for clause in [statement.rangeModifiers.withClause,
                       statement.rangeModifiers.againstClause,
                       statement.rangeModifiers.toClause].compactMap({ $0 }) {
            for varName in extractVariables(from: clause) {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // A verb whose *result slot* names content to read, when that name is
        // already bound.
        //
        // `Append the <log-line> to the <file: "./app.log">.` is
        // `AppendAction`'s own documented primary form, and the action does
        // read the content from the result slot:
        //
        //     } else if let value: String = context.resolve(result.base) {
        //         content = value
        //
        // But the analyzer treated the slot as a *binding*, so the variable
        // holding the content was being rebound and the immutability check
        // rejected the statement before the action could run — with a hint
        // suggesting `<log-line-updated>`, which is unbound and would append
        // the empty string (GitLab #580).
        //
        // `store`, `write`, `emit`, `save`, `persist` and `send` already had
        // this rule inside the `.response` branch; `append` belongs with them.
        // It is applied here rather than there so it holds regardless of which
        // role branch the verb takes — `append` classifies as `.own` today and
        // `.response` once the role taxonomy is unified (GitLab #585).
        //
        // Scoped twice. The name must be *already defined* — the same guard
        // the `.response` branch uses — and the statement must carry no `with`
        // clause: `Append the <entry> to the <file: …> with "…"` takes its
        // content from the literal, exactly as `AppendAction` prefers
        // `_literal_` over the result slot, so there the slot really is an
        // output and binds an `AppendResult`.
        if Self.resultIsContentVerbs.contains(statement.action.verb.lowercased()),
           definedSymbols.contains(resultName),
           statement.rangeModifiers.withClause == nil {
            inputs.insert(resultName)
            if definedSymbols.contains(objectName) || isKnownExternal(objectName) {
                inputs.insert(objectName)
            }
            sideEffects.append("\(statement.action.verb):\(resultName)")
            return (
                DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
                dependencies
            )
        }

        // Determine data flow based on action semantic role
        switch statement.action.semanticRole {
        case .request:
            if !isKnownExternal(objectName) && !definedSymbols.contains(objectName) && !objectIsTimeUnit {
                dependencies.insert(objectName)
            }
            if !objectIsTimeUnit { inputs.insert(objectName) }
            outputs.insert(resultName)

            let dataType = TypeInferencer.inferResultType(statement)
            checkImmutabilityViolation(
                name: resultName, verb: statement.action.verb,
                objectName: objectName, preposition: statement.object.preposition,
                span: statement.result.span,
                definedSymbols: definedSymbols, inMutableScope: inMutableScope
            )

            builder.define(
                name: resultName,
                definedAt: statement.span,
                visibility: .internal,
                source: .extracted(from: objectName),
                dataType: dataType
            )
            definedSymbols.insert(resultName)

        case .own:
            // Three `.own` verbs whose object slot names something other
            // than a variable (GitLab #823).
            let verb = statement.action.verb.lowercased()

            // ARO-0015 §2.2: `When the <sum> from the <add-numbers>.` names
            // the feature set under test. Reported "used before definition"
            // in every test in the examples.
            //
            // ARO-0016: `Call the <rows> from the <sqlite: execute> with
            // { … }.` names an external service and the method on it —
            // nine warnings in SQLiteExample alone, and one in ZipService.
            //
            // ARO-0010: `Execute the <result> for the <listing> with
            // <command>.` labels what is being run; the command is in the
            // `with` clause.
            let objectNamesAFeatureSet = verb == "when"
            let objectNamesAService = verb == "call" || verb == "invoke"
            let objectIsALabel = (verb == "exec" || verb == "execute"
                                  || verb == "shell" || verb == "run")
                && statement.object.preposition == .for

            let objectIsNotAVariable = objectNamesAFeatureSet
                || objectNamesAService || objectIsALabel

            if !isKnownExternal(objectName) && !definedSymbols.contains(objectName)
                && !dependencies.contains(objectName) && !objectIsTimeUnit
                && !objectIsNotAVariable {
                diagnostics.warning(
                    "Variable '\(objectName)' used before definition",
                    at: statement.object.noun.span.start
                )
            }
            if !objectIsTimeUnit && !objectIsNotAVariable { inputs.insert(objectName) }

            // ARO-0015 §2.3: `Then the <sum> with 8.` asserts *about* its
            // result slot — it reads the binding rather than making one.
            // Treated as an output, every `Then` left its subject looking
            // unused, which is how `len`, `upper` and `lower` were warned
            // about in AssertDemo.
            if verb == "then" {
                inputs.insert(resultName)
                if !isKnownExternal(resultName) && !definedSymbols.contains(resultName) {
                    dependencies.insert(resultName)
                }
                return (DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
                        dependencies)
            }

            outputs.insert(resultName)

            let dataType = TypeInferencer.inferResultType(statement)
            checkImmutabilityViolation(
                name: resultName, verb: statement.action.verb,
                objectName: objectName, preposition: statement.object.preposition,
                span: statement.result.span,
                definedSymbols: definedSymbols, inMutableScope: inMutableScope
            )

            builder.define(
                name: resultName,
                definedAt: statement.span,
                visibility: .internal,
                source: .computed,
                dataType: dataType
            )
            definedSymbols.insert(resultName)

        case .response:
            if definedSymbols.contains(objectName) || isKnownExternal(objectName) {
                inputs.insert(objectName)
            }
            if Self.resultIsContentVerbs.contains(statement.action.verb.lowercased()) {
                if definedSymbols.contains(resultName) {
                    inputs.insert(resultName)
                }
            }
            sideEffects.append("\(statement.action.verb):\(resultName)")

            // GitLab #515: `Store the <ticket> into the <ticket-repository>
            // with { … }` binds the stored record to <ticket> — the payload is
            // the value, so the result slot is an output here, not a read of
            // something defined earlier. Without this the record is invisible
            // to the analyzer and every later use reports "External dependency
            // 'ticket' is not published by any feature set".
            //
            // The `<stored-user: user>` spelling binds too (GitLab #823).
            // The comment here used to say it "reads a variable that already
            // exists", and the runtime disagrees — `Store the <stored-user:
            // user> into the <user-repository>.` binds `stored-user` to the
            // stored record, id and all, which is the whole reason to write
            // it that way. `user` is the read. Treating the base as a read
            // made `Return a <Created: status> with <stored-user>.` report
            // "External dependency 'stored-user' is not published" in both
            // UserService and RepositoryObserver.
            //
            // The bare spelling still defines nothing: it stores a variable
            // under its own name.
            // StoreAction.verbs, mirrored here because AROParser cannot see it.
            // `append` joins them: the block above hands the `with` form to
            // this branch precisely because the slot is an output there, and
            // an output that names an existing variable is a rebind. Before
            // the role taxonomy was unified `append` classified as `.own`, so
            // that branch ran the check and this one never had to — the two
            // changes are individually correct and silently drop the check
            // when combined (GitLab #580, #585).
            let storeVerbs = ["store", "save", "persist", "append"]
            let isStore = storeVerbs.contains(statement.action.verb.lowercased())
            let intoARepository = statement.object.preposition == .into
                || statement.object.preposition == .to

            // `<stored-user: user>`: the specifier names what is stored, the
            // base names the binding the statement produces.
            if isStore, intoARepository, let stored = statement.result.specifiers.first {
                if definedSymbols.contains(stored) { inputs.insert(stored) }
                checkImmutabilityViolation(
                    name: resultName, verb: statement.action.verb,
                    objectName: objectName, preposition: statement.object.preposition,
                    span: statement.result.span,
                    definedSymbols: definedSymbols, inMutableScope: inMutableScope
                )
                outputs.insert(resultName)
                builder.define(
                    name: resultName,
                    definedAt: statement.span,
                    visibility: .internal,
                    source: .computed,
                    dataType: TypeInferencer.inferResultType(statement)
                )
                definedSymbols.insert(resultName)
            }

            if isStore,
               statement.rangeModifiers.withClause != nil,
               statement.result.typeAnnotation == nil,
               statement.result.specifiers.isEmpty,
               intoARepository {
                // A name that already holds a value cannot also hold the stored
                // record — the runtime refuses the rebind, so say so here where
                // it is cheap to fix (ARO-0001 immutability).
                checkImmutabilityViolation(
                    name: resultName, verb: statement.action.verb,
                    objectName: objectName, preposition: statement.object.preposition,
                    span: statement.result.span,
                    definedSymbols: definedSymbols, inMutableScope: inMutableScope
                )
                outputs.insert(resultName)
                builder.define(
                    name: resultName,
                    definedAt: statement.span,
                    visibility: .internal,
                    source: .computed,
                    dataType: TypeInferencer.inferResultType(statement)
                )
                definedSymbols.insert(resultName)
            }

        case .export:
            break

        case .server:
            if !isKnownExternal(objectName) && !definedSymbols.contains(objectName)
                && !dependencies.contains(objectName) && !objectIsTimeUnit {
                if !isServiceObject(objectName) {
                    dependencies.insert(objectName)
                }
            }
            if !objectIsTimeUnit { inputs.insert(objectName) }
            outputs.insert(resultName)

            let dataType = TypeInferencer.inferResultType(statement)
            checkImmutabilityViolation(
                name: resultName, verb: statement.action.verb,
                objectName: objectName, preposition: statement.object.preposition,
                span: statement.result.span,
                definedSymbols: definedSymbols, inMutableScope: inMutableScope
            )

            builder.define(
                name: resultName,
                definedAt: statement.span,
                visibility: .internal,
                source: .computed,
                dataType: dataType
            )
            definedSymbols.insert(resultName)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    /// Verbs that read the value in their **result slot** rather than binding
    /// one there.
    ///
    /// `Store the <a> into the <repo>.`, `Write the <text> to the <file>.`,
    /// `Append the <line> to the <file>.` — the slot names what to write. The
    /// first five have always been handled; `append` was missing, which made
    /// its own documented primary form a rebinding error (GitLab #580).
    ///
    /// `Attach the <session> to the <connection>.` (ARO-0094 §6.1) is the same
    /// shape: the session is retrieved from the sessions repository on the line
    /// above, and the slot names *which* session to attach. Binding there would
    /// make the proposal's own promotion example a rebinding error.
    static let resultIsContentVerbs: Set<String> = [
        "store", "write", "emit", "save", "persist", "send", "append", "attach",
    ]

    // MARK: - Immutability Check

    /// Checks whether rebinding a variable would violate immutability rules
    private func checkImmutabilityViolation(
        name: String,
        verb: String,
        objectName: String,
        preposition: Preposition,
        span: SourceSpan,
        definedSymbols: Set<String>,
        inMutableScope: Bool
    ) {
        if definedSymbols.contains(name) && !isInternalVariable(name) && !isRebindingAllowed(verb) && !inMutableScope {
            diagnostics.error(
                "Cannot rebind variable '\(name)' - variables are immutable",
                at: span.start,
                hints: hintsForRebinding(
                    name: name, verb: verb, objectName: objectName, preposition: preposition)
            )
        }
    }


    /// Hints for an immutability violation.
    ///
    /// The generic advice — bind a differently-named variable — is right for a
    /// value and wrong for `Configure`, whose result names a *thing being
    /// configured* rather than a value being produced. Two settings on one
    /// repository is the natural spelling and reads as a rebinding:
    ///
    ///     Configure the <cache-repository: ttl> with 60.
    ///     Configure the <cache-repository: maxSize> with 500.
    ///
    /// Advising `<cache-repository-updated>` there is nonsense: that names a
    /// different repository, so the program would compile and configure the
    /// wrong thing. The object form sets both at once and is what to write
    /// (GitLab #564).
    private func hintsForRebinding(
        name: String,
        verb: String,
        objectName: String,
        preposition: Preposition
    ) -> [String] {
        let alreadyDefined = "Variable '\(name)' was already defined earlier in this feature set"

        if verb.lowercased() == "configure" {
            return [
                alreadyDefined,
                "Configure takes every setting at once, in one object",
                "Example: <Configure> the <\(name)> with { setting: value, other: value }",
            ]
        }

        return [
            alreadyDefined,
            "Create a new variable with a different name instead",
            "Example: <\(verb)> the <\(name)-updated> \(preposition.rawValue) the <\(objectName)>",
        ]
    }

    // MARK: - Publish Statement

    private func analyzePublishStatement(
        _ statement: PublishStatement,
        builder: SymbolTableBuilder,
        definedSymbols: Set<String>
    ) -> (DataFlowInfo, Set<String>) {

        if !definedSymbols.contains(statement.internalVariable),
           !preboundSymbols.contains(statement.internalVariable) {
            diagnostics.error(
                "Cannot publish undefined variable '\(statement.internalVariable)'",
                at: statement.span.start
            )
        }

        builder.updateVisibility(name: statement.internalVariable, to: .published)

        builder.define(
            name: statement.externalName,
            definedAt: statement.span,
            visibility: .published,
            source: .alias(of: statement.internalVariable)
        )

        return (
            DataFlowInfo(inputs: [statement.internalVariable], outputs: [statement.externalName]),
            []
        )
    }

    // MARK: - Require Statement

    private func analyzeRequireStatement(
        _ statement: RequireStatement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        // A Require introduces the name, so later statements read a symbol that
        // is defined rather than an unresolved one. Without this every use of a
        // Required variable was reported as an unpublished external dependency,
        // which is the opposite of what the statement declares (GitLab #828).
        definedSymbols.insert(statement.variableName)

        builder.define(
            name: statement.variableName,
            definedAt: statement.span,
            visibility: .external,
            source: .extracted(from: "\(statement.source)")
        )

        return (
            DataFlowInfo(inputs: [], outputs: [statement.variableName]),
            [statement.variableName]
        )
    }

    // MARK: - Match Statement (ARO-0004)

    private func analyzeMatchStatement(
        _ statement: MatchStatement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        let subjectName = statement.subject.base
        if !definedSymbols.contains(subjectName) && !isKnownExternal(subjectName) {
            diagnostics.warning(
                "Variable '\(subjectName)' used in match before definition",
                at: statement.subject.span.start
            )
        }
        inputs.insert(subjectName)

        var branchDefinitions: [Set<String>] = []

        for caseClause in statement.cases {
            var branchSymbols = definedSymbols

            if let guard_ = caseClause.guardCondition {
                let guardVars = extractVariables(from: guard_)
                for varName in guardVars {
                    if !branchSymbols.contains(varName) && !isKnownExternal(varName) {
                        dependencies.insert(varName)
                    }
                    inputs.insert(varName)
                }
            }

            if case .variable(let noun) = caseClause.pattern {
                let patternName = noun.base
                if branchSymbols.contains(patternName) {
                    inputs.insert(patternName)
                }
            }

            for bodyStatement in caseClause.body {
                let (flow, newDeps) = analyzeStatement(
                    bodyStatement,
                    builder: builder,
                    definedSymbols: &branchSymbols
                )
                inputs.formUnion(flow.inputs)
                outputs.formUnion(flow.outputs)
                sideEffects.append(contentsOf: flow.sideEffects)
                dependencies.formUnion(newDeps)
            }

            branchDefinitions.append(branchSymbols.subtracting(definedSymbols))
        }

        if let otherwise = statement.otherwise {
            var branchSymbols = definedSymbols

            for bodyStatement in otherwise {
                let (flow, newDeps) = analyzeStatement(
                    bodyStatement,
                    builder: builder,
                    definedSymbols: &branchSymbols
                )
                inputs.formUnion(flow.inputs)
                outputs.formUnion(flow.outputs)
                sideEffects.append(contentsOf: flow.sideEffects)
                dependencies.formUnion(newDeps)
            }

            branchDefinitions.append(branchSymbols.subtracting(definedSymbols))
        }

        if !branchDefinitions.isEmpty {
            let allBranchSymbols = branchDefinitions.reduce(Set<String>()) { $0.union($1) }
            definedSymbols.formUnion(allBranchSymbols)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // MARK: - For-Each Loop (ARO-0005)

    private func analyzeForEachLoop(
        _ statement: ForEachLoop,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        // The collection is either a noun or an expression (GitLab #519). A noun
        // is one input and can be reported as undefined by name; an expression
        // contributes every variable it reads.
        let collectionName: String
        if let noun = statement.collection {
            collectionName = noun.base
            if !definedSymbols.contains(collectionName) && !isKnownExternal(collectionName) {
                diagnostics.warning(
                    "Collection '\(collectionName)' used in for-each before definition",
                    at: noun.span.start
                )
            }
            inputs.insert(collectionName)
        } else {
            collectionName = statement.collectionLabel
            if let expression = statement.collectionExpression {
                for varName in extractVariables(from: expression) {
                    if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                        diagnostics.warning(
                            "Collection '\(varName)' used in for-each before definition",
                            at: expression.span.start
                        )
                    }
                    inputs.insert(varName)
                }
            }
        }

        if let filter = statement.filter {
            let filterVars = extractVariables(from: filter)
            for varName in filterVars {
                if varName != statement.itemVariable && !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        var loopDefinedSymbols = definedSymbols

        builder.define(
            name: statement.itemVariable,
            definedAt: statement.span,
            visibility: .internal,
            source: .extracted(from: collectionName),
            dataType: .unknown
        )
        loopDefinedSymbols.insert(statement.itemVariable)

        if let indexVar = statement.indexVariable {
            builder.define(
                name: indexVar,
                definedAt: statement.span,
                visibility: .internal,
                source: .computed,
                dataType: .integer
            )
            loopDefinedSymbols.insert(indexVar)
        }

        if statement.isParallel {
            if let concurrency = statement.concurrency {
                sideEffects.append("parallel:concurrency=\(concurrency)")
            } else {
                sideEffects.append("parallel")
            }
        }

        for bodyStatement in statement.body {
            let (flow, newDeps) = analyzeStatement(
                bodyStatement,
                builder: builder,
                definedSymbols: &loopDefinedSymbols
            )
            inputs.formUnion(flow.inputs)
            outputs.formUnion(flow.outputs)
            sideEffects.append(contentsOf: flow.sideEffects)
            dependencies.formUnion(newDeps)
        }

        outputs.remove(statement.itemVariable)
        if let indexVar = statement.indexVariable {
            outputs.remove(indexVar)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // MARK: - Range Loop (ARO-0002)

    /// `for <i> from <a> to <b> { … }`.
    ///
    /// This node used to fall through to the visitor's empty default, so the
    /// analysis never saw it at all: variables read in the bounds or anywhere
    /// in the body were missing from `usedVariables`, and the LAST binding of
    /// a loop bound was reported "defined but never used" while the loop
    /// right below it read the value. The Crawler hit exactly that —
    /// `for <pass> from 0 to <max-iters>` did not count as a read of
    /// `max-iters`, and a repair tool acting on the false warning would have
    /// deleted a live binding.
    private func analyzeRangeLoop(
        _ statement: RangeLoop,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        // The bounds are reads.
        for bound in [statement.from, statement.to] {
            for varName in extractVariables(from: bound) {
                if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                    dependencies.insert(varName)
                }
                inputs.insert(varName)
            }
        }

        // The loop variable is scoped to the body, like for-each's item.
        var loopDefinedSymbols = definedSymbols
        builder.define(
            name: statement.variable,
            definedAt: statement.span,
            visibility: .internal,
            source: .computed,
            dataType: .integer
        )
        loopDefinedSymbols.insert(statement.variable)

        // The loop machinery itself reads the counter on every iteration to
        // advance and compare against the bound, so it is never "unused" —
        // and `for <pass> from 0 to <n>` with an unread counter is the
        // idiomatic way to repeat n times; there is no bare repeat form to
        // point the warning at.
        inputs.insert(statement.variable)

        for bodyStatement in statement.body {
            let (flow, newDeps) = analyzeStatement(
                bodyStatement,
                builder: builder,
                definedSymbols: &loopDefinedSymbols
            )
            inputs.formUnion(flow.inputs)
            outputs.formUnion(flow.outputs)
            sideEffects.append(contentsOf: flow.sideEffects)
            dependencies.formUnion(newDeps)
        }

        outputs.remove(statement.variable)

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // MARK: - While Loop

    private func analyzeWhileLoop(
        _ statement: WhileLoop,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        let condVars = extractVariables(from: statement.condition)
        for varName in condVars {
            if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                dependencies.insert(varName)
            }
            inputs.insert(varName)
        }

        for bodyStatement in statement.body {
            let (flow, newDeps) = analyzeStatement(
                bodyStatement,
                builder: builder,
                definedSymbols: &definedSymbols,
                inMutableScope: true
            )
            inputs.formUnion(flow.inputs)
            outputs.formUnion(flow.outputs)
            sideEffects.append(contentsOf: flow.sideEffects)
            dependencies.formUnion(newDeps)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    /// A guarded block reads its condition and whatever its body
    /// reads; its body's bindings are conditional, so they are
    /// treated like a loop body's — visible, but produced under a
    /// guard (GitLab #516).
    private func analyzeWhenStatement(
        _ statement: WhenStatement,
        builder: SymbolTableBuilder,
        definedSymbols: inout Set<String>
    ) -> (DataFlowInfo, Set<String>) {
        var inputs: Set<String> = []
        var outputs: Set<String> = []
        var sideEffects: [String] = []
        var dependencies: Set<String> = []

        for varName in extractVariables(from: statement.condition) {
            if !definedSymbols.contains(varName) && !isKnownExternal(varName) {
                dependencies.insert(varName)
            }
            inputs.insert(varName)
        }

        for bodyStatement in statement.body {
            let (flow, newDeps) = analyzeStatement(
                bodyStatement,
                builder: builder,
                definedSymbols: &definedSymbols,
                inMutableScope: true
            )
            inputs.formUnion(flow.inputs)
            outputs.formUnion(flow.outputs)
            sideEffects.append(contentsOf: flow.sideEffects)
            dependencies.formUnion(newDeps)
        }

        return (
            DataFlowInfo(inputs: inputs, outputs: outputs, sideEffects: sideEffects),
            dependencies
        )
    }

    // MARK: - Dependency Verification

    /// Verifies that external dependencies are published by some feature set
    public func verifyDependencies(_ analyzed: AnalyzedFeatureSet, globalRegistry: GlobalSymbolRegistry) {
        for dependency in analyzed.dependencies {
            if globalRegistry.lookup(dependency) == nil {
                // A prebound name is already bound outside this source — the
                // REPL passes the session's variables, so `<feedback-text>`
                // from an earlier cell is there at run time. Reporting it as
                // unpublished is a false positive: nothing needs publishing,
                // and the advice ("add a <Publish> statement") is wrong for a
                // notebook. GitLab #689 passed preboundSymbols in for exactly
                // this reason but only `Publish` consulted them.
                if !preboundSymbols.contains(dependency)
                    && !isKnownExternal(dependency)
                    && !isDeclaredRuntimeProvided(dependency, in: analyzed.symbolTable) {
                    diagnostics.warning(
                        "External dependency '\(dependency)' is not published by any feature set",
                        hints: ["Consider adding a <Publish> statement or marking it as framework-provided"],
                        code: .unpublishedDependency
                    )
                }
            }
        }
    }

    // MARK: - Duplicate Feature Set Detection

    /// Detects duplicate feature set names
    public func detectDuplicateFeatureSetNames(_ featureSets: [FeatureSet]) {
        var seen: [String: SourceLocation] = [:]

        for featureSet in featureSets {
            let key: String
            if featureSet.name == "Application-End" {
                key = "\(featureSet.name):\(featureSet.businessActivity)"
            } else {
                key = featureSet.name
            }

            if let firstLocation = seen[key] {
                diagnostics.error(
                    "Duplicate feature set name '\(featureSet.name)'",
                    at: featureSet.span.start,
                    hints: [
                        "A feature set with this name was already defined at line \(firstLocation.line)",
                        "Each feature set must have a unique name"
                    ]
                )
            } else {
                seen[key] = featureSet.span.start
            }
        }
    }

    // MARK: - Aggregation Fusion Detection (ARO-0051)

    private func detectAggregationFusions(_ statements: [Statement]) -> [AggregationFusionGroup] {
        var reducesBySource: [String: [(index: Int, output: String, function: String, field: String?)]] = [:]

        for (index, statement) in statements.enumerated() {
            guard let aro = statement as? AROStatement,
                  aro.action.verb.lowercased() == "reduce" else {
                continue
            }

            let source = aro.object.noun.base
            let output = aro.result.base
            let (function, field) = parseAggregationFunction(aro)

            reducesBySource[source, default: []].append((index, output, function, field))
        }

        var fusions: [AggregationFusionGroup] = []

        for (source, reduces) in reducesBySource where reduces.count > 1 {
            let operations = reduces.map { AggregationOperation(output: $0.output, function: $0.function, field: $0.field) }
            let indices = reduces.map { $0.index }

            fusions.append(AggregationFusionGroup(
                source: source,
                operations: operations,
                statementIndices: indices
            ))
        }

        return fusions
    }

    private func parseAggregationFunction(_ statement: AROStatement) -> (function: String, field: String?) {
        if let aggregation = statement.queryModifiers.aggregation {
            return (aggregation.type.rawValue, aggregation.field)
        }

        if let typeAnnotation = statement.result.typeAnnotation {
            let lower = typeAnnotation.lowercased()
            if ["sum", "count", "avg", "min", "max", "first", "last"].contains(lower) {
                return (lower, nil)
            }
        }

        return ("unknown", nil)
    }

    // MARK: - Stream Consumer Detection (ARO-0051)

    private func detectStreamConsumers(_ dataFlows: [DataFlowInfo], statements: [Statement]) -> [StreamConsumerInfo] {
        var inputCounts: [String: [Int]] = [:]

        for (index, flow) in dataFlows.enumerated() {
            for input in flow.inputs {
                inputCounts[input, default: []].append(index)
            }
        }

        var consumers: [StreamConsumerInfo] = []

        for (variable, indices) in inputCounts where indices.count > 1 {
            if isKnownExternal(variable) { continue }

            consumers.append(StreamConsumerInfo(
                variable: variable,
                consumerCount: indices.count,
                consumerIndices: indices
            ))
        }

        return consumers
    }

    // MARK: - Expression Analysis

    /// Extracts variable names referenced in an expression
    private func extractVariables(from expression: any Expression) -> Set<String> {
        // #338: dispatch on the concrete node type via `ExpressionVisitor`
        // instead of an `as?` cast chain. `VariableCollector` reproduces the
        // old switch exactly — including that `ExistenceExpression` and
        // `TypeCheckExpression` recurse into their inner expression, and that
        // any node without a variable contribution yields the empty set (the
        // old `default: break`).
        expression.accept(VariableCollector())
    }

    /// Variable base-names referenced anywhere in an expression tree.
    ///
    /// Module-internal so other analyses that meet a bare expression — the
    /// for-each collection slot in `BodyMaterializationAnalyzer`, GitLab #519 —
    /// read variables the same way rather than growing a second walker. One
    /// had grown anyway: `VariableNameCollector` in `BodyMaterialization.swift`
    /// was this visitor transcribed, node for node, and is gone (GitLab #723).
    /// This is the module's only answer to "which names does this expression
    /// mention?".
    static func variables(in expression: any Expression) -> Set<String> {
        expression.accept(VariableCollector())
    }

    /// Collects the variable base-names referenced anywhere in an expression
    /// tree. Behaviour matches the previous `collectVariables` switch 1:1.
    struct VariableCollector: ExpressionVisitor {
        typealias Result = Set<String>

        func visit(_ node: LiteralExpression) -> Set<String> { [] }

        func visit(_ node: VariableRefExpression) -> Set<String> {
            [node.noun.base]
        }

        func visit(_ node: BinaryExpression) -> Set<String> {
            node.left.accept(self).union(node.right.accept(self))
        }

        func visit(_ node: UnaryExpression) -> Set<String> {
            node.operand.accept(self)
        }

        func visit(_ node: MemberAccessExpression) -> Set<String> {
            node.base.accept(self)
        }

        func visit(_ node: SubscriptExpression) -> Set<String> {
            node.base.accept(self).union(node.index.accept(self))
        }

        func visit(_ node: GroupedExpression) -> Set<String> {
            node.expression.accept(self)
        }

        func visit(_ node: ExistenceExpression) -> Set<String> {
            node.expression.accept(self)
        }

        func visit(_ node: TypeCheckExpression) -> Set<String> {
            node.expression.accept(self)
        }

        func visit(_ node: EmptinessCheckExpression) -> Set<String> {
            node.expression.accept(self)
        }

        func visit(_ node: ArrayLiteralExpression) -> Set<String> {
            var vars: Set<String> = []
            for element in node.elements {
                vars.formUnion(element.accept(self))
            }
            return vars
        }

        func visit(_ node: MapLiteralExpression) -> Set<String> {
            var vars: Set<String> = []
            for entry in node.entries {
                vars.formUnion(entry.value.accept(self))
            }
            return vars
        }

        func visit(_ node: InterpolatedStringExpression) -> Set<String> {
            var vars: Set<String> = []
            for part in node.parts {
                if case .interpolation(let expr) = part {
                    vars.formUnion(expr.accept(self))
                }
            }
            return vars
        }
    }

    // MARK: - Helper Predicates

    private func isInternalVariable(_ name: String) -> Bool {
        name.hasPrefix("_")
    }

    private static let rebindingVerbs: Set<String> = [
        "accept", "update", "modify", "change", "set",
        "merge", "combine", "join", "concat",
        "then", "assert",
        "clear", "show"
    ]

    private func isRebindingAllowed(_ verb: String) -> Bool {
        return Self.rebindingVerbs.contains(verb.lowercased())
    }

    /// Whether `name` is a framework-provided object rather than a user variable.
    ///
    /// Delegates to `SystemObjectCatalog`, which is the single source of truth
    /// shared with the rest of the toolchain. Keeping this list inline here is
    /// what let it drift from the runtime and produce false "used before
    /// definition" warnings on correct code (GitLab #478).
    func isKnownExternal(_ name: String) -> Bool {
        SystemObjectCatalog.isSystemObject(name)
    }

    /// True when the feature set declared this name with
    /// `Require … from the <framework>` or `… from the <environment>`.
    ///
    /// Both sources are supplied by the runtime, so the Require statement is
    /// itself the declaration `verifyDependencies` would otherwise ask for --
    /// its hint literally reads "consider … marking it as framework-provided".
    /// Warning anyway made the only statement that declares an external
    /// dependency the one statement that could not satisfy the check
    /// (GitLab #828).
    ///
    /// A Require naming a feature set is left alone: that one really does need
    /// someone to `Publish`, and saying so is the point of the warning.
    private func isDeclaredRuntimeProvided(_ name: String, in symbolTable: SymbolTable) -> Bool {
        guard let symbol = symbolTable.lookup(name) else { return false }
        guard case .extracted(let from) = symbol.source else { return false }
        return from == "\(RequireSource.framework)" || from == "\(RequireSource.environment)"
    }

    private static let serviceObjects: Set<String> = [
        "http-server", "socket-server", "file-monitor", "websocket-server",
        "connection", "server-connection", "client-connection",
        "file", "directory", "path",
        "application", "events", "shutdown-signal"
    ]

    private func isServiceObject(_ name: String) -> Bool {
        let lower = name.lowercased()
        if Self.serviceObjects.contains(lower) {
            return true
        }
        if lower.hasSuffix("-server") || lower.hasSuffix("-connection") || lower.hasSuffix("-monitor") {
            return true
        }
        return false
    }

    private static let sideEffectPatterns: Set<String> = [
        "http-server", "http-client", "server", "client",
        "file-monitor", "file-watcher",
        "database-connections", "database", "db-connection",
        "socket-server", "socket-client",
        "log-buffer", "cache",
        "application"
    ]

    private func isSideEffectBinding(_ name: String) -> Bool {
        return Self.sideEffectPatterns.contains(name.lowercased())
    }

    /// The shared walk (GitLab #660), so side-effect, template-render and
    /// qualifier-base checks see every action in the feature set rather than
    /// only the top-level ones.
    ///
    /// This copy was the fullest of the three — it had grown range and while
    /// bodies as bugs found them — and still missed `when { }` blocks and
    /// pipelines. `AROStatementWalk` is a `StatementVisitor`, so the next AST
    /// node cannot be forgotten the same way.
    private func collectAROStatements(_ statements: [Statement]) -> [AROStatement] {
        AROStatementWalk.flatten(statements)
    }

    /// Verbs whose "result" is really just a confirmation handle for a
    /// side-effecting action — the value rarely needs reading because
    /// the point of the statement is what it *did*, not what it returns.
    private static let sideEffectVerbs: Set<String> = [
        "make", "append", "write", "copy", "move", "delete",
        "log", "emit", "send", "notify", "publish", "store",
        "schedule", "start", "stop", "listen", "keepalive",
        "render", "show", "repaint", "clear",
        "broadcast", "close", "connect",
        // ARO-0094 / GitLab #886. `Configure the <session: secure> with
        // false.` and `Configure the <cart-repository: scope> with
        // "session".` settle framework state and produce nothing anyone
        // reads, so "defined but never used" is noise on a statement that
        // did exactly its job. Same reason `configure` is in
        // `ActionRoleCatalog.mustRunForEffect`.
        "configure", "declare",

        // GitLab #823. Three more whose result is a confirmation handle:
        //
        // `Accept the <transition: draft_to_placed> on <order: status>.`
        // performs a state transition (ARO-0022); the binding is the
        // transition's name, and reading it afterwards is not a thing
        // anyone does — this warned on every `Accept` in the examples.
        //
        // `Sleep the <wait1> for 2 seconds.` is the delay. The whole
        // point is that nothing reads it — ARO-0088 keeps `Sleep` out of
        // the deferral allowlist for the same reason.
        //
        // `Exec`/`Execute`'s result is read often enough to keep, so it
        // is deliberately not here.
        "accept", "sleep", "delay", "pause", "wait"
    ]

    private func isSideEffectVerb(_ verb: String) -> Bool {
        let v = verb.lowercased()
        // Plugin / user-defined action calls (`Application.X`,
        // `MyPlugin.DoThing`) — these are dispatched by name and almost
        // always called for their effect.
        if v.contains(".") { return true }
        return Self.sideEffectVerbs.contains(v)
    }

    private func looksLikeVariable(_ name: String) -> Bool {
        if name.contains("-") {
            return true
        }
        if name == name.lowercased() && !name.isEmpty {
            return true
        }
        return false
    }
}
