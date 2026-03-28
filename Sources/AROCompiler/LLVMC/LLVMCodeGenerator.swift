// ============================================================
// LLVMCodeGenerator.swift
// ARO Compiler - LLVM Code Generator using Swifty-LLVM API
// ============================================================

#if !os(Windows)
import Foundation
import SwiftyLLVM
import AROParser

/// Result of LLVM code generation
public struct LLVMCodeGenerationResult {
    /// The generated LLVM IR text
    public let irText: String

    /// Path to the emitted file (if applicable)
    public var filePath: String?

    public init(irText: String, filePath: String? = nil) {
        self.irText = irText
        self.filePath = filePath
    }
}

/// LLVM Code Generator using the Swifty-LLVM API for type-safe IR generation
/// with source-location-aware error messages
public final class LLVMCodeGenerator {
    // MARK: - Components

    private var ctx: LLVMCodeGenContext!
    private var types: LLVMTypeMapper!
    private var externals: LLVMExternalDeclEmitter!

    // MARK: - State

    private var globalRuntime: GlobalVariable?
    /// Break target block for the innermost while loop (nil when not inside a loop)
    private var currentBreakBlock: BasicBlock?

    // MARK: - Initialization

    public init() {}

    // MARK: - Main Entry Point

    /// Generates LLVM IR for the given analyzed program
    /// - Parameters:
    ///   - program: The analyzed ARO program
    ///   - openAPISpecJSON: Optional OpenAPI specification as JSON string
    ///   - templatesJSON: Optional templates dictionary as JSON string (ARO-0050)
    ///   - embeddedPlugins: Optional array of plugin libraries to embed in the binary
    /// - Returns: Code generation result with IR text
    /// - Throws: LLVMCodeGenError if generation fails
    public func generate(
        program: AnalyzedProgram,
        openAPISpecJSON: String? = nil,
        templatesJSON: String? = nil,
        embeddedPlugins: [(name: String, yaml: String, base64Library: String)]? = nil
    ) throws -> LLVMCodeGenerationResult {
        // Initialize components
        ctx = LLVMCodeGenContext(moduleName: "aro_program")
        types = LLVMTypeMapper(context: ctx)
        externals = LLVMExternalDeclEmitter(context: ctx, types: types)

        // Set up module target
        setupModuleTarget()

        // Declare external functions
        externals.declareAllExternals()

        // Create global runtime variable
        createGlobalRuntime()

        // Validate entry point
        try validateEntryPoint(program)

        // Collect and emit string constants
        let stringCollector = StringConstantCollector(context: ctx)
        stringCollector.collect(from: program, openAPISpecJSON: openAPISpecJSON, templatesJSON: templatesJSON, embeddedPlugins: embeddedPlugins)

        // Generate feature set functions
        for analyzedFS in program.featureSets {
            generateFeatureSet(analyzedFS)
        }

        // Generate main function
        generateMainFunction(program: program, openAPISpecJSON: openAPISpecJSON, templatesJSON: templatesJSON, embeddedPlugins: embeddedPlugins)

        // Verify module
        try verifyModule()

        // Get IR text
        let irText = ctx.module.description

        return LLVMCodeGenerationResult(irText: irText)
    }

    // MARK: - Module Setup

    private func setupModuleTarget() {
        // Set target triple based on platform
        #if arch(arm64) && os(macOS)
        if let target = try? Target(triple: "arm64-apple-macosx14.0.0") {
            ctx.module.target = target
        }
        #elseif arch(x86_64) && os(macOS)
        if let target = try? Target(triple: "x86_64-apple-macosx14.0.0") {
            ctx.module.target = target
        }
        #elseif os(Linux) && arch(x86_64)
        if let target = try? Target(triple: "x86_64-unknown-linux-gnu") {
            ctx.module.target = target
        }
        #elseif os(Linux) && arch(arm64)
        if let target = try? Target(triple: "aarch64-unknown-linux-gnu") {
            ctx.module.target = target
        }
        #endif
    }

    private func createGlobalRuntime() {
        globalRuntime = ctx.module.addGlobalVariable("global_runtime", ctx.ptrType)
        ctx.module.setLinkage(.internal, for: globalRuntime!)
        // Initialize to null
        ctx.module.setInitializer(ctx.ptrType.null, for: globalRuntime!)
    }

    // MARK: - Validation

    private func validateEntryPoint(_ program: AnalyzedProgram) throws {
        let entryPoints = program.featureSets.filter {
            $0.featureSet.name == "Application-Start"
        }

        if entryPoints.isEmpty {
            throw LLVMCodeGenError.noEntryPoint
        }
        // Allow multiple Application-Start for module imports
        // The last one is the main application's entry point
    }

    private func verifyModule() throws {
        do {
            try ctx.module.verify()
        } catch {
            throw LLVMCodeGenError.moduleVerificationFailed(message: "\(error)")
        }
    }

    // MARK: - Feature Set Generation

    private func generateFeatureSet(_ analyzed: AnalyzedFeatureSet) {
        let fs = analyzed.featureSet
        // Use unique function name for Application-Start/End to support module imports
        // and avoid collisions between Success/Error variants
        let funcName: String
        if fs.name == "Application-Start" {
            funcName = applicationStartFunctionName(fs.businessActivity)
        } else if fs.name == "Application-End" {
            funcName = applicationEndFunctionName(fs.businessActivity)
        } else {
            funcName = featureSetFunctionName(fs.name)
        }

        // Create function
        let funcType = types.featureSetFunctionType
        let function = ctx.module.declareFunction(funcName, funcType)
        ctx.currentFunction = function

        // Create entry block
        let entryBlock = ctx.module.appendBlock(named: "entry", to: function)
        ctx.setInsertionPoint(atEndOf: entryBlock)

        // Get context parameter
        let ctxParam = function.parameters[0]
        ctx.currentContextVar = ctxParam

        // Allocate result storage — always in entry block via atEntryOf.
        let resultPtr = ctx.module.insertAlloca(ctx.ptrType, atEntryOf: function)
        ctx.currentResultPtr = resultPtr

        // Initialize result to null
        ctx.module.insertStore(ctx.ptrType.null, to: resultPtr, at: ctx.insertionPoint)

        // Feature-set-level when/where guard: if present, skip execution when condition is false.
        // This implements `(Name: Event Handler) where <event: field> == "value" { ... }`.
        // The guard is evaluated at runtime against the handler's context (which has event bound).
        if let guardCond = fs.whenCondition {
            let guardTrueBlock = ctx.module.appendBlock(named: "guard_true", to: function)
            let guardFalseBlock = ctx.module.appendBlock(named: "guard_false", to: function)

            let condJSON = ctx.stringConstant(serializeExpression(guardCond))
            let guardResult = ctx.module.insertCall(
                externals.evaluateWhenGuard,
                on: [ctxParam, condJSON],
                at: ctx.insertionPoint
            )
            let guardPassed = ctx.module.insertIntegerComparison(
                .ne, guardResult, ctx.i32Type.zero, at: ctx.insertionPoint
            )
            ctx.module.insertCondBr(if: guardPassed, then: guardTrueBlock, else: guardFalseBlock, at: ctx.insertionPoint)

            // Guard false: return null immediately (skip this handler)
            ctx.setInsertionPoint(atEndOf: guardFalseBlock)
            ctx.module.insertReturn(ctx.ptrType.null, at: ctx.insertionPoint)

            // Guard true: continue with body
            ctx.setInsertionPoint(atEndOf: guardTrueBlock)
        }

        // Create control flow blocks
        let normalReturnBlock = ctx.module.appendBlock(named: "normal_return", to: function)
        let errorExitBlock = ctx.module.appendBlock(named: "error_exit", to: function)

        // Generate statements
        for (index, statement) in fs.statements.enumerated() {
            ctx.currentSourceSpan = statement.span
            generateStatement(statement, index: index, errorBlock: errorExitBlock)
        }

        // Branch to normal return
        ctx.module.insertBr(to: normalReturnBlock, at: ctx.insertionPoint)

        // Normal return block
        ctx.setInsertionPoint(atEndOf: normalReturnBlock)
        let finalResult = ctx.module.insertLoad(ctx.ptrType, from: resultPtr, at: ctx.insertionPoint)
        ctx.module.insertReturn(finalResult, at: ctx.insertionPoint)

        // Error exit block
        ctx.setInsertionPoint(atEndOf: errorExitBlock)
        _ = ctx.module.insertCall(externals.contextPrintError, on: [ctxParam], at: ctx.insertionPoint)
        ctx.module.insertReturn(ctx.ptrType.null, at: ctx.insertionPoint)
    }

    private func featureSetFunctionName(_ name: String) -> String {
        let sanitized = name
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "aro_fs_\(sanitized)"
    }

    /// Generate unique function name for Application-Start using business activity
    private func applicationStartFunctionName(_ businessActivity: String) -> String {
        let sanitized = businessActivity
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "aro_fs_application_start_\(sanitized)"
    }

    /// Generate unique function name for Application-End using business activity
    private func applicationEndFunctionName(_ businessActivity: String) -> String {
        let sanitized = businessActivity
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "aro_fs_application_end_\(sanitized)"
    }

    // MARK: - Statement Generation

    private func generateStatement(_ statement: Statement, index: Int, errorBlock: BasicBlock) {
        switch statement {
        case let aroStatement as AROStatement:
            generateAROStatement(aroStatement, index: index, errorBlock: errorBlock)
        case let matchStatement as MatchStatement:
            generateMatchStatement(matchStatement, index: index, errorBlock: errorBlock)
        case let forEachLoop as ForEachLoop:
            generateForEachLoop(forEachLoop, index: index, errorBlock: errorBlock)
        case let rangeLoop as RangeLoop:
            generateRangeLoop(rangeLoop, index: index, errorBlock: errorBlock)
        case let whileLoop as WhileLoop:
            generateWhileLoop(whileLoop, index: index, errorBlock: errorBlock)
        case is BreakStatement:
            generateBreakStatement(index: index)
        case let publishStatement as PublishStatement:
            generatePublishStatement(publishStatement, index: index, errorBlock: errorBlock)
        case let requireStatement as RequireStatement:
            generateRequireStatement(requireStatement, index: index, errorBlock: errorBlock)
        default:
            // Unsupported statement type
            ctx.recordError(.invalidExpression(
                description: "Unsupported statement type",
                span: statement.span
            ))
        }
    }

