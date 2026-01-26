// ============================================================
// LLVMCodeGeneratorV2.swift
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
public final class LLVMCodeGeneratorV2 {
    // MARK: - Components

    private var ctx: LLVMCodeGenContext!
    private var types: LLVMTypeMapper!
    private var externals: LLVMExternalDeclEmitter!

    // MARK: - State

    private var globalRuntime: GlobalVariable?

    // MARK: - Initialization

    public init() {}

    // MARK: - Main Entry Point

    /// Generates LLVM IR for the given analyzed program
    /// - Parameters:
    ///   - program: The analyzed ARO program
    ///   - openAPISpecJSON: Optional OpenAPI specification as JSON string
    /// - Returns: Code generation result with IR text
    /// - Throws: LLVMCodeGenError if generation fails
    public func generate(
        program: AnalyzedProgram,
        openAPISpecJSON: String? = nil
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
        stringCollector.collect(from: program, openAPISpecJSON: openAPISpecJSON)

        // Generate feature set functions
        for analyzedFS in program.featureSets {
            generateFeatureSet(analyzedFS)
        }

        // Generate main function
        generateMainFunction(program: program, openAPISpecJSON: openAPISpecJSON)

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
        // Use unique function name for Application-Start to support module imports
        let funcName: String
        if fs.name == "Application-Start" {
            funcName = applicationStartFunctionName(fs.businessActivity)
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

        // Allocate result storage
        let resultPtr = ctx.module.insertAlloca(ctx.ptrType, at: ctx.insertionPoint)
        ctx.currentResultPtr = resultPtr

        // Initialize result to null
        ctx.module.insertStore(ctx.ptrType.null, to: resultPtr, at: ctx.insertionPoint)

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

    // MARK: - Statement Generation

    private func generateStatement(_ statement: Statement, index: Int, errorBlock: BasicBlock) {
        switch statement {
        case let aroStatement as AROStatement:
            generateAROStatement(aroStatement, index: index, errorBlock: errorBlock)
        case let matchStatement as MatchStatement:
            generateMatchStatement(matchStatement, index: index, errorBlock: errorBlock)
        case let forEachLoop as ForEachLoop:
            generateForEachLoop(forEachLoop, index: index, errorBlock: errorBlock)
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

        // Bind query modifiers if present
        bindQueryModifiers(statement.queryModifiers)

        // Bind range modifiers if present
        bindRangeModifiers(statement.rangeModifiers)

        // Bind value source if present
        bindValueSource(statement.valueSource, prefix: prefix)

        // Call action function
        let verb = statement.action.verb.lowercased()
        guard let actionFunc = externals.actionFunction(for: verb) else {
            ctx.recordError(.invalidAction(verb: verb, span: statement.span))
            return
        }

        let actionResult = ctx.module.insertCall(
            actionFunc,
            on: [ctx.currentContextVar!, resultDesc, objectDesc],
            at: ctx.insertionPoint
        )

        // Store result
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

        // Allocate descriptor on stack
        let descPtr = ctx.module.insertAlloca(descType, at: ip)

        // Store base name
        let baseStr = ctx.stringConstant(result.base)
        let basePtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 0, at: ip
        )
        ctx.module.insertStore(baseStr, to: basePtr, at: ip)

        // Store specifiers array (or null if none)
        let specsPtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 1, at: ip
        )

        if result.specifiers.isEmpty {
            ctx.module.insertStore(ctx.ptrType.null, to: specsPtr, at: ip)
        } else {
            // Create specifiers array
            let arrayType = types.pointerArrayType(count: result.specifiers.count)
            let arrayPtr = ctx.module.insertAlloca(arrayType, at: ip)

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

        // Store specifier count
        let countPtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 2, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.constant(result.specifiers.count), to: countPtr, at: ip)

        return descPtr
    }

    private func buildObjectDescriptor(_ object: ObjectClause, prefix: String) -> IRValue {
        let ip = ctx.insertionPoint
        let descType = types.objectDescriptorType

        // Allocate descriptor on stack
        let descPtr = ctx.module.insertAlloca(descType, at: ip)

        // Store base name
        let baseStr = ctx.stringConstant(object.noun.base)
        let basePtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 0, at: ip
        )
        ctx.module.insertStore(baseStr, to: basePtr, at: ip)

        // Store preposition
        let prepPtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 1, at: ip
        )
        ctx.module.insertStore(ctx.i32Type.constant(LLVMTypeMapper.prepositionValue(object.preposition)), to: prepPtr, at: ip)

        // Store specifiers array (or null if none)
        let specsPtr = ctx.module.insertGetStructElementPointer(
            of: descPtr, typed: descType, index: 2, at: ip
        )

        let specifiers = object.noun.specifiers
        if specifiers.isEmpty {
            ctx.module.insertStore(ctx.ptrType.null, to: specsPtr, at: ip)
        } else {
            // Create specifiers array
            let arrayType = types.pointerArrayType(count: specifiers.count)
            let arrayPtr = ctx.module.insertAlloca(arrayType, at: ip)

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

        // Store specifier count
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
            let exprJSON = ctx.stringConstant(serializeExpression(expr))
            ctx.module.insertCall(
                externals.evaluateExpression,
                on: [ctx.currentContextVar!, exprJSON],
                at: ip
            )

        case .sinkExpression(let expr):
            // Sink expression: evaluate and bind to _result_expression_ for LogAction/response actions
            let resultExprName = ctx.stringConstant("_result_expression_")
            let exprJSON = ctx.stringConstant(serializeExpression(expr))
            ctx.module.insertCall(
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
            ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, fieldName, fieldValue],
                at: ip
            )

            // Bind _where_op_
            let opName = ctx.stringConstant("_where_op_")
            let opValue = ctx.stringConstant(whereClause.op.rawValue)
            ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, opName, opValue],
                at: ip
            )

            // Bind _where_value_ by evaluating the expression
            let valueName = ctx.stringConstant("_where_value_")
            let valueJSON = ctx.stringConstant(serializeExpression(whereClause.value))
            ctx.module.insertCall(
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
            ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, typeName, typeValue],
                at: ip
            )

            // Bind _aggregation_field_ (can be nil for count())
            let fieldName = ctx.stringConstant("_aggregation_field_")
            let fieldValue = ctx.stringConstant(aggregation.field ?? "")
            ctx.module.insertCall(
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
            ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, patternName, patternValue],
                at: ip
            )

            // Bind _by_flags_
            let flagsName = ctx.stringConstant("_by_flags_")
            let flagsValue = ctx.stringConstant(byClause.flags)
            ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, flagsName, flagsValue],
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
            ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, toName, toJSON],
                at: ip
            )
        }

        // Bind with clause if present (e.g., set operations) - evaluate expression
        if let withClause = modifiers.withClause {
            let withName = ctx.stringConstant("_with_")
            let withJSON = ctx.stringConstant(serializeExpression(withClause))
            ctx.module.insertCall(
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
            ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, literalVar, valueStr],
                at: ip
            )

        case .integer(let value):
            ctx.module.insertCall(
                externals.variableBindInt,
                on: [ctx.currentContextVar!, literalVar, ctx.i64Type.constant(value)],
                at: ip
            )

        case .float(let value):
            ctx.module.insertCall(
                externals.variableBindDouble,
                on: [ctx.currentContextVar!, literalVar, ctx.doubleType.constant(value)],
                at: ip
            )

        case .boolean(let value):
            ctx.module.insertCall(
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
            ctx.module.insertCall(
                externals.variableBindArray,
                on: [ctx.currentContextVar!, literalVar, jsonStr],
                at: ip
            )

        case .object(let entries):
            // Serialize object as plain JSON (not expression-wrapped) for variableBindDict
            let json = serializeLiteralObjectPlain(entries)
            let jsonStr = ctx.stringConstant(json)
            ctx.module.insertCall(
                externals.variableBindDict,
                on: [ctx.currentContextVar!, literalVar, jsonStr],
                at: ip
            )

        case .regex(let pattern, let flags):
            // Bind regex as pattern string
            let regexStr = ctx.stringConstant("/\(pattern)/\(flags)")
            ctx.module.insertCall(
                externals.variableBindString,
                on: [ctx.currentContextVar!, literalVar, regexStr],
                at: ip
            )
        }
    }

    // MARK: - Expression Serialization

    private func serializeExpression(_ expr: any AROParser.Expression) -> String {
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
                    template += "${\(varRef.noun.base)}"
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
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
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
        "{\"name\":\"\(escapeJSON(subject.base))\"}"
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

    private func generateForEachLoop(_ loop: ForEachLoop, index: Int, errorBlock: BasicBlock) {
        let prefix = "foreach\(index)"

        // Create loop blocks
        let condBlock = ctx.module.appendBlock(named: "\(prefix)_cond", to: ctx.currentFunction!)
        let bodyBlock = ctx.module.appendBlock(named: "\(prefix)_body", to: ctx.currentFunction!)
        let incrBlock = ctx.module.appendBlock(named: "\(prefix)_incr", to: ctx.currentFunction!)
        let endBlock = ctx.module.appendBlock(named: "\(prefix)_end", to: ctx.currentFunction!)

        // Resolve collection (with optional specifier for nested properties like <team: members>)
        let collectionName = ctx.stringConstant(loop.collection.base)
        var collection = ctx.module.insertCall(
            externals.variableResolve,
            on: [ctx.currentContextVar!, collectionName],
            at: ctx.insertionPoint
        )

        // Handle specifiers to access nested properties
        for spec in loop.collection.specifiers {
            let specName = ctx.stringConstant(spec)
            collection = ctx.module.insertCall(
                externals.dictGet,
                on: [collection, specName],
                at: ctx.insertionPoint
            )
        }

        // Get collection count
        let count = ctx.module.insertCall(
            externals.arrayCount,
            on: [collection],
            at: ctx.insertionPoint
        )

        // Allocate index counter
        let indexPtr = ctx.module.insertAlloca(ctx.i64Type, at: ctx.insertionPoint)
        ctx.module.insertStore(ctx.i64Type.zero, to: indexPtr, at: ctx.insertionPoint)

        // Jump to condition check
        ctx.module.insertBr(to: condBlock, at: ctx.insertionPoint)

        // === Condition Block ===
        ctx.setInsertionPoint(atEndOf: condBlock)

        let curIndex = ctx.module.insertLoad(ctx.i64Type, from: indexPtr, at: ctx.insertionPoint)
        let done = ctx.module.insertIntegerComparison(
            .sge, curIndex, count, at: ctx.insertionPoint
        )
        ctx.module.insertCondBr(if: done, then: endBlock, else: bodyBlock, at: ctx.insertionPoint)

        // === Body Block ===
        ctx.setInsertionPoint(atEndOf: bodyBlock)

        // Get current element
        let element = ctx.module.insertCall(
            externals.arrayGet,
            on: [collection, curIndex],
            at: ctx.insertionPoint
        )

        // Unbind and rebind element to item variable (unbind allows rebinding on each iteration)
        let itemVarName = ctx.stringConstant(loop.itemVariable)
        ctx.module.insertCall(
            externals.variableUnbind,
            on: [ctx.currentContextVar!, itemVarName],
            at: ctx.insertionPoint
        )
        ctx.module.insertCall(
            externals.variableBindValue,
            on: [ctx.currentContextVar!, itemVarName, element],
            at: ctx.insertionPoint
        )

        // Bind index if specified
        if let indexVar = loop.indexVariable {
            // Create index value (0-based like most programming languages)
            let indexVarName = ctx.stringConstant(indexVar)

            // Unbind first to allow rebinding on each iteration
            ctx.module.insertCall(
                externals.variableUnbind,
                on: [ctx.currentContextVar!, indexVarName],
                at: ctx.insertionPoint
            )

            // Create boxed integer value
            let indexValue = ctx.module.insertCall(
                externals.valueCreateInt,
                on: [curIndex],
                at: ctx.insertionPoint
            )
            ctx.module.insertCall(
                externals.variableBindValue,
                on: [ctx.currentContextVar!, indexVarName, indexValue],
                at: ctx.insertionPoint
            )
        }

        // Check filter if present
        var filterSkipBlock: BasicBlock?
        if let filter = loop.filter {
            filterSkipBlock = incrBlock  // Skip to increment if filter fails

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

        // Generate body statements
        for (stmtIndex, stmt) in loop.body.enumerated() {
            generateStatement(stmt, index: index * 100 + stmtIndex, errorBlock: errorBlock)
        }

        // Branch to increment
        ctx.module.insertBr(to: incrBlock, at: ctx.insertionPoint)

        // === Increment Block ===
        ctx.setInsertionPoint(atEndOf: incrBlock)

        let nextIndex = ctx.module.insertAdd(curIndex, ctx.i64Type.constant(1), at: ctx.insertionPoint)
        ctx.module.insertStore(nextIndex, to: indexPtr, at: ctx.insertionPoint)
        ctx.module.insertBr(to: condBlock, at: ctx.insertionPoint)

        // === End Block ===
        ctx.setInsertionPoint(atEndOf: endBlock)
    }

    // MARK: - Publish Statement Generation

    private func generatePublishStatement(_ statement: PublishStatement, index: Int, errorBlock: BasicBlock) {
        let ip = ctx.insertionPoint

        // Bind the publish alias
        let aliasName = ctx.stringConstant("_publish_alias_")
        let aliasValue = ctx.stringConstant(statement.externalName)
        ctx.module.insertCall(
            externals.variableBindString,
            on: [ctx.currentContextVar!, aliasName, aliasValue],
            at: ip
        )

        // Bind the internal variable name
        let varName = ctx.stringConstant("_publish_variable_")
        let varValue = ctx.stringConstant(statement.internalVariable)
        ctx.module.insertCall(
            externals.variableBindString,
            on: [ctx.currentContextVar!, varName, varValue],
            at: ip
        )

        // Build result descriptor for the publish action
        let descType = types.resultDescriptorType
        let resultDesc = ctx.module.insertAlloca(descType, at: ip)

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
        let objectDesc = ctx.module.insertAlloca(objDescType, at: ip)

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
        ctx.module.insertCall(
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
        ctx.module.insertCall(
            externals.variableBindString,
            on: [ctx.currentContextVar!, sourceName, sourceStr],
            at: ip
        )

        // Build result descriptor for the require action
        let descType = types.resultDescriptorType
        let resultDesc = ctx.module.insertAlloca(descType, at: ip)

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
        let objectDesc = ctx.module.insertAlloca(objDescType, at: ip)

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
            ctx.module.insertStore(actionResult, to: ctx.currentResultPtr!, at: ip)
        }
    }

    // MARK: - Main Function Generation

    private func generateMainFunction(program: AnalyzedProgram, openAPISpecJSON: String?) {
        let mainFunc = ctx.module.declareFunction("main", types.mainFunctionType)

        let entryBlock = ctx.module.appendBlock(named: "entry", to: mainFunc)
        ctx.setInsertionPoint(atEndOf: entryBlock)
        let ip = ctx.insertionPoint

        // Initialize runtime
        let runtime = ctx.module.insertCall(externals.runtimeInit, on: [], at: ip)

        // Store runtime in global
        ctx.module.insertStore(runtime, to: globalRuntime!, at: ip)

        // Set embedded OpenAPI spec if provided
        if let spec = openAPISpecJSON {
            let specStr = ctx.stringConstant(spec)
            ctx.module.insertCall(externals.setEmbeddedOpenapi, on: [specStr], at: ip)
        }

        // Load precompiled plugins
        ctx.module.insertCall(externals.loadPrecompiledPlugins, on: [], at: ip)

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
                ctx.module.insertCall(appStartFunc, on: [appCtx], at: ip)
            }

            // Keep main context for response printing, destroy imported module contexts
            if isMain {
                mainCtx = appCtx
            } else {
                _ = ctx.module.insertCall(externals.contextDestroy, on: [appCtx], at: ip)
            }
        }

        // Wait for pending events (10 second timeout)
        _ = ctx.module.insertCall(
            externals.runtimeAwaitPendingEvents,
            on: [runtime, ctx.doubleType.constant(10.0)],
            at: ip
        )

        // Print response
        _ = ctx.module.insertCall(externals.contextPrintResponse, on: [mainCtx], at: ip)

        // Cleanup
        _ = ctx.module.insertCall(externals.contextDestroy, on: [mainCtx], at: ip)
        _ = ctx.module.insertCall(externals.runtimeShutdown, on: [runtime], at: ip)

        // Return success
        ctx.module.insertReturn(ctx.i32Type.zero, at: ip)
    }

    private func registerEventHandlers(program: AnalyzedProgram, runtime: IRValue) {
        let ip = ctx.insertionPoint

        for analyzed in program.featureSets {
            let activity = analyzed.featureSet.businessActivity

            // Check for event handlers
            if activity.hasSuffix(" Handler") {
                if let handlerRange = activity.range(of: " Handler") {
                    let eventType = String(activity[..<handlerRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)

                    // Skip special handlers
                    guard !activity.contains("Socket Event") &&
                          !activity.contains("File Event") &&
                          !activity.contains("Application-End") else {
                        continue
                    }

                    let funcName = featureSetFunctionName(analyzed.featureSet.name)
                    if let handlerFunc = ctx.module.function(named: funcName) {
                        let eventTypeStr = ctx.stringConstant(eventType)
                        ctx.module.insertCall(
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
                        ctx.module.insertCall(
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

// MARK: - String Constant Collector

/// Collects all string constants from the program
private final class StringConstantCollector {
    private let ctx: LLVMCodeGenContext

    init(context: LLVMCodeGenContext) {
        self.ctx = context
    }

    func collect(from program: AnalyzedProgram, openAPISpecJSON: String?) {
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