    private func generateAROStatement(_ statement: AROStatement, index: Int, errorBlock: BasicBlock) {
        let prefix = "s\(index)"
        let ip = ctx.insertionPoint

        // Track merge block for when guard
        var guardMergeBlock: BasicBlock?

        // Handle when guard if present
        if let condition = statement.statementGuard.condition {
            let skipBlock = ctx.module.appendBlock(named: "\(prefix)_skip", to: ctx.currentFunction!)
            let bodyBlock = ctx.module.appendBlock(named: "\(prefix)_body", to: ctx.currentFunction!)
            let mergeBlock = ctx.module.appendBlock(named: "\(prefix)_merge", to: ctx.currentFunction!)

            guardMergeBlock = mergeBlock

            // Evaluate guard condition
            let conditionJSON = ctx.stringConstant(serializeExpression(condition))
            let guardResult = ctx.module.insertCall(
                externals.evaluateWhenGuard,
                on: [ctx.currentContextVar!, conditionJSON],
                at: ip
            )

            // Check if guard passed
            let guardPassed = ctx.module.insertIntegerComparison(
                .ne, guardResult, ctx.i32Type.zero, at: ip
            )

            ctx.module.insertCondBr(if: guardPassed, then: bodyBlock, else: skipBlock, at: ip)

            // Add terminator to skip block - branch directly to merge
            ctx.setInsertionPoint(atEndOf: skipBlock)
            ctx.module.insertBr(to: mergeBlock, at: ctx.insertionPoint)

            // Continue in body block
            ctx.setInsertionPoint(atEndOf: bodyBlock)
        }

        // Build result descriptor
        let resultDesc = buildResultDescriptor(statement.result, prefix: prefix)

        // Build object descriptor
        let objectDesc = buildObjectDescriptor(statement.object, prefix: prefix)

        // Clear transient query modifiers before binding fresh ones (mirrors FeatureSetExecutor lines 248-256)
        // Without this, where/by bindings from earlier Retrieve calls persist and contaminate
        // subsequent Retrieve calls (e.g. "Retrieve all" after "Retrieve where key = X" would
        // incorrectly still filter by key = X).
        for transientKey in ["_where_field_", "_where_op_", "_where_value_", "_by_pattern_", "_by_flags_",
                             "_aggregation_type_", "_aggregation_field_", "_default_value_"] {
            let keyStr = ctx.stringConstant(transientKey)
            _ = ctx.module.insertCall(externals.variableUnbind, on: [ctx.currentContextVar!, keyStr], at: ctx.insertionPoint)
        }

        // Bind query modifiers if present
        bindQueryModifiers(statement.queryModifiers)

        // Bind range modifiers if present
        bindRangeModifiers(statement.rangeModifiers)

        // Bind value source if present
        bindValueSource(statement.valueSource, prefix: prefix)

        // Call action function
        let verb = statement.action.verb.lowercased()
        let actionResult: IRValue

        if let actionFunc = externals.actionFunction(for: verb) {
            // Known built-in action
            actionResult = ctx.module.insertCall(
                actionFunc,
                on: [ctx.currentContextVar!, resultDesc, objectDesc],
                at: ctx.insertionPoint
            )
        } else {
            // Unknown verb - use dynamic action for plugin-provided custom actions
            let verbStr = ctx.stringConstant(verb)
            actionResult = ctx.module.insertCall(
                externals.actionDynamic,
                on: [verbStr, ctx.currentContextVar!, resultDesc, objectDesc],
                at: ctx.insertionPoint
            )
        }

        // Free the PREVIOUS result box before overwriting resultPtr.
        // aro_value_free handles null safely (initial value is null).
        // The final result stored here is returned by the function and freed by the caller.
        let prevResult = ctx.module.insertLoad(ctx.ptrType, from: ctx.currentResultPtr!, at: ctx.insertionPoint)
        _ = ctx.module.insertCall(externals.valueFree, on: [prevResult], at: ctx.insertionPoint)

        // Store new result
        ctx.module.insertStore(actionResult, to: ctx.currentResultPtr!, at: ctx.insertionPoint)

        // Check for action errors - halt execution if any action fails
        // This matches interpreter behavior where errors stop execution
        let hasError = ctx.module.insertCall(
            externals.contextHasError,
            on: [ctx.currentContextVar!],
            at: ctx.insertionPoint
        )
        let errorOccurred = ctx.module.insertIntegerComparison(
            .ne, hasError, ctx.i32Type.zero, at: ctx.insertionPoint
        )

        let continueBlock = ctx.module.appendBlock(
            named: "\(prefix)_continue",
            to: ctx.currentFunction!
        )

        ctx.module.insertCondBr(
            if: errorOccurred,
            then: errorBlock,
            else: continueBlock,
            at: ctx.insertionPoint
        )

        ctx.setInsertionPoint(atEndOf: continueBlock)

        // If we had a when guard, branch to merge block and continue from there
        if let mergeBlock = guardMergeBlock {
            ctx.module.insertBr(to: mergeBlock, at: ctx.insertionPoint)
            ctx.setInsertionPoint(atEndOf: mergeBlock)
        }
    }

    // MARK: - Descriptor Building

    private func buildResultDescriptor(_ result: QualifiedNoun, prefix: String) -> IRValue {
        let ip = ctx.insertionPoint
        let descType = types.resultDescriptorType

        // Hoist alloca to function entry block so it is a *static* stack allocation
        // (allocated once at function entry). Allocas in loop-body blocks are "dynamic"
        // in LLVM at -O0: they grow the stack on every iteration and cause SIGBUS after
        // ~30 k files when the 8 MB thread stack overflows.
        let descPtr = ctx.module.insertAlloca(descType, atEntryOf: ctx.currentFunction!)

        // Fill in the struct fields at the current (body) insertion point.
        let baseStr = ctx.stringConstant(result.base)
        let basePtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 0, at: ip
        )
        ctx.module.insertStore(baseStr, to: basePtr, at: ip)

        let specsPtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 1, at: ip
        )

        if result.specifiers.isEmpty {
            ctx.module.insertStore(ctx.ptrType.null, to: specsPtr, at: ip)
        } else {
            let arrayType = types.pointerArrayType(count: result.specifiers.count)
            let arrayPtr = ctx.module.insertAlloca(arrayType, atEntryOf: ctx.currentFunction!)

            for (i, spec) in result.specifiers.enumerated() {
                let specStr = ctx.stringConstant(spec)
                let elemPtr = ctx.module.insertGetElementPointer(
                    of: arrayPtr,
                    typed: arrayType,
                    indices: [ctx.i32Type.zero, ctx.i32Type.constant(i)],
                    at: ip
                )
                ctx.module.insertStore(specStr, to: elemPtr, at: ip)
            }

            ctx.module.insertStore(arrayPtr, to: specsPtr, at: ip)
        }

        let countPtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 2, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.constant(result.specifiers.count), to: countPtr, at: ip)

        return descPtr
    }

    private func buildObjectDescriptor(_ object: ObjectClause, prefix: String) -> IRValue {
        let ip = ctx.insertionPoint
        let descType = types.objectDescriptorType

        let descPtr = ctx.module.insertAlloca(descType, atEntryOf: ctx.currentFunction!)

        let baseStr = ctx.stringConstant(object.noun.base)
        let basePtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 0, at: ip
        )
        ctx.module.insertStore(baseStr, to: basePtr, at: ip)

        let prepPtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 1, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.constant(LLVMTypeMapper.prepositionValue(object.preposition)), to: prepPtr, at: ip)

        let specsPtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 2, at: ip
        )

        let specifiers = object.noun.specifiers
        if specifiers.isEmpty {
            ctx.module.insertStore(ctx.ptrType.null, to: specsPtr, at: ip)
        } else {
            let arrayType = types.pointerArrayType(count: specifiers.count)
            let arrayPtr = ctx.module.insertAlloca(arrayType, atEntryOf: ctx.currentFunction!)

            for (i, spec) in specifiers.enumerated() {
                let specStr = ctx.stringConstant(spec)
                let elemPtr = ctx.module.insertGetElementPointer(
                    of: arrayPtr,
                    typed: arrayType,
                    indices: [ctx.i32Type.zero, ctx.i32Type.constant(i)],
                    at: ip
                )
                ctx.module.insertStore(specStr, to: elemPtr, at: ip)
            }

            ctx.module.insertStore(arrayPtr, to: specsPtr, at: ip)
        }

        let countPtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 3, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.constant(specifiers.count), to: countPtr, at: ip)

        return descPtr
    }

    // MARK: - Value Source Binding

    private func bindValueSource(_ valueSource: ValueSource, prefix: String) {
        let ip = ctx.insertionPoint

        switch valueSource {
        case .none:
            // No binding needed
            break

        case .literal(let literal):
            bindLiteral(literal)

        case .expression(let expr):
            // Serialize expression (with constant folding if applicable)
            let exprJSON = ctx.stringConstant(serializeExpression(expr))
            _ = ctx.module.insertCall(
                externals.evaluateExpression,
                on: [ctx.currentContextVar!, exprJSON],
                at: ip
            )

        case .sinkExpression(let expr):
            // Sink expression: evaluate and bind to _result_expression_ for LogAction/response actions
            // Constant folding happens in serializeExpression (GitLab #102)
            let resultExprName = ctx.stringConstant("_result_expression_")
            let exprJSON = ctx.stringConstant(serializeExpression(expr))
            _ = ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, resultExprName, exprJSON],
                at: ip
            )
        }
    }

    // MARK: - Query and Range Modifiers Binding

    private func bindQueryModifiers(_ modifiers: QueryModifiers) {
        guard !modifiers.isEmpty else { return }
        let ip = ctx.insertionPoint

        // Bind where clause if present
        if let whereClause = modifiers.whereClause {
            // Bind _where_field_
            let fieldName = ctx.stringConstant("_where_field_")
            let fieldValue = ctx.stringConstant(whereClause.field)
            _ = ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, fieldName, fieldValue],
                at: ip
            )

            // Bind _where_op_
            let opName = ctx.stringConstant("_where_op_")
            let opValue = ctx.stringConstant(whereClause.op.rawValue)
            _ = ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, opName, opValue],
                at: ip
            )

            // Bind _where_value_ by evaluating the expression
            let valueName = ctx.stringConstant("_where_value_")
            let valueJSON = ctx.stringConstant(serializeExpression(whereClause.value))
            _ = ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, valueName, valueJSON],
                at: ip
            )
        }

        // Bind aggregation clause if present
        if let aggregation = modifiers.aggregation {
            // Bind _aggregation_type_
            let typeName = ctx.stringConstant("_aggregation_type_")
            let typeValue = ctx.stringConstant(aggregation.type.rawValue)
            _ = ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, typeName, typeValue],
                at: ip
            )

            // Bind _aggregation_field_ (can be nil for count())
            let fieldName = ctx.stringConstant("_aggregation_field_")
            let fieldValue = ctx.stringConstant(aggregation.field ?? "")
            _ = ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, fieldName, fieldValue],
                at: ip
            )
        }

        // Bind by clause if present (for Split action with regex)
        if let byClause = modifiers.byClause {
            // Bind _by_pattern_
            let patternName = ctx.stringConstant("_by_pattern_")
            let patternValue = ctx.stringConstant(byClause.pattern)
            _ = ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, patternName, patternValue],
                at: ip
            )

            // Bind _by_flags_
            let flagsName = ctx.stringConstant("_by_flags_")
            let flagsValue = ctx.stringConstant(byClause.flags)
            _ = ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, flagsName, flagsValue],
                at: ip
            )
        }

        // Bind default value if present (for optional retrieve with fallback)
        if let defaultExpr = modifiers.defaultValue {
            let defaultName = ctx.stringConstant("_default_value_")
            let defaultJSON = ctx.stringConstant(serializeExpression(defaultExpr))
            _ = ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, defaultName, defaultJSON],
                at: ip
            )
        }
    }

    private func bindRangeModifiers(_ modifiers: RangeModifiers) {
        guard !modifiers.isEmpty else { return }
        let ip = ctx.insertionPoint

        // Bind to clause if present (e.g., date range end) - evaluate expression
        if let toClause = modifiers.toClause {
            let toName = ctx.stringConstant("_to_")
            let toJSON = ctx.stringConstant(serializeExpression(toClause))
            _ = ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, toName, toJSON],
                at: ip
            )
        }

        // Bind with clause if present (e.g., set operations) - evaluate expression
        if let withClause = modifiers.withClause {
            let withName = ctx.stringConstant("_with_")
            let withJSON = ctx.stringConstant(serializeExpression(withClause))
            _ = ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, withName, withJSON],
                at: ip
            )
        }
    }

    private func bindLiteral(_ literal: LiteralValue) {
        let ip = ctx.insertionPoint
        let literalVar = ctx.stringConstant("_literal_")

        switch literal {
        case .string(let value):
            let valueStr = ctx.stringConstant(value)
            _ = ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, literalVar, valueStr],
                at: ip
            )

        case .integer(let value):
            _ = ctx.module.insertCall(
                externals.variableBindInt,
                on: [ctx.currentContextVar!, literalVar, ctx.i64Type.constant(value)],
                at: ip
            )

        case .float(let value):
            _ = ctx.module.insertCall(
                externals.variableBindDouble,
                on: [ctx.currentContextVar!, literalVar, ctx.doubleType.constant(value)],
                at: ip
            )

        case .boolean(let value):
            _ = ctx.module.insertCall(
                externals.variableBindBool,
                on: [ctx.currentContextVar!, literalVar, ctx.i32Type.constant(value ? 1 : 0)],
                at: ip
            )

        case .null:
            // Bind null as empty string or skip
            break

        case .array(let elements):
            // Serialize array as plain JSON (not expression-wrapped) for variableBindArray
            let json = serializeLiteralArrayPlain(elements)
            let jsonStr = ctx.stringConstant(json)
            _ = ctx.module.insertCall(
                externals.variableBindArray,
                on: [ctx.currentContextVar!, literalVar, jsonStr],
                at: ip
            )

        case .object(let entries):
            // Serialize object as plain JSON (not expression-wrapped) for variableBindDict
            let json = serializeLiteralObjectPlain(entries)
            let jsonStr = ctx.stringConstant(json)
            _ = ctx.module.insertCall(
                externals.variableBindDict,
                on: [ctx.currentContextVar!, literalVar, jsonStr],
                at: ip
            )

        case .regex(let pattern, let flags):
            // Bind regex as pattern string
            let regexStr = ctx.stringConstant("/\(pattern)/\(flags)")
            _ = ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, literalVar, regexStr],
                at: ip
            )
        }
    }

    // MARK: - Expression Serialization

    private func serializeExpression(_ expr: any AROParser.Expression) -> String {
        // GitLab #102: Constant folding optimization
        // If the expression is entirely constant, evaluate it at compile time
        if ConstantFolder.isConstant(expr), let value = ConstantFolder.evaluate(expr) {
            return serializeLiteralValue(value)
        }

        if let literal = expr as? LiteralExpression {
            return serializeLiteralValue(literal.value)
        } else if let ref = expr as? VariableRefExpression {
            return serializeVariableRef(ref)
        } else if let binary = expr as? BinaryExpression {
            return """
            {"$binary":{"op":"\(binary.op.rawValue)","left":\(serializeExpression(binary.left)),"right":\(serializeExpression(binary.right))}}
            """
        } else if let unary = expr as? UnaryExpression {
            return """
            {"$unary":{"op":"\(unary.op.rawValue)","operand":\(serializeExpression(unary.operand))}}
            """
        } else if let interpolated = expr as? InterpolatedStringExpression {
            return serializeInterpolatedString(interpolated.parts)
        } else if let array = expr as? ArrayLiteralExpression {
            return serializeArrayLiteral(array.elements)
        } else if let map = expr as? MapLiteralExpression {
            return serializeMapLiteral(map.entries)
        } else if let member = expr as? MemberAccessExpression {
            return """
            {"$member":{"base":\(serializeExpression(member.base)),"member":"\(member.member)"}}
            """
        } else if let subscript_ = expr as? SubscriptExpression {
            return """
            {"$subscript":{"base":\(serializeExpression(subscript_.base)),"index":\(serializeExpression(subscript_.index))}}
            """
        } else if let grouped = expr as? GroupedExpression {
            return serializeExpression(grouped.expression)
        } else if let existence = expr as? ExistenceExpression {
            return """
            {"$exists":\(serializeExpression(existence.expression))}
            """
        } else if let typeCheck = expr as? TypeCheckExpression {
            return """
            {"$typeCheck":{"expr":\(serializeExpression(typeCheck.expression)),"type":"\(typeCheck.typeName)"}}
            """
        }
        return "{\"$unknown\":true}"
    }

    private func serializeLiteralValue(_ lit: LiteralValue) -> String {
        switch lit {
        case .string(let s):
            return "{\"$lit\":\"\(escapeJSON(s))\"}"
        case .integer(let i):
            return "{\"$lit\":\(i)}"
        case .float(let f):
            return "{\"$lit\":\(f)}"
        case .boolean(let b):
            return "{\"$lit\":\(b)}"
        case .null:
            return "{\"$lit\":null}"
        case .array(let elements):
            return serializeLiteralArray(elements)
        case .object(let entries):
            return serializeLiteralObject(entries)
        case .regex(let pattern, let flags):
            return "{\"$regex\":{\"pattern\":\"\(escapeJSON(pattern))\",\"flags\":\"\(flags)\"}}"
        }
    }

    private func serializeVariableRef(_ ref: VariableRefExpression) -> String {
        var result = "{\"$var\":\"\(ref.noun.base)\""
        if !ref.noun.specifiers.isEmpty {
            let specs = ref.noun.specifiers.map { "\"\($0)\"" }.joined(separator: ",")
            result += ",\"$specs\":[\(specs)]"
        }
        result += "}"
        return result
    }

    private func serializeInterpolatedString(_ parts: [StringPart]) -> String {
        var template = ""
        for part in parts {
            switch part {
            case .literal(let s):
                template += escapeJSON(s)
            case .interpolation(let expr):
                // Serialize the expression and embed it
                if let varRef = expr as? VariableRefExpression {
                    // Include specifiers for property access: <base: spec1: spec2>
                    if varRef.noun.specifiers.isEmpty {
                        template += "${<\(varRef.noun.base)>}"
                    } else {
                        let specifiers = varRef.noun.specifiers.joined(separator: ": ")
                        template += "${<\(varRef.noun.base): \(specifiers)>}"
                    }
                } else {
                    template += "${...}"
                }
            }
        }
        return "{\"$interpolated\":\"\(template)\"}"
    }

    private func serializeArrayLiteral(_ elements: [any AROParser.Expression]) -> String {
        let serialized = elements.map { serializeExpression($0) }.joined(separator: ",")
        return "[\(serialized)]"
    }

    private func serializeMapLiteral(_ entries: [MapEntry]) -> String {
        let serialized = entries.map { entry in
            "\"\(escapeJSON(entry.key))\":\(serializeExpression(entry.value))"
        }.joined(separator: ",")
        return "{\(serialized)}"
    }

    private func serializeLiteralArray(_ elements: [LiteralValue]) -> String {
        let serialized = elements.map { serializeLiteralValue($0) }.joined(separator: ",")
        return "[\(serialized)]"
    }

    private func serializeLiteralObject(_ entries: [(String, LiteralValue)]) -> String {
        let serialized = entries.map { key, value in
            "\"\(escapeJSON(key))\":\(serializeLiteralValue(value))"
        }.joined(separator: ",")
        return "{\(serialized)}"
    }

    // Plain JSON serialization (no $lit wrappers) for variableBindDict/variableBindArray
    private func serializeLiteralValuePlain(_ lit: LiteralValue) -> String {
        switch lit {
        case .string(let s):
            return "\"\(escapeJSON(s))\""
        case .integer(let i):
            return "\(i)"
        case .float(let f):
            return "\(f)"
        case .boolean(let b):
            return "\(b)"
        case .null:
            return "null"
        case .array(let elements):
            return serializeLiteralArrayPlain(elements)
        case .object(let entries):
            return serializeLiteralObjectPlain(entries)
        case .regex(let pattern, let flags):
            return "\"/\(escapeJSON(pattern))/\(flags)\""
        }
    }

    private func serializeLiteralArrayPlain(_ elements: [LiteralValue]) -> String {
        let serialized = elements.map { serializeLiteralValuePlain($0) }.joined(separator: ",")
        return "[\(serialized)]"
    }

    private func serializeLiteralObjectPlain(_ entries: [(String, LiteralValue)]) -> String {
        let serialized = entries.map { key, value in
            "\"\(escapeJSON(key))\":\(serializeLiteralValuePlain(value))"
        }.joined(separator: ",")
        return "{\(serialized)}"
    }

    private func escapeJSON(_ s: String) -> String {
        var result = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x5C: result += "\\\\"          // backslash
            case 0x22: result += "\\\""          // double quote
            case 0x0A: result += "\\n"           // newline
            case 0x0D: result += "\\r"           // carriage return
            case 0x09: result += "\\t"           // tab
            case 0x00..<0x20:                    // other control characters (incl. ESC 0x1B)
                result += String(format: "\\u%04x", scalar.value)
            default:
                result += String(scalar)
            }
        }
        return result
    }

    // MARK: - Control Flow (Stubs)

    private func generateMatchStatement(_ statement: MatchStatement, index: Int, errorBlock: BasicBlock) {
        let prefix = "match\(index)"

        // Create end block for after the match
        let endBlock = ctx.module.appendBlock(named: "\(prefix)_end", to: ctx.currentFunction!)

        // Create subject JSON for pattern matching
        let subjectJSON = ctx.stringConstant(serializeMatchSubject(statement.subject))

        // Generate code for each case
        for (caseIndex, caseClause) in statement.cases.enumerated() {
            let casePrefix = "\(prefix)_case\(caseIndex)"

            // Create blocks for this case
            let caseBodyBlock = ctx.module.appendBlock(named: "\(casePrefix)_body", to: ctx.currentFunction!)
            let caseNextBlock = ctx.module.appendBlock(named: "\(casePrefix)_next", to: ctx.currentFunction!)

            // Evaluate if pattern matches
            let patternJSON = ctx.stringConstant(serializePattern(caseClause.pattern))
            let matchResult = ctx.module.insertCall(
                externals.matchPattern,
                on: [ctx.currentContextVar!, subjectJSON, patternJSON],
                at: ctx.insertionPoint
            )

            // Check if matched
            let matched = ctx.module.insertIntegerComparison(
                .ne, matchResult, ctx.i32Type.zero, at: ctx.insertionPoint
            )

            // Branch based on match result
            ctx.module.insertCondBr(if: matched, then: caseBodyBlock, else: caseNextBlock, at: ctx.insertionPoint)

            // Generate case body
            ctx.setInsertionPoint(atEndOf: caseBodyBlock)

            // Generate statements in the case body
            for (stmtIndex, stmt) in caseClause.body.enumerated() {
                generateStatement(stmt, index: index * 100 + caseIndex * 10 + stmtIndex, errorBlock: errorBlock)
            }

            // Branch to end after case body
            ctx.module.insertBr(to: endBlock, at: ctx.insertionPoint)

            // Continue from next block for subsequent cases
            ctx.setInsertionPoint(atEndOf: caseNextBlock)
        }

        // Handle otherwise clause if present
        if let otherwiseStmts = statement.otherwise {
            for (stmtIndex, stmt) in otherwiseStmts.enumerated() {
                generateStatement(stmt, index: index * 100 + statement.cases.count * 10 + stmtIndex, errorBlock: errorBlock)
            }
        }

        // Branch to end block
        ctx.module.insertBr(to: endBlock, at: ctx.insertionPoint)

        // Continue from end block
        ctx.setInsertionPoint(atEndOf: endBlock)
    }

    /// Serialize match subject to JSON
    private func serializeMatchSubject(_ subject: QualifiedNoun) -> String {
        let specsJSON = subject.specifiers.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",")
        return "{\"name\":\"\(escapeJSON(subject.base))\",\"specifiers\":[\(specsJSON)]}"
    }

    /// Serialize a pattern to JSON for match statement
    private func serializePattern(_ pattern: Pattern) -> String {
        switch pattern {
        case .literal(let literal):
            return "{\"type\":\"literal\",\"value\":\(serializePatternLiteral(literal))}"
        case .variable(let noun):
            return "{\"type\":\"variable\",\"name\":\"\(escapeJSON(noun.base))\"}"
        case .wildcard:
            return "{\"type\":\"wildcard\"}"
        case .regex(let patternStr, let flags):
            return "{\"type\":\"regex\",\"pattern\":\"\(escapeJSON(patternStr))\",\"flags\":\"\(escapeJSON(flags))\"}"
        }
    }

    /// Serialize a literal value to raw JSON (for pattern matching)
    private func serializePatternLiteral(_ literal: LiteralValue) -> String {
        switch literal {
        case .string(let s):
            return "\"\(escapeJSON(s))\""
        case .integer(let i):
            return "\(i)"
        case .float(let f):
            return "\(f)"
        case .boolean(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case .array(let elements):
            let items = elements.map { serializePatternLiteral($0) }.joined(separator: ",")
            return "[\(items)]"
        case .object(let entries):
            let items = entries.map { (key, value) in "\"\(escapeJSON(key))\":\(serializePatternLiteral(value))" }.joined(separator: ",")
            return "{\(items)}"
        case .regex(let pattern, let flags):
            return "{\"pattern\":\"\(escapeJSON(pattern))\",\"flags\":\"\(escapeJSON(flags))\"}"
        }
    }

    // MARK: - Loop Body Variable Collection

    /// Collects all variable names that will be bound by statements in the loop body.
    /// This is used to unbind them at the start of each iteration, simulating the
    /// child context behavior of the interpreter.
    private func collectBoundVariables(from statements: [any Statement]) -> Set<String> {
        var variables = Set<String>()
        for statement in statements {
            collectBoundVariablesFromStatement(statement, into: &variables)
        }
        return variables
    }

    private func collectBoundVariablesFromStatement(_ statement: any Statement, into variables: inout Set<String>) {
        if let aroStatement = statement as? AROStatement {
            // The result of an ARO statement is bound to a variable
            variables.insert(aroStatement.result.base)
        } else if let matchStatement = statement as? MatchStatement {
            // Recurse into match statement cases
            for caseClause in matchStatement.cases {
                for stmt in caseClause.body {
                    collectBoundVariablesFromStatement(stmt, into: &variables)
                }
            }
            if let otherwise = matchStatement.otherwise {
                for stmt in otherwise {
                    collectBoundVariablesFromStatement(stmt, into: &variables)
                }
            }
        } else if let forEachLoop = statement as? ForEachLoop {
            // The item and index variables are managed by the nested loop
            // But we still need to collect variables from the nested body
            for stmt in forEachLoop.body {
                collectBoundVariablesFromStatement(stmt, into: &variables)
            }
        } else if let rangeLoop = statement as? RangeLoop {
            // Range loop variable and body variables
            variables.insert(rangeLoop.variable)
            for stmt in rangeLoop.body {
                collectBoundVariablesFromStatement(stmt, into: &variables)
            }
        } else if let whileLoop = statement as? WhileLoop {
            // While loop variables are in the outer scope — collect them
            for stmt in whileLoop.body {
                collectBoundVariablesFromStatement(stmt, into: &variables)
            }
        }
        // PublishStatement, RequireStatement, and BreakStatement don't bind new variables
    }

    private func generateForEachLoop(_ loop: ForEachLoop, index: Int, errorBlock: BasicBlock) {
        let prefix = "foreach\(index)"

        // Create loop blocks
        let condBlock = ctx.module.appendBlock(named: "\(prefix)_cond", to: ctx.currentFunction!)
        let bodyBlock = ctx.module.appendBlock(named: "\(prefix)_body", to: ctx.currentFunction!)
        let incrBlock = ctx.module.appendBlock(named: "\(prefix)_incr", to: ctx.currentFunction!)
        let endBlock  = ctx.module.appendBlock(named: "\(prefix)_end",  to: ctx.currentFunction!)

        // Stream path: if the collection variable holds a lazy stream, use the callback-based
        // stream iterator (O(1) memory) instead of the index-based array loop.
        // Only applies when iterating a plain variable (no specifiers).
        //
        // When the stream dispatch is active, `collection` (from aro_variable_resolve) is only
        // defined in the array path. To satisfy LLVM dominance, we introduce a dedicated
        // `arrayEndBlock` that frees `collection` and then falls through to `endBlock`.
        // The stream path jumps directly to `endBlock` (no collection box to free).
        var arrayEndBlock: BasicBlock? = nil
        if loop.collection.specifiers.isEmpty {
            arrayEndBlock = ctx.module.appendBlock(named: "\(prefix)_aend", to: ctx.currentFunction!)

            let collVarName = ctx.stringConstant(loop.collection.base)
            let isStreamResult = ctx.module.insertCall(
                externals.isStream,
                on: [ctx.currentContextVar!, collVarName],
                at: ctx.insertionPoint
            )
            let isStreamBool = ctx.module.insertIntegerComparison(
                .ne, isStreamResult, ctx.i32Type.zero, at: ctx.insertionPoint
            )
            let streamPath = ctx.module.appendBlock(named: "\(prefix)_stream", to: ctx.currentFunction!)
            let arrayPath  = ctx.module.appendBlock(named: "\(prefix)_array",  to: ctx.currentFunction!)
            ctx.module.insertCondBr(if: isStreamBool, then: streamPath, else: arrayPath, at: ctx.insertionPoint)

            // === Stream path ===
            ctx.setInsertionPoint(atEndOf: streamPath)
            generateStreamForEachLoop(loop, index: index, endBlock: endBlock, errorBlock: errorBlock)

            // === Array path (fall-through to existing logic) ===
            ctx.setInsertionPoint(atEndOf: arrayPath)
        }

        // Resolve collection (with optional specifier for nested properties like <team: members>)
        let collectionName = ctx.stringConstant(loop.collection.base)
        var collection = ctx.module.insertCall(
            externals.variableResolve,
            on: [ctx.currentContextVar!, collectionName],
            at: ctx.insertionPoint
        )

        // Handle specifiers to access nested properties.
        // Each aro_dict_get call returns a NEW passRetained box wrapping the nested value,
        // making the previous box unreachable — free it before reassigning.
        for spec in loop.collection.specifiers {
            let specName = ctx.stringConstant(spec)
            let prevCollection = collection
            collection = ctx.module.insertCall(
                externals.dictGet,
                on: [collection, specName],
                at: ctx.insertionPoint
            )
            _ = ctx.module.insertCall(externals.valueFree, on: [prevCollection], at: ctx.insertionPoint)
        }

        // Iterator state: a stack-allocated i64 initialised to 0.
        // For arrays: aro_array_get_next uses it as a 0-based index.
        // For LazyDirectoryList: aro_array_get_next increments it as a monotonic counter;
        // the enumerator tracks the actual position internally.
        let statePtr = ctx.module.insertAlloca(ctx.i64Type, at: ctx.insertionPoint)
        ctx.module.insertStore(ctx.i64Type.zero, to: statePtr, at: ctx.insertionPoint)

        // If the caller wants a 0-based iteration index variable, track it separately.
        let iterIndexPtr: IRValue?
        if loop.indexVariable != nil {
            let p = ctx.module.insertAlloca(ctx.i64Type, at: ctx.insertionPoint)
            ctx.module.insertStore(ctx.i64Type.zero, to: p, at: ctx.insertionPoint)
            iterIndexPtr = p
        } else {
            iterIndexPtr = nil
        }

        // Jump to condition check
        ctx.module.insertBr(to: condBlock, at: ctx.insertionPoint)

        // === Condition Block ===
        // Call aro_array_get_next_ctx — context-aware cooperative variant that uses
        // PipelinedDirectoryIterator + driver channel for zero-overhead pipelined iteration.
        // Falls back to synchronous aro_array_get_next for eager arrays.
        ctx.setInsertionPoint(atEndOf: condBlock)

        let nextElem = ctx.module.insertCall(
            externals.arrayGetNextCtx,
            on: [ctx.currentContextVar!, collection, statePtr],
            at: ctx.insertionPoint
        )
        let isNull = ctx.module.insertIntegerComparison(
            .eq, nextElem, ctx.ptrType.null, at: ctx.insertionPoint
        )
        // When stream dispatch is active, jump to arrayEndBlock (frees collection) then endBlock.
        // Otherwise jump directly to endBlock (collection freed there, as before).
        let arrayDoneBlock = arrayEndBlock ?? endBlock
        ctx.module.insertCondBr(if: isNull, then: arrayDoneBlock, else: bodyBlock, at: ctx.insertionPoint)

        // === Body Block ===
        ctx.setInsertionPoint(atEndOf: bodyBlock)

        // Unbind and rebind item variable for this iteration
        let itemVarName = ctx.stringConstant(loop.itemVariable)
        _ = ctx.module.insertCall(
            externals.variableUnbind,
            on: [ctx.currentContextVar!, itemVarName],
            at: ctx.insertionPoint
        )
        _ = ctx.module.insertCall(
            externals.variableBindValue,
            on: [ctx.currentContextVar!, itemVarName, nextElem],
            at: ctx.insertionPoint
        )

        // Bind index variable if specified (0-based).
        // The boxed integer is freed immediately after binding — the inner Int value
        // was already copied into the context, so the AROCValue wrapper is not needed.
        if let indexVar = loop.indexVariable, let iterIndexPtr = iterIndexPtr {
            let indexVarName = ctx.stringConstant(indexVar)
            _ = ctx.module.insertCall(
                externals.variableUnbind,
                on: [ctx.currentContextVar!, indexVarName],
                at: ctx.insertionPoint
            )
            let curIterIdx = ctx.module.insertLoad(ctx.i64Type, from: iterIndexPtr, at: ctx.insertionPoint)
            let indexValue = ctx.module.insertCall(
                externals.valueCreateInt,
                on: [curIterIdx],
                at: ctx.insertionPoint
            )
            _ = ctx.module.insertCall(
                externals.variableBindValue,
                on: [ctx.currentContextVar!, indexVarName, indexValue],
                at: ctx.insertionPoint
            )
            // Free the passRetained box — the Int was extracted into the context by variableBindValue.
            _ = ctx.module.insertCall(externals.valueFree, on: [indexValue], at: ctx.insertionPoint)
        }

        // Check filter if present — failed filter jumps to incrBlock (freeing nextElem there)
        if let filter = loop.filter {
            let filterJSON = ctx.stringConstant(serializeExpression(filter))
            let filterResult = ctx.module.insertCall(
                externals.evaluateWhenGuard,
                on: [ctx.currentContextVar!, filterJSON],
                at: ctx.insertionPoint
            )
            let passed = ctx.module.insertIntegerComparison(
                .ne, filterResult, ctx.i32Type.zero, at: ctx.insertionPoint
            )
            let filterBodyBlock = ctx.module.appendBlock(named: "\(prefix)_filter_body", to: ctx.currentFunction!)
            ctx.module.insertCondBr(if: passed, then: filterBodyBlock, else: incrBlock, at: ctx.insertionPoint)
            ctx.setInsertionPoint(atEndOf: filterBodyBlock)
        }

        // Pre-unbind all body-bound variables to simulate child-context isolation,
        // allowing rebinding on each iteration. Item/index variables are excluded —
        // they are managed by the dedicated unbind+rebind code above.
        var managedByLoop = Set([loop.itemVariable])
        if let indexVar = loop.indexVariable { managedByLoop.insert(indexVar) }
        let bodyVariables = collectBoundVariables(from: loop.body)
        for varName in bodyVariables where !managedByLoop.contains(varName) {
            let varNameConst = ctx.stringConstant(varName)
            _ = ctx.module.insertCall(
                externals.variableUnbind,
                on: [ctx.currentContextVar!, varNameConst],
                at: ctx.insertionPoint
            )
        }

        // Generate body statements
        for (stmtIndex, stmt) in loop.body.enumerated() {
            generateStatement(stmt, index: index * 100 + stmtIndex, errorBlock: errorBlock)
        }

        // Branch to increment
        ctx.module.insertBr(to: incrBlock, at: ctx.insertionPoint)

        // === Increment Block ===
        ctx.setInsertionPoint(atEndOf: incrBlock)

        // Free the element box returned passRetained by aro_array_get_next.
        // The inner Swift value was already bound to the context; only the wrapper is released.
        _ = ctx.module.insertCall(externals.valueFree, on: [nextElem], at: ctx.insertionPoint)

        // Advance the iteration index (used for the user-facing index variable, if any).
        if let iterIndexPtr = iterIndexPtr {
            let cur = ctx.module.insertLoad(ctx.i64Type, from: iterIndexPtr, at: ctx.insertionPoint)
            let next = ctx.module.insertAdd(cur, ctx.i64Type.constant(1), at: ctx.insertionPoint)
            ctx.module.insertStore(next, to: iterIndexPtr, at: ctx.insertionPoint)
        }

        ctx.module.insertBr(to: condBlock, at: ctx.insertionPoint)

        // === Array End Block (only present when stream dispatch is active) ===
        // Frees `collection` before falling through to endBlock. This keeps `collection`
        // within the array-only control-flow path, satisfying LLVM dominance.
        if let aEnd = arrayEndBlock {
            ctx.setInsertionPoint(atEndOf: aEnd)
            _ = ctx.module.insertCall(externals.valueFree, on: [collection], at: ctx.insertionPoint)
            ctx.module.insertBr(to: endBlock, at: ctx.insertionPoint)
        }

        // === End Block ===
        ctx.setInsertionPoint(atEndOf: endBlock)

        // Free the collection box from aro_variable_resolve (or the final aro_dict_get).
        // Only inserted when there is no stream dispatch (array-only path); when stream
        // dispatch is active the free is done in arrayEndBlock above.
        if arrayEndBlock == nil {
            _ = ctx.module.insertCall(externals.valueFree, on: [collection], at: ctx.insertionPoint)
        }
    }

    // MARK: - Stream For-Each Loop Generation (lazy O(1) path)

    /// Generates a stream-based for-each loop that processes elements one at a time
    /// via a callback function, preserving O(1) memory usage.
    ///
    /// Creates a separate LLVM loop-body function and passes it to `aro_runtime_foreach_stream`,
    /// which drives iteration from within a Task while blocking the calling thread.
    private func generateStreamForEachLoop(
        _ loop: ForEachLoop,
        index: Int,
        endBlock: BasicBlock,
        errorBlock: BasicBlock
    ) {
        let prefix = "stream\(index)"

        // --- Build the loop body function ---
        let bodyFuncName = ctx.uniqueLoopBodyName()
        // signature: (ptr ctx, ptr element, i64 index) -> ptr
        let bodyFunc = ctx.module.declareFunction(bodyFuncName, types.loopBodyFunctionType)

        // Save outer function state
        let outerFunction   = ctx.currentFunction
        let outerContextVar = ctx.currentContextVar
        let outerResultPtr  = ctx.currentResultPtr
        let outerIP         = ctx.currentInsertionPoint

        // Switch to body function
        ctx.currentFunction = bodyFunc
        let bodyEntry = ctx.module.appendBlock(named: "entry", to: bodyFunc)
        ctx.setInsertionPoint(atEndOf: bodyEntry)

        let bodyCtxParam     = bodyFunc.parameters[0]  // ptr %ctx
        let bodyElementParam = bodyFunc.parameters[1]  // ptr %element
        let bodyIndexParam   = bodyFunc.parameters[2]  // i64 %index

        ctx.currentContextVar = bodyCtxParam

        // Allocate result storage for actions inside the body
        let bodyResultPtr = ctx.module.insertAlloca(ctx.ptrType, at: ctx.insertionPoint)
        ctx.module.insertStore(ctx.ptrType.null, to: bodyResultPtr, at: ctx.insertionPoint)
        ctx.currentResultPtr = bodyResultPtr

        // Error block: action failed → return null (error stored in context; caller checks it)
        let bodyErrorBlock = ctx.module.appendBlock(named: "\(prefix)_error", to: bodyFunc)
        ctx.setInsertionPoint(atEndOf: bodyErrorBlock)
        ctx.module.insertReturn(ctx.ptrType.null, at: ctx.insertionPoint)

        // Continue generating in the entry block
        ctx.setInsertionPoint(atEndOf: bodyEntry)

        // Bind item variable to current element
        let itemVarName = ctx.stringConstant(loop.itemVariable)
        _ = ctx.module.insertCall(externals.variableUnbind, on: [bodyCtxParam, itemVarName], at: ctx.insertionPoint)
        _ = ctx.module.insertCall(externals.variableBindValue, on: [bodyCtxParam, itemVarName, bodyElementParam], at: ctx.insertionPoint)

        // Bind index variable (if requested)
        if let indexVar = loop.indexVariable {
            let indexVarName = ctx.stringConstant(indexVar)
            _ = ctx.module.insertCall(externals.variableUnbind, on: [bodyCtxParam, indexVarName], at: ctx.insertionPoint)
            let indexValue = ctx.module.insertCall(externals.valueCreateInt, on: [bodyIndexParam], at: ctx.insertionPoint)
            _ = ctx.module.insertCall(externals.variableBindValue, on: [bodyCtxParam, indexVarName, indexValue], at: ctx.insertionPoint)
        }

        // Apply filter (if present)
        if let filter = loop.filter {
            let filterJSON = ctx.stringConstant(serializeExpression(filter))
            let filterResult = ctx.module.insertCall(
                externals.evaluateWhenGuard, on: [bodyCtxParam, filterJSON], at: ctx.insertionPoint)
            let passed = ctx.module.insertIntegerComparison(
                .ne, filterResult, ctx.i32Type.zero, at: ctx.insertionPoint)
            let filterBodyBlock = ctx.module.appendBlock(named: "\(prefix)_fb", to: bodyFunc)
            let filterSkipBlock = ctx.module.appendBlock(named: "\(prefix)_fs", to: bodyFunc)
            ctx.module.insertCondBr(if: passed, then: filterBodyBlock, else: filterSkipBlock, at: ctx.insertionPoint)
            // Skip: return null (continue iteration)
            ctx.setInsertionPoint(atEndOf: filterSkipBlock)
            ctx.module.insertReturn(ctx.ptrType.null, at: ctx.insertionPoint)
            ctx.setInsertionPoint(atEndOf: filterBodyBlock)
        }

        // Pre-unbind body variables (mirrors inline for-each behaviour)
        var managedByLoop = Set([loop.itemVariable])
        if let iv = loop.indexVariable { managedByLoop.insert(iv) }
        for varName in collectBoundVariables(from: loop.body) where !managedByLoop.contains(varName) {
            let vn = ctx.stringConstant(varName)
            _ = ctx.module.insertCall(externals.variableUnbind, on: [bodyCtxParam, vn], at: ctx.insertionPoint)
        }

        // Generate body statements (errors branch to bodyErrorBlock)
        for (stmtIndex, stmt) in loop.body.enumerated() {
            generateStatement(stmt, index: index * 100 + stmtIndex, errorBlock: bodyErrorBlock)
        }

        // Normal exit: return null (continue iteration)
        ctx.module.insertReturn(ctx.ptrType.null, at: ctx.insertionPoint)

        // --- Restore outer function state ---
        ctx.currentFunction    = outerFunction
        ctx.currentContextVar  = outerContextVar
        ctx.currentResultPtr   = outerResultPtr
        ctx.currentInsertionPoint = outerIP

        // --- Call aro_runtime_foreach_stream in the outer function ---
        let collVarName = ctx.stringConstant(loop.collection.base)
        _ = ctx.module.insertCall(
            externals.foreachStream,
            on: [ctx.currentContextVar!, collVarName, bodyFunc],
            at: ctx.insertionPoint
        )

        // After stream iteration: check for errors
        let hasError = ctx.module.insertCall(
            externals.contextHasError, on: [ctx.currentContextVar!], at: ctx.insertionPoint)
        let errorOccurred = ctx.module.insertIntegerComparison(
            .ne, hasError, ctx.i32Type.zero, at: ctx.insertionPoint)
        let continueBlock = ctx.module.appendBlock(named: "\(prefix)_cont", to: ctx.currentFunction!)
        ctx.module.insertCondBr(if: errorOccurred, then: errorBlock, else: continueBlock, at: ctx.insertionPoint)
        ctx.setInsertionPoint(atEndOf: continueBlock)

        // Jump to endBlock (shared with array path)
        ctx.module.insertBr(to: endBlock, at: ctx.insertionPoint)
    }

    // MARK: - Range Loop Generation (for <var> from <low> to <high>)

    private func generateRangeLoop(_ loop: RangeLoop, index: Int, errorBlock: BasicBlock) {
        let prefix = "range\(index)"

        // Create loop blocks
        let condBlock = ctx.module.appendBlock(named: "\(prefix)_cond", to: ctx.currentFunction!)
        let bodyBlock = ctx.module.appendBlock(named: "\(prefix)_body", to: ctx.currentFunction!)
        let incrBlock = ctx.module.appendBlock(named: "\(prefix)_incr", to: ctx.currentFunction!)
        let endBlock  = ctx.module.appendBlock(named: "\(prefix)_end",  to: ctx.currentFunction!)

        // Evaluate `from` and `to` expressions into temp variables
        let fromTempName = ctx.stringConstant("_rng_from_\(index)_")
        let toTempName   = ctx.stringConstant("_rng_to_\(index)_")

        let fromJSON = ctx.stringConstant(serializeExpression(loop.from))
        _ = ctx.module.insertCall(externals.evaluateAndBind, on: [ctx.currentContextVar!, fromTempName, fromJSON], at: ctx.insertionPoint)

        let toJSON = ctx.stringConstant(serializeExpression(loop.to))
        _ = ctx.module.insertCall(externals.evaluateAndBind, on: [ctx.currentContextVar!, toTempName, toJSON], at: ctx.insertionPoint)

        // Extract integer values into stack-allocated i64 storage
        let fromIntPtr = ctx.module.insertAlloca(ctx.i64Type, at: ctx.insertionPoint)
        let toIntPtr   = ctx.module.insertAlloca(ctx.i64Type, at: ctx.insertionPoint)
        ctx.module.insertStore(ctx.i64Type.zero, to: fromIntPtr, at: ctx.insertionPoint)
        ctx.module.insertStore(ctx.i64Type.zero, to: toIntPtr,   at: ctx.insertionPoint)
        _ = ctx.module.insertCall(externals.variableResolveInt, on: [ctx.currentContextVar!, fromTempName, fromIntPtr], at: ctx.insertionPoint)
        _ = ctx.module.insertCall(externals.variableResolveInt, on: [ctx.currentContextVar!, toTempName,   toIntPtr],   at: ctx.insertionPoint)

        let toInt   = ctx.module.insertLoad(ctx.i64Type, from: toIntPtr,   at: ctx.insertionPoint)
        let fromInt = ctx.module.insertLoad(ctx.i64Type, from: fromIntPtr, at: ctx.insertionPoint)

        // Allocate loop counter starting at fromInt
        let counterPtr = ctx.module.insertAlloca(ctx.i64Type, at: ctx.insertionPoint)
        ctx.module.insertStore(fromInt, to: counterPtr, at: ctx.insertionPoint)

        // Jump to condition check
        ctx.module.insertBr(to: condBlock, at: ctx.insertionPoint)

        // === Condition Block: loop while counter < toInt ===
        ctx.setInsertionPoint(atEndOf: condBlock)
        let curCount = ctx.module.insertLoad(ctx.i64Type, from: counterPtr, at: ctx.insertionPoint)
        let done = ctx.module.insertIntegerComparison(.sge, curCount, toInt, at: ctx.insertionPoint)
        ctx.module.insertCondBr(if: done, then: endBlock, else: bodyBlock, at: ctx.insertionPoint)

        // === Body Block ===
        ctx.setInsertionPoint(atEndOf: bodyBlock)

        let bodyCount = ctx.module.insertLoad(ctx.i64Type, from: counterPtr, at: ctx.insertionPoint)

        // Bind loop variable as boxed integer (unbind first to allow rebinding).
        // Free the box immediately after binding — the Int was extracted into the context.
        let varNameStr = ctx.stringConstant(loop.variable)
        _ = ctx.module.insertCall(externals.variableUnbind, on: [ctx.currentContextVar!, varNameStr], at: ctx.insertionPoint)
        let varValue = ctx.module.insertCall(externals.valueCreateInt, on: [bodyCount], at: ctx.insertionPoint)
        _ = ctx.module.insertCall(externals.variableBindValue, on: [ctx.currentContextVar!, varNameStr, varValue], at: ctx.insertionPoint)
        _ = ctx.module.insertCall(externals.valueFree, on: [varValue], at: ctx.insertionPoint)

        // Unbind all body-bound variables to allow rebinding on each iteration
        let bodyVars = collectBoundVariables(from: loop.body)
        for varName in bodyVars where varName != loop.variable {
            let bodyVarName = ctx.stringConstant(varName)
            _ = ctx.module.insertCall(externals.variableUnbind, on: [ctx.currentContextVar!, bodyVarName], at: ctx.insertionPoint)
        }

        // Generate body statements
        for (stmtIndex, stmt) in loop.body.enumerated() {
            generateStatement(stmt, index: index * 100 + stmtIndex, errorBlock: incrBlock)
        }

        // Branch to increment
        ctx.module.insertBr(to: incrBlock, at: ctx.insertionPoint)

        // === Increment Block ===
        ctx.setInsertionPoint(atEndOf: incrBlock)
        let nextCount = ctx.module.insertLoad(ctx.i64Type, from: counterPtr, at: ctx.insertionPoint)
        let incremented = ctx.module.insertAdd(nextCount, ctx.i64Type.constant(1), at: ctx.insertionPoint)
        ctx.module.insertStore(incremented, to: counterPtr, at: ctx.insertionPoint)
        ctx.module.insertBr(to: condBlock, at: ctx.insertionPoint)

        // === End Block ===
        ctx.setInsertionPoint(atEndOf: endBlock)
    }

    // MARK: - While Loop Generation (ARO-0131)

    private func generateWhileLoop(_ loop: WhileLoop, index: Int, errorBlock: BasicBlock) {
        let prefix = "while\(index)"

        // Create loop blocks
        let condBlock = ctx.module.appendBlock(named: "\(prefix)_cond", to: ctx.currentFunction!)
        let bodyBlock = ctx.module.appendBlock(named: "\(prefix)_body", to: ctx.currentFunction!)
        let endBlock  = ctx.module.appendBlock(named: "\(prefix)_end",  to: ctx.currentFunction!)

        // Enter mutable scope so variable rebinds are allowed inside the loop
        _ = ctx.module.insertCall(
            externals.enterMutableScope,
            on: [ctx.currentContextVar!],
            at: ctx.insertionPoint
        )

        // Jump to condition block
        ctx.module.insertBr(to: condBlock, at: ctx.insertionPoint)

        // === Condition Block ===
        ctx.setInsertionPoint(atEndOf: condBlock)

        let condJSON = ctx.stringConstant(serializeExpression(loop.condition))
        let condResult = ctx.module.insertCall(
            externals.evaluateWhenGuard,
            on: [ctx.currentContextVar!, condJSON],
            at: ctx.insertionPoint
        )
        let isTrue = ctx.module.insertIntegerComparison(
            .ne, condResult, ctx.i32Type.zero, at: ctx.insertionPoint
        )
        ctx.module.insertCondBr(if: isTrue, then: bodyBlock, else: endBlock, at: ctx.insertionPoint)

        // === Body Block ===
        ctx.setInsertionPoint(atEndOf: bodyBlock)

        // Push break target so inner BreakStatement knows where to jump
        let savedBreakBlock = currentBreakBlock
        currentBreakBlock = endBlock

        // Generate body statements
        for (stmtIndex, stmt) in loop.body.enumerated() {
            generateStatement(stmt, index: index * 100 + stmtIndex, errorBlock: errorBlock)
        }

        // Restore outer break target
        currentBreakBlock = savedBreakBlock

        // Loop back to condition (unless we already have a terminator)
        ctx.module.insertBr(to: condBlock, at: ctx.insertionPoint)

        // === End Block ===
        ctx.setInsertionPoint(atEndOf: endBlock)

        // Exit mutable scope
        _ = ctx.module.insertCall(
            externals.exitMutableScope,
            on: [ctx.currentContextVar!],
            at: ctx.insertionPoint
        )
    }

    private func generateBreakStatement(index: Int) {
        guard let breakBlock = currentBreakBlock else {
            ctx.recordError(.invalidExpression(
                description: "break used outside of while loop",
                span: SourceSpan.unknown
            ))
            return
        }

        // Exit mutable scope before jumping out
        _ = ctx.module.insertCall(
            externals.exitMutableScope,
            on: [ctx.currentContextVar!],
            at: ctx.insertionPoint
        )

        ctx.module.insertBr(to: breakBlock, at: ctx.insertionPoint)

        // Append an unreachable continuation block so remaining code has a home
        let contBlock = ctx.module.appendBlock(named: "break_cont\(index)", to: ctx.currentFunction!)
        ctx.setInsertionPoint(atEndOf: contBlock)
    }

    // MARK: - Publish Statement Generation

    private func generatePublishStatement(_ statement: PublishStatement, index: Int, errorBlock: BasicBlock) {
        let ip = ctx.insertionPoint

        // Bind the publish alias
        let aliasName = ctx.stringConstant("_publish_alias_")
        let aliasValue = ctx.stringConstant(statement.externalName)
        _ = ctx.module.insertCall(
            externals.variableBindString,
            on: [ctx.currentContextVar!, aliasName, aliasValue],
            at: ip
        )

        // Bind the internal variable name
        let varName = ctx.stringConstant("_publish_variable_")
        let varValue = ctx.stringConstant(statement.internalVariable)
        _ = ctx.module.insertCall(
            externals.variableBindString,
            on: [ctx.currentContextVar!, varName, varValue],
            at: ip
        )

        // Build result descriptor for the publish action
        let descType = types.resultDescriptorType
        let resultDesc = ctx.module.insertAlloca(descType, atEntryOf: ctx.currentFunction!)

        let baseStr = ctx.stringConstant(statement.externalName)
        let basePtr = ctx.module.insertGetStructElementPointer(
            of: resultDesc, typed: descType, index: 0, at: ip
        )
        ctx.module.insertStore(baseStr, to: basePtr, at: ip)

        // Specifiers = null
        let specsPtr = ctx.module.insertGetStructElementPointer(
            of: resultDesc, typed: descType, index: 1, at: ip
        )
        ctx.module.insertStore(ctx.ptrType.null, to: specsPtr, at: ip)

        // Count = 0
        let countPtr = ctx.module.insertGetStructElementPointer(
            of: resultDesc, typed: descType, index: 2, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.zero, to: countPtr, at: ip)

        // Build object descriptor for the internal variable
        let objDescType = types.objectDescriptorType
        let objectDesc = ctx.module.insertAlloca(objDescType, atEntryOf: ctx.currentFunction!)

        let objBaseStr = ctx.stringConstant(statement.internalVariable)
        let objBasePtr = ctx.module.insertGetStructElementPointer(
            of: objectDesc, typed: objDescType, index: 0, at: ip
        )
        ctx.module.insertStore(objBaseStr, to: objBasePtr, at: ip)

        // Preposition = from (0)
        let prepPtr = ctx.module.insertGetStructElementPointer(
            of: objectDesc, typed: objDescType, index: 1, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.zero, to: prepPtr, at: ip)

        // Specifiers = null
        let objSpecsPtr = ctx.module.insertGetStructElementPointer(
            of: objectDesc, typed: objDescType, index: 2, at: ip
        )
        ctx.module.insertStore(ctx.ptrType.null, to: objSpecsPtr, at: ip)

        // Count = 0
        let objCountPtr = ctx.module.insertGetStructElementPointer(
            of: objectDesc, typed: objDescType, index: 3, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.zero, to: objCountPtr, at: ip)

        // Call publish action
        if let publishFunc = externals.actionFunction(for: "publish") {
            let actionResult = ctx.module.insertCall(
                publishFunc,
                on: [ctx.currentContextVar!, resultDesc, objectDesc],
                at: ip
            )
            let prevResult = ctx.module.insertLoad(ctx.ptrType, from: ctx.currentResultPtr!, at: ip)
            _ = ctx.module.insertCall(externals.valueFree, on: [prevResult], at: ip)
            ctx.module.insertStore(actionResult, to: ctx.currentResultPtr!, at: ip)
        }
    }

    // MARK: - Require Statement Generation

    private func generateRequireStatement(_ statement: RequireStatement, index: Int, errorBlock: BasicBlock) {
        // Framework dependencies are auto-bound by the runtime (console, http-server, etc.)
        // and don't need extraction — matching interpreter behavior where .framework is a no-op.
        if case .framework = statement.source {
            return
        }

        let ip = ctx.insertionPoint

        // Bind the required variable name
        let varNameStr = ctx.stringConstant("_require_variable_")
        let varValue = ctx.stringConstant(statement.variableName)
        _ = ctx.module.insertCall(
            externals.variableBindString,
            on: [ctx.currentContextVar!, varNameStr, varValue],
            at: ip
        )

        // Bind the source type
        let sourceName = ctx.stringConstant("_require_source_")
        let sourceValue: String
        switch statement.source {
        case .framework:
            sourceValue = "framework" // unreachable due to early return above
        case .environment:
            sourceValue = "environment"
        case .featureSet(let name):
            sourceValue = name
        }
        let sourceStr = ctx.stringConstant(sourceValue)
        _ = ctx.module.insertCall(
            externals.variableBindString,
            on: [ctx.currentContextVar!, sourceName, sourceStr],
            at: ip
        )

        // Build result descriptor for the require action
        let descType = types.resultDescriptorType
        let resultDesc = ctx.module.insertAlloca(descType, atEntryOf: ctx.currentFunction!)

        let baseStr = ctx.stringConstant(statement.variableName)
        let basePtr = ctx.module.insertGetStructElementPointer(
            of: resultDesc, typed: descType, index: 0, at: ip
        )
        ctx.module.insertStore(baseStr, to: basePtr, at: ip)

        // Specifiers = null
        let specsPtr = ctx.module.insertGetStructElementPointer(
            of: resultDesc, typed: descType, index: 1, at: ip
        )
        ctx.module.insertStore(ctx.ptrType.null, to: specsPtr, at: ip)

        // Count = 0
        let countPtr = ctx.module.insertGetStructElementPointer(
            of: resultDesc, typed: descType, index: 2, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.zero, to: countPtr, at: ip)

        // Build object descriptor for the source
        let objDescType = types.objectDescriptorType
        let objectDesc = ctx.module.insertAlloca(objDescType, atEntryOf: ctx.currentFunction!)

        let objBaseStr = ctx.stringConstant(sourceValue)
        let objBasePtr = ctx.module.insertGetStructElementPointer(
            of: objectDesc, typed: objDescType, index: 0, at: ip
        )
        ctx.module.insertStore(objBaseStr, to: objBasePtr, at: ip)

        // Preposition = from (0)
        let prepPtr = ctx.module.insertGetStructElementPointer(
            of: objectDesc, typed: objDescType, index: 1, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.zero, to: prepPtr, at: ip)

        // Specifiers = null
        let objSpecsPtr = ctx.module.insertGetStructElementPointer(
            of: objectDesc, typed: objDescType, index: 2, at: ip
        )
        ctx.module.insertStore(ctx.ptrType.null, to: objSpecsPtr, at: ip)

        // Count = 0
        let objCountPtr = ctx.module.insertGetStructElementPointer(
            of: objectDesc, typed: objDescType, index: 3, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.zero, to: objCountPtr, at: ip)

        // Call require action (extract)
        if let extractFunc = externals.actionFunction(for: "extract") {
            let actionResult = ctx.module.insertCall(
                extractFunc,
                on: [ctx.currentContextVar!, resultDesc, objectDesc],
                at: ip
            )
            let prevResult = ctx.module.insertLoad(ctx.ptrType, from: ctx.currentResultPtr!, at: ip)
            _ = ctx.module.insertCall(externals.valueFree, on: [prevResult], at: ip)
            ctx.module.insertStore(actionResult, to: ctx.currentResultPtr!, at: ip)
        }
    }

    // MARK: - Main Function Generation

    private func generateMainFunction(program: AnalyzedProgram, openAPISpecJSON: String?, templatesJSON: String? = nil, embeddedPlugins: [(name: String, yaml: String, base64Library: String)]? = nil) {
        let mainFunc = ctx.module.declareFunction("main", types.mainFunctionType)

        let entryBlock = ctx.module.appendBlock(named: "entry", to: mainFunc)
        ctx.setInsertionPoint(atEndOf: entryBlock)
        let ip = ctx.insertionPoint

        // Initialize runtime
        let runtime = ctx.module.insertCall(externals.runtimeInit, on: [], at: ip)

        // Store runtime in global
        ctx.module.insertStore(runtime, to: globalRuntime!, at: ip)

        // Parse command-line arguments (ARO-0047)
        let argc = mainFunc.parameters[0]
        let argv = mainFunc.parameters[1]
        _ = ctx.module.insertCall(externals.parseArguments, on: [argc, argv], at: ip)

        // Set embedded OpenAPI spec if provided
        if let spec = openAPISpecJSON {
            let specStr = ctx.stringConstant(spec)
            _ = ctx.module.insertCall(externals.setEmbeddedOpenapi, on: [specStr], at: ip)
        }

        // Set embedded templates if provided (ARO-0050)
        if let templates = templatesJSON {
            let templatesStr = ctx.stringConstant(templates)
            _ = ctx.module.insertCall(externals.setEmbeddedTemplates, on: [templatesStr], at: ip)
        }

        // Register embedded plugins (base64-encoded .so files compiled into the binary)
        if let plugins = embeddedPlugins {
            for plugin in plugins {
                let nameStr = ctx.stringConstant(plugin.name)
                let yamlStr = ctx.stringConstant(plugin.yaml)
                let base64Str = ctx.stringConstant(plugin.base64Library)
                _ = ctx.module.insertCall(externals.registerEmbeddedPlugin, on: [nameStr, yamlStr, base64Str], at: ip)
            }
        }

        // Load precompiled plugins
        _ = ctx.module.insertCall(externals.loadPrecompiledPlugins, on: [], at: ip)

        // Register feature set metadata (name -> business activity) for HTTP routing
        for analyzed in program.featureSets {
            let fsName = ctx.stringConstant(analyzed.featureSet.name)
            let businessActivity = ctx.stringConstant(analyzed.featureSet.businessActivity)
            _ = ctx.module.insertCall(externals.registerFeatureSetMetadata, on: [fsName, businessActivity], at: ip)
        }

        // Register event handlers
        registerEventHandlers(program: program, runtime: runtime)

        // Find all Application-Start feature sets
        let appStartFeatureSets = program.featureSets.filter {
            $0.featureSet.name == "Application-Start"
        }

        // Variable to hold the main context (last Application-Start)
        var mainCtx: IRValue!

        // Call all Application-Start functions in order
        // Imported modules come first, main application comes last
        for (index, analyzed) in appStartFeatureSets.enumerated() {
            let isMain = (index == appStartFeatureSets.count - 1)
            let activity = analyzed.featureSet.businessActivity

            // Create context for this Application-Start
            let contextName = ctx.stringConstant(isMain ? "Application-Start" : "Application-Start:\(activity)")
            let appCtx = ctx.module.insertCall(
                externals.contextCreateNamed,
                on: [runtime, contextName],
                at: ip
            )

            // Call the Application-Start function
            let funcName = applicationStartFunctionName(activity)
            if let appStartFunc = ctx.module.function(named: funcName) {
                _ = ctx.module.insertCall(appStartFunc, on: [appCtx], at: ip)
            }

            // Keep main context for response printing, destroy imported module contexts
            if isMain {
                mainCtx = appCtx
            } else {
                _ = ctx.module.insertCall(externals.contextDestroy, on: [appCtx], at: ip)
            }
        }

        // Wait for pending events (10 second timeout)
        // Must complete BEFORE Application-End so all handlers finish first
        _ = ctx.module.insertCall(
            externals.runtimeAwaitPendingEvents,
            on: [runtime, ctx.doubleType.constant(10.0)],
            at: ip
        )

        // Execute Application-End: Success handler if defined
        let appEndSuccess = program.featureSets.first(where: {
            $0.featureSet.name == "Application-End" &&
            $0.featureSet.businessActivity == "Success"
        })
        if let endHandler = appEndSuccess {
            let endFuncName = applicationEndFunctionName(endHandler.featureSet.businessActivity)
            if let endFunc = ctx.module.function(named: endFuncName) {
                let endContextName = ctx.stringConstant("Application-End")
                let endCtx = ctx.module.insertCall(
                    externals.contextCreateNamed,
                    on: [runtime, endContextName],
                    at: ip
                )
                _ = ctx.module.insertCall(endFunc, on: [endCtx], at: ip)
                _ = ctx.module.insertCall(externals.contextDestroy, on: [endCtx], at: ip)
            }
        }

        // Print response (unless --keep-alive flag is set)
        let keepAliveFlag = ctx.module.insertCall(externals.hasKeepAlive, on: [], at: ip)
        let isNotKeepAlive = ctx.module.insertIntegerComparison(.eq, keepAliveFlag, ctx.i32Type.zero, at: ip)

        let printBlock = ctx.module.appendBlock(named: "print_response", to: mainFunc)
        let cleanupBlock = ctx.module.appendBlock(named: "cleanup", to: mainFunc)

        ctx.module.insertCondBr(if: isNotKeepAlive, then: printBlock, else: cleanupBlock, at: ip)

        // Print block
        ctx.setInsertionPoint(atEndOf: printBlock)
        let printIP = ctx.insertionPoint
        _ = ctx.module.insertCall(externals.contextPrintResponse, on: [mainCtx], at: printIP)
        ctx.module.insertBr(to: cleanupBlock, at: printIP)

        // Cleanup block
        ctx.setInsertionPoint(atEndOf: cleanupBlock)
        let cleanupIP = ctx.insertionPoint

        // Cleanup
        _ = ctx.module.insertCall(externals.contextDestroy, on: [mainCtx], at: cleanupIP)
        _ = ctx.module.insertCall(externals.runtimeShutdown, on: [runtime], at: cleanupIP)

        // Return success
        ctx.module.insertReturn(ctx.i32Type.zero, at: cleanupIP)
    }

    private func registerEventHandlers(program: AnalyzedProgram, runtime: IRValue) {
        let ip = ctx.insertionPoint

        for analyzed in program.featureSets {
            let activity = analyzed.featureSet.businessActivity

            // NotificationSent Handler — must be checked BEFORE generic hasSuffix(" Handler").
            // Serializes the feature set's `whenCondition` expression as JSON for runtime evaluation.
            if activity.contains("NotificationSent Handler") {
                let funcName = featureSetFunctionName(analyzed.featureSet.name)
                if let handlerFunc = ctx.module.function(named: funcName) {
                    // Serialize whenCondition as JSON, or pass "" (empty = no condition guard)
                    let conditionJSON: String
                    if let whenCondition = analyzed.featureSet.whenCondition {
                        conditionJSON = serializeExpression(whenCondition)
                    } else {
                        conditionJSON = ""
                    }
                    let whenConditionStr = ctx.stringConstant(conditionJSON)
                    _ = ctx.module.insertCall(
                        externals.registerNotificationHandler,
                        on: [runtime, handlerFunc, whenConditionStr],
                        at: ip
                    )
                }
                continue
            }

            // StateTransition Handler<guardKey:guardValue> — activity ends with ">" not " Handler"
            // Must be checked BEFORE the hasSuffix(" Handler") block.
            if activity.contains("StateTransition Handler<") {
                // Parse the guard: e.g. "StateTransition Handler<toState:submitted>"
                if let openBracket = activity.firstIndex(of: "<"),
                   let closeBracket = activity.firstIndex(of: ">") {
                    let guardContent = String(activity[activity.index(after: openBracket)..<closeBracket])
                    let parts = guardContent.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let guardKey = String(parts[0])
                        let guardValue = String(parts[1])
                        let funcName = featureSetFunctionName(analyzed.featureSet.name)
                        if let handlerFunc = ctx.module.function(named: funcName) {
                            let guardKeyStr = ctx.stringConstant(guardKey)
                            let guardValueStr = ctx.stringConstant(guardValue)
                            _ = ctx.module.insertCall(
                                externals.registerStateTransitionHandler,
                                on: [runtime, guardKeyStr, guardValueStr, handlerFunc],
                                at: ip
                            )
                        }
                    }
                }
                continue
            }

            // Check for event handlers
            if activity.hasSuffix(" Handler") {
                if let handlerRange = activity.range(of: " Handler") {
                    let eventType = String(activity[..<handlerRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)

                    // Skip special handlers (Socket events handled separately; Application-End not an event handler)
                    // Note: WebSocket Event MUST be checked before Socket Event because
                    // "WebSocket Event Handler" contains "Socket Event" as a substring.
                    guard !activity.contains("Application-End") else {
                        continue
                    }

                    // WebSocket Event Handlers: determine event type from feature set name.
                    // Must be checked before "Socket Event" guard since "WebSocket" contains "Socket".
                    if activity.contains("WebSocket Event") {
                        let featureName = analyzed.featureSet.name.lowercased()
                        let wsEventType: String
                        if featureName.contains("message") || featureName.contains("data") {
                            wsEventType = "websocket.message"
                        } else if featureName.contains("disconnect") {
                            wsEventType = "websocket.disconnected"
                        } else if featureName.contains("connect") {
                            wsEventType = "websocket.connected"
                        } else {
                            continue
                        }
                        let funcName = featureSetFunctionName(analyzed.featureSet.name)
                        if let handlerFunc = ctx.module.function(named: funcName) {
                            let eventTypeStr = ctx.stringConstant(wsEventType)
                            _ = ctx.module.insertCall(
                                externals.runtimeRegisterHandler,
                                on: [runtime, eventTypeStr, handlerFunc],
                                at: ip
                            )
                        }
                        continue
                    }

                    // TCP Socket Event Handlers: register by event type derived from feature set name.
                    // DomainEvents are co-published by AROSocketClient's receive/connect/disconnect paths.
                    if activity.contains("Socket Event") {
                        let featureName = analyzed.featureSet.name.lowercased()
                        let socketEventType: String
                        if featureName.contains("data") || featureName.contains("message") || featureName.contains("received") {
                            socketEventType = "socket.data"
                        } else if featureName.contains("disconnect") {
                            socketEventType = "socket.disconnected"
                        } else if featureName.contains("connect") {
                            socketEventType = "socket.connected"
                        } else {
                            continue
                        }
                        let funcName = featureSetFunctionName(analyzed.featureSet.name)
                        if let handlerFunc = ctx.module.function(named: funcName) {
                            let eventTypeStr = ctx.stringConstant(socketEventType)
                            _ = ctx.module.insertCall(
                                externals.runtimeRegisterHandler,
                                on: [runtime, eventTypeStr, handlerFunc],
                                at: ip
                            )
                        }
                        continue
                    }

                    // File Event Handlers: determine event type from feature set name
                    if activity.contains("File Event") {
                        let featureName = analyzed.featureSet.name.lowercased()
                        let fileEventType: String
                        if featureName.contains("created") {
                            fileEventType = "file.created"
                        } else if featureName.contains("modified") {
                            fileEventType = "file.modified"
                        } else if featureName.contains("deleted") {
                            fileEventType = "file.deleted"
                        } else {
                            continue
                        }
                        let funcName = featureSetFunctionName(analyzed.featureSet.name)
                        if let handlerFunc = ctx.module.function(named: funcName) {
                            let eventTypeStr = ctx.stringConstant(fileEventType)
                            _ = ctx.module.insertCall(
                                externals.runtimeRegisterHandler,
                                on: [runtime, eventTypeStr, handlerFunc],
                                at: ip
                            )
                        }
                        continue
                    }

                    let funcName = featureSetFunctionName(analyzed.featureSet.name)
                    if let handlerFunc = ctx.module.function(named: funcName) {
                        let eventTypeStr = ctx.stringConstant(eventType)
                        _ = ctx.module.insertCall(
                            externals.runtimeRegisterHandler,
                            on: [runtime, eventTypeStr, handlerFunc],
                            at: ip
                        )
                    }
                }
            }

            // Check for repository observers
            if activity.hasSuffix(" Observer") {
                if let observerRange = activity.range(of: " Observer") {
                    let repoName = String(activity[..<observerRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)

                    let funcName = featureSetFunctionName(analyzed.featureSet.name)
                    if let observerFunc = ctx.module.function(named: funcName) {
                        let repoNameStr = ctx.stringConstant(repoName)

                        // Check for when condition on the feature set
                        if let whenCondition = analyzed.featureSet.whenCondition {
                            // Serialize the when condition to JSON
                            let conditionJSON = serializeExpression(whenCondition)
                            let conditionStr = ctx.stringConstant(conditionJSON)
                            _ = ctx.module.insertCall(
                                externals.registerRepositoryObserverWithGuard,
                                on: [runtime, repoNameStr, observerFunc, conditionStr],
                                at: ip
                            )
                        } else {
                            // No when condition, use the legacy function
                            _ = ctx.module.insertCall(
                                externals.registerRepositoryObserver,
                                on: [runtime, repoNameStr, observerFunc],
                                at: ip
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - String Constant Collector

/// Collects all string constants from the program
private final class StringConstantCollector {
    private let ctx: LLVMCodeGenContext

    init(context: LLVMCodeGenContext) {
        self.ctx = context
    }

    func collect(from program: AnalyzedProgram, openAPISpecJSON: String?, templatesJSON: String? = nil, embeddedPlugins: [(name: String, yaml: String, base64Library: String)]? = nil) {
        // Register built-in variable names
        let builtins = ["_literal_", "_expression_", "_result_expression_",
                        "_aggregation_type_", "_aggregation_field_",
                        "_where_field_", "_where_op_", "_where_value_", "_by_pattern_", "_by_flags_",
                        "_with_", "_to_", "_publish_alias_", "_publish_variable_",
                        "_require_variable_", "_require_source_", "Application-Start"]
        for name in builtins {
            _ = ctx.stringConstant(name)
        }

        // Register OpenAPI spec if provided
        if let spec = openAPISpecJSON {
            _ = ctx.stringConstant(spec)
        }

        // Register templates JSON if provided (ARO-0050)
        if let templates = templatesJSON {
            _ = ctx.stringConstant(templates)
        }

        // Pre-register embedded plugin strings
        if let plugins = embeddedPlugins {
            for plugin in plugins {
                _ = ctx.stringConstant(plugin.name)
                _ = ctx.stringConstant(plugin.yaml)
                _ = ctx.stringConstant(plugin.base64Library)
            }
        }

        // Collect from feature sets
        for analyzed in program.featureSets {
            collectFromFeatureSet(analyzed.featureSet)
        }
    }

    private func collectFromFeatureSet(_ fs: FeatureSet) {
        _ = ctx.stringConstant(fs.name)
        _ = ctx.stringConstant(fs.businessActivity)

        for statement in fs.statements {
            collectFromStatement(statement)
        }
    }

    private func collectFromStatement(_ statement: Statement) {
        if let aro = statement as? AROStatement {
            _ = ctx.stringConstant(aro.result.base)
            for spec in aro.result.specifiers {
                _ = ctx.stringConstant(spec)
            }
            _ = ctx.stringConstant(aro.object.noun.base)
            for spec in aro.object.noun.specifiers {
                _ = ctx.stringConstant(spec)
            }
            collectFromValueSource(aro.valueSource)
            collectFromQueryModifiers(aro.queryModifiers)
            collectFromRangeModifiers(aro.rangeModifiers)
        } else if let match = statement as? MatchStatement {
            _ = ctx.stringConstant(match.subject.base)
            for caseClause in match.cases {
                for stmt in caseClause.body {
                    collectFromStatement(stmt)
                }
            }
            if let otherwise = match.otherwise {
                for stmt in otherwise {
                    collectFromStatement(stmt)
                }
            }
        } else if let loop = statement as? ForEachLoop {
            _ = ctx.stringConstant(loop.itemVariable)
            if let index = loop.indexVariable {
                _ = ctx.stringConstant(index)
            }
            _ = ctx.stringConstant(loop.collection.base)
            for stmt in loop.body {
                collectFromStatement(stmt)
            }
        } else if let publish = statement as? PublishStatement {
            _ = ctx.stringConstant(publish.externalName)
            _ = ctx.stringConstant(publish.internalVariable)
        } else if let require = statement as? RequireStatement {
            _ = ctx.stringConstant(require.variableName)
            switch require.source {
            case .framework:
                _ = ctx.stringConstant("framework")
            case .environment:
                _ = ctx.stringConstant("environment")
            case .featureSet(let name):
                _ = ctx.stringConstant(name)
            }
        }
    }

    private func collectFromValueSource(_ source: ValueSource) {
        switch source {
        case .none:
            break
        case .literal(let lit):
            collectFromLiteral(lit)
        case .expression(let expr):
            collectFromExpression(expr)
        case .sinkExpression(let expr):
            collectFromExpression(expr)
        }
    }

    private func collectFromQueryModifiers(_ modifiers: QueryModifiers) {
        guard !modifiers.isEmpty else { return }

        if let whereClause = modifiers.whereClause {
            _ = ctx.stringConstant(whereClause.field)
            _ = ctx.stringConstant(whereClause.op.rawValue)
            collectFromExpression(whereClause.value)
        }

        if let aggregation = modifiers.aggregation {
            _ = ctx.stringConstant(aggregation.type.rawValue)
            if let field = aggregation.field {
                _ = ctx.stringConstant(field)
            }
        }

        if let byClause = modifiers.byClause {
            _ = ctx.stringConstant(byClause.pattern)
            _ = ctx.stringConstant(byClause.flags)
        }
    }

    private func collectFromRangeModifiers(_ modifiers: RangeModifiers) {
        guard !modifiers.isEmpty else { return }

        if let toClause = modifiers.toClause {
            collectFromExpression(toClause)
        }

        if let withClause = modifiers.withClause {
            collectFromExpression(withClause)
        }
    }

    private func collectFromLiteral(_ lit: LiteralValue) {
        switch lit {
        case .string(let s):
            _ = ctx.stringConstant(s)
        case .array(let elements):
            for elem in elements {
                collectFromLiteral(elem)
            }
        case .object(let entries):
            for (key, value) in entries {
                _ = ctx.stringConstant(key)
                collectFromLiteral(value)
            }
        case .regex(let pattern, _):
            _ = ctx.stringConstant(pattern)
        case .integer, .float, .boolean, .null:
            break
        }
    }

    private func collectFromExpression(_ expr: any AROParser.Expression) {
        if let literal = expr as? LiteralExpression {
            collectFromLiteral(literal.value)
        } else if let ref = expr as? VariableRefExpression {
            _ = ctx.stringConstant(ref.noun.base)
            for spec in ref.noun.specifiers {
                _ = ctx.stringConstant(spec)
            }
        } else if let binary = expr as? BinaryExpression {
            collectFromExpression(binary.left)
            collectFromExpression(binary.right)
        } else if let unary = expr as? UnaryExpression {
            collectFromExpression(unary.operand)
        } else if let interpolated = expr as? InterpolatedStringExpression {
            for part in interpolated.parts {
                switch part {
                case .literal(let s):
                    _ = ctx.stringConstant(s)
                case .interpolation(let e):
                    collectFromExpression(e)
                }
            }
        } else if let array = expr as? ArrayLiteralExpression {
            for elem in array.elements {
                collectFromExpression(elem)
            }
        } else if let map = expr as? MapLiteralExpression {
            for entry in map.entries {
                _ = ctx.stringConstant(entry.key)
                collectFromExpression(entry.value)
            }
        } else if let member = expr as? MemberAccessExpression {
            collectFromExpression(member.base)
            _ = ctx.stringConstant(member.member)
        } else if let subscript_ = expr as? SubscriptExpression {
            collectFromExpression(subscript_.base)
            collectFromExpression(subscript_.index)
        } else if let grouped = expr as? GroupedExpression {
            collectFromExpression(grouped.expression)
        } else if let existence = expr as? ExistenceExpression {
            collectFromExpression(existence.expression)
        } else if let typeCheck = expr as? TypeCheckExpression {
            collectFromExpression(typeCheck.expression)
            _ = ctx.stringConstant(typeCheck.typeName)
        }
    }
}

#endif
