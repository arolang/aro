// ============================================================
// LLVMCodeGenerator.swift
// AROCompiler - LLVM IR Text Code Generation
// ============================================================

import Foundation
import AROParser

/// Result of LLVM code generation
public struct LLVMCodeGenerationResult {
    /// The generated LLVM IR text
    public let irText: String

    /// Path to the emitted file (if applicable)
    public var filePath: String?
}

/// Generates LLVM IR text from an analyzed ARO program
public final class LLVMCodeGenerator {
    // MARK: - Properties

    private var output: String = ""
    private var stringConstants: [String: String] = [:]  // string -> global name
    private var uniqueCounter: Int = 0
    private var openAPISpecJSON: String? = nil
    private var currentContext: String = "%ctx"  // Current context variable name (for loop scoping)

    /// Counter for generating unique loop body function names
    private var loopBodyCounter: Int = 0

    /// Storage for loop body functions to emit after feature set
    private var pendingLoopBodies: [(String, ForEachLoop, String)] = []

    // MARK: - Initialization

    public init() {}

    // MARK: - Code Generation

    /// Generate LLVM IR for an analyzed program
    /// - Parameters:
    ///   - program: The analyzed ARO program
    ///   - openAPISpecJSON: Optional OpenAPI spec as minified JSON to embed in binary
    /// - Returns: Result containing the LLVM IR text
    public func generate(program: AnalyzedProgram, openAPISpecJSON: String? = nil) throws -> LLVMCodeGenerationResult {
        output = ""
        stringConstants = [:]
        uniqueCounter = 0
        self.openAPISpecJSON = openAPISpecJSON

        // Emit module header
        emitModuleHeader()

        // Emit type definitions
        emitTypeDefinitions()

        // Emit external function declarations
        emitExternalDeclarations()

        // Emit global variables
        emitGlobalVariables()

        // Collect all string constants first
        collectStringConstants(program)

        // Emit string constants
        emitStringConstants()

        // Generate feature set functions
        for featureSet in program.featureSets {
            try generateFeatureSet(featureSet)
        }

        // Generate main function
        try generateMain(program: program)

        return LLVMCodeGenerationResult(irText: output)
    }

    // MARK: - Header Generation

    private func emitModuleHeader() {
        emit("; ModuleID = 'aro_program'")
        emit("source_filename = \"aro_program.ll\"")
        emit("target datalayout = \"e-m:o-i64:64-i128:128-n32:64-S128\"")
        #if arch(arm64)
        emit("target triple = \"arm64-apple-macosx14.0.0\"")
        #else
        emit("target triple = \"x86_64-apple-macosx14.0.0\"")
        #endif
        emit("")
    }

    private func emitTypeDefinitions() {
        emit("; Type definitions")
        emit("; AROResultDescriptor: { i8*, i8**, i32 }")
        emit("%AROResultDescriptor = type { ptr, ptr, i32 }")
        emit("")
        emit("; AROObjectDescriptor: { i8*, i32, i8**, i32 }")
        emit("%AROObjectDescriptor = type { ptr, i32, ptr, i32 }")
        emit("")
    }

    private func emitExternalDeclarations() {
        emit("; External runtime function declarations")
        emit("")

        // Runtime lifecycle
        emit("; Runtime lifecycle")
        emit("declare ptr @aro_runtime_init()")
        emit("declare void @aro_runtime_shutdown(ptr)")
        emit("declare i32 @aro_runtime_await_pending_events(ptr, double)")
        emit("declare void @aro_runtime_register_handler(ptr, ptr, ptr)")
        emit("declare void @aro_log_warning(ptr)")
        emit("declare ptr @aro_context_create(ptr)")
        emit("declare ptr @aro_context_create_named(ptr, ptr)")
        emit("declare ptr @aro_context_create_child(ptr, ptr)")
        emit("declare void @aro_context_destroy(ptr)")
        emit("declare void @aro_context_print_response(ptr)")
        emit("declare i32 @aro_load_precompiled_plugins()")
        emit("")

        // Variable operations
        emit("; Variable operations")
        emit("declare void @aro_variable_bind_string(ptr, ptr, ptr)")
        emit("declare void @aro_variable_bind_int(ptr, ptr, i64)")
        emit("declare void @aro_variable_bind_double(ptr, ptr, double)")
        emit("declare void @aro_variable_bind_bool(ptr, ptr, i32)")
        emit("declare void @aro_variable_bind_dict(ptr, ptr, ptr)")
        emit("declare void @aro_variable_bind_array(ptr, ptr, ptr)")
        emit("declare ptr @aro_variable_resolve(ptr, ptr)")
        emit("declare void @aro_copy_value_to_expression(ptr, ptr)")
        emit("declare ptr @aro_variable_resolve_string(ptr, ptr)")
        emit("declare i32 @aro_variable_resolve_int(ptr, ptr, ptr)")
        emit("declare void @aro_value_free(ptr)")
        emit("declare ptr @aro_value_as_string(ptr)")
        emit("declare i32 @aro_value_as_int(ptr, ptr)")
        emit("declare ptr @aro_string_concat(ptr, ptr)")
        emit("declare ptr @aro_interpolate_string(ptr, ptr)")
        emit("declare i32 @aro_evaluate_when_guard(ptr, ptr)")
        emit("declare void @aro_evaluate_expression(ptr, ptr)")
        emit("")

        // All action functions
        emit("; Action functions")
        let actions = [
            "extract", "fetch", "retrieve", "parse", "read", "request",
            "compute", "validate", "compare", "transform", "create", "update", "accept",
            "return", "throw", "emit", "send", "log", "store", "write", "publish",
            "start", "listen", "route", "watch", "stop", "keepalive", "broadcast",
            "call",
            // Data pipeline actions (ARO-0018)
            "filter", "reduce", "map",
            // System exec action (ARO-0033)
            "exec", "shell",
            // Repository actions
            "delete", "merge", "close",
            // String action (ARO-0037)
            "split",
            // File operations (ARO-0036)
            "list", "stat", "exists", "make", "touch", "createdirectory", "mkdir",
            "copy", "move", "rename", "append"
        ]
        for action in actions {
            emit("declare ptr @aro_action_\(action)(ptr, ptr, ptr)")
        }
        emit("")

        // HTTP operations
        emit("; HTTP operations")
        emit("declare ptr @aro_http_server_create(ptr)")
        emit("declare i32 @aro_http_server_start(ptr, ptr, i32)")
        emit("declare void @aro_http_server_stop(ptr)")
        emit("declare void @aro_http_server_destroy(ptr)")
        emit("")

        // Async runtime operations
        emit("; Async runtime")
        emit("declare i32 @aro_async_run(ptr)")
        emit("declare void @aro_async_shutdown()")
        emit("")

        // File operations
        emit("; File operations")
        emit("declare ptr @aro_file_read(ptr, ptr)")
        emit("declare i32 @aro_file_write(ptr, ptr)")
        emit("declare i32 @aro_file_exists(ptr)")
        emit("declare i32 @aro_file_delete(ptr)")
        emit("")

        // Standard C library functions
        emit("; Standard C library")
        emit("declare i32 @strcmp(ptr, ptr)")
        emit("")

        // ForEach/iteration operations
        emit("; ForEach/iteration operations")
        emit("declare i64 @aro_array_count(ptr)")
        emit("declare ptr @aro_array_get(ptr, i64)")
        emit("declare void @aro_variable_bind_value(ptr, ptr, ptr)")
        emit("declare ptr @aro_dict_get(ptr, ptr)")
        emit("declare i32 @aro_evaluate_filter(ptr, ptr)")
        emit("")

        // Parallel execution
        emit("; Parallel execution")
        emit("declare i32 @aro_parallel_for_each_execute(ptr, ptr, ptr, ptr, i64, ptr, ptr)")
        emit("")

        // OpenAPI embedding
        emit("; OpenAPI spec embedding")
        emit("declare void @aro_set_embedded_openapi(ptr)")
        emit("")

        // Repository observer registration
        emit("; Repository observer registration")
        emit("declare void @aro_register_repository_observer(ptr, ptr, ptr)")
        emit("")
    }

    /// Emit global variables
    private func emitGlobalVariables() {
        emit("; Global variables")
        emit("@global_runtime = global ptr null")
        emit("")
    }

    // MARK: - String Constants

    private func collectStringConstants(_ program: AnalyzedProgram) {
        // Collect all strings used in the program
        for featureSet in program.featureSets {
            registerString(featureSet.featureSet.name)
            registerString(featureSet.featureSet.businessActivity)

            // Collect event types from handler business activities
            let activity = featureSet.featureSet.businessActivity
            let hasHandler = activity.contains(" Handler")
            let isSpecialHandler = activity.contains("Socket Event Handler") ||
                                   activity.contains("File Event Handler") ||
                                   activity.contains("Application-End")
            if hasHandler && !isSpecialHandler {
                if let handlerRange = activity.range(of: " Handler") {
                    let eventType = String(activity[..<handlerRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    registerString(eventType)
                }
            }

            for statement in featureSet.featureSet.statements {
                collectStringsFromStatement(statement)
            }
        }

        // Register repository observer repository names
        for (repositoryName, _) in scanRepositoryObservers(program) {
            registerString(repositoryName)
        }

        // Always register these strings for main
        registerString("Application-Start")
        registerString("_literal_")
        registerString("_expression_")
        registerString("")  // Empty string for interpolation fallbacks
        // ARO-0018: Aggregation and where clause context variables
        registerString("_aggregation_type_")
        registerString("_aggregation_field_")
        registerString("_where_field_")
        registerString("_where_op_")
        registerString("_where_value_")
        // Timeout warning message
        registerString("Event handlers did not complete within timeout")

        // Register OpenAPI spec JSON if provided (for embedded spec)
        if let specJSON = openAPISpecJSON {
            registerString(specJSON)
        }
    }

    private func collectStringsFromStatement(_ statement: Statement) {
        if let aroStatement = statement as? AROStatement {
            registerString(aroStatement.result.base)
            for spec in aroStatement.result.specifiers {
                registerString(spec)
            }

            registerString(aroStatement.object.noun.base)
            for spec in aroStatement.object.noun.specifiers {
                registerString(spec)
            }

            if let literal = aroStatement.literalValue {
                collectStringsFromLiteral(literal)
            }

            // Collect strings from expressions (ARO-0002)
            if let expression = aroStatement.expression {
                collectStringsFromExpression(expression)
            }

            // ARO-0043: Collect strings from result expression (sink syntax)
            if let resultExpression = aroStatement.resultExpression {
                collectStringsFromExpression(resultExpression)
            }

            // ARO-0018: Collect aggregation clause strings
            if let aggregation = aroStatement.aggregation {
                registerString(aggregation.type.rawValue)
                if let field = aggregation.field {
                    registerString(field)
                }
            }

            // ARO-0018: Collect where clause strings
            if let whereClause = aroStatement.whereClause {
                registerString(whereClause.field)
                registerString(whereClause.op.rawValue)
                // Where value expression
                collectStringsFromExpression(whereClause.value)
            }

            // ARO-0037: Collect by clause strings (for Split action)
            if let byClause = aroStatement.byClause {
                registerString("_by_pattern_")
                registerString("_by_flags_")
                registerString(byClause.pattern)
                registerString(byClause.flags)
            }
        } else if let publishStatement = statement as? PublishStatement {
            registerString(publishStatement.externalName)
            registerString(publishStatement.internalVariable)
        } else if let matchStatement = statement as? MatchStatement {
            registerString(matchStatement.subject.base)
            for caseClause in matchStatement.cases {
                switch caseClause.pattern {
                case .literal(let literalValue):
                    if case .string(let s) = literalValue {
                        registerString(s)
                    }
                case .regex(let pattern, let flags):
                    registerString(pattern)
                    registerString(flags)
                default:
                    break
                }
                for bodyStatement in caseClause.body {
                    collectStringsFromStatement(bodyStatement)
                }
            }
            if let otherwiseBody = matchStatement.otherwise {
                for bodyStatement in otherwiseBody {
                    collectStringsFromStatement(bodyStatement)
                }
            }
        } else if let forEachLoop = statement as? ForEachLoop {
            // Register item variable name
            registerString(forEachLoop.itemVariable)
            // Register index variable if present
            if let indexVar = forEachLoop.indexVariable {
                registerString(indexVar)
            }
            // Register collection base and specifiers
            registerString(forEachLoop.collection.base)
            for spec in forEachLoop.collection.specifiers {
                registerString(spec)
            }
            // Register filter expression if present
            if let filter = forEachLoop.filter {
                collectStringsFromExpression(filter)
                // Also register the filter JSON for runtime evaluation
                let filterJSON = filterExpressionToJSON(filter, itemVar: forEachLoop.itemVariable)
                registerString(filterJSON)
            }
            // Collect strings from body statements
            for bodyStatement in forEachLoop.body {
                collectStringsFromStatement(bodyStatement)
            }
        }
    }

    private func collectStringsFromExpression(_ expression: any AROParser.Expression) {
        if let literalExpr = expression as? LiteralExpression {
            collectStringsFromLiteral(literalExpr.value)
        } else if let varRefExpr = expression as? VariableRefExpression {
            // Register variable name and specifiers for runtime resolution
            registerString(varRefExpr.noun.base)
            for spec in varRefExpr.noun.specifiers {
                registerString(spec)
            }
        } else if let mapExpr = expression as? MapLiteralExpression {
            // Register JSON representation of the map
            let jsonString = mapExpressionToJSON(mapExpr)
            registerString(jsonString)
            // Also register nested strings from entries
            for entry in mapExpr.entries {
                registerString(entry.key)
                collectStringsFromExpression(entry.value)
            }
        } else if let arrayExpr = expression as? ArrayLiteralExpression {
            // Register JSON representation of the array
            let jsonString = arrayExpressionToJSON(arrayExpr)
            registerString(jsonString)
            // Also register nested strings from elements
            for element in arrayExpr.elements {
                collectStringsFromExpression(element)
            }
        } else if let binaryExpr = expression as? BinaryExpression {
            // Register the JSON representation for runtime evaluation
            let jsonString = binaryExpressionToJSON(binaryExpr)
            registerString(jsonString)
            // Also collect strings from operands
            collectStringsFromExpression(binaryExpr.left)
            collectStringsFromExpression(binaryExpr.right)
        } else if let groupedExpr = expression as? GroupedExpression {
            collectStringsFromExpression(groupedExpr.expression)
        } else if let interpolatedExpr = expression as? InterpolatedStringExpression {
            // Register all literal parts and collect from interpolation expressions
            for part in interpolatedExpr.parts {
                switch part {
                case .literal(let str):
                    registerString(str)
                case .interpolation(let expr):
                    collectStringsFromExpression(expr)
                }
            }

            // Also register the reconstructed template string for aro_interpolate_string()
            var template = ""
            for part in interpolatedExpr.parts {
                switch part {
                case .literal(let str):
                    template += str
                case .interpolation(let expr):
                    if let varRefExpr = expr as? VariableRefExpression {
                        template += "${\(varRefExpr.noun.base)}"
                    } else {
                        template += "${}"
                    }
                }
            }
            registerString(template)
        }
    }

    /// Convert a MapLiteralExpression to JSON string
    private func mapExpressionToJSON(_ mapExpr: MapLiteralExpression) -> String {
        let pairs = mapExpr.entries.map { entry in
            let keyEscaped = entry.key.replacingOccurrences(of: "\"", with: "\\\"")
            let valueJSON = expressionToJSON(entry.value)
            return "\"\(keyEscaped)\":\(valueJSON)"
        }
        return "{\(pairs.joined(separator: ","))}"
    }

    /// Convert an ArrayLiteralExpression to JSON string
    private func arrayExpressionToJSON(_ arrayExpr: ArrayLiteralExpression) -> String {
        let items = arrayExpr.elements.map { expressionToJSON($0) }
        return "[\(items.joined(separator: ","))]"
    }

    /// Convert a BinaryExpression to JSON string for runtime evaluation
    /// Format: {"$binary":{"op":"*","left":{...},"right":{...}}}
    private func binaryExpressionToJSON(_ binaryExpr: BinaryExpression) -> String {
        let opStr = binaryExpr.op.rawValue.replacingOccurrences(of: "\"", with: "\\\"")
        let leftJSON = expressionToEvalJSON(binaryExpr.left)
        let rightJSON = expressionToEvalJSON(binaryExpr.right)
        return "{\"$binary\":{\"op\":\"\(opStr)\",\"left\":\(leftJSON),\"right\":\(rightJSON)}}"
    }

    /// Convert any Expression to evaluation JSON format
    /// Format for values: {"$lit": value} or {"$var": "name"} or {"$var": "name", "$specs": ["prop"]} or {"$binary": {...}}
    private func expressionToEvalJSON(_ expr: any AROParser.Expression) -> String {
        if let literalExpr = expr as? LiteralExpression {
            return "{\"$lit\":\(literalToJSON(literalExpr.value))}"
        } else if let varRefExpr = expr as? VariableRefExpression {
            let escaped = varRefExpr.noun.base.replacingOccurrences(of: "\"", with: "\\\"")
            if varRefExpr.noun.specifiers.isEmpty {
                return "{\"$var\":\"\(escaped)\"}"
            } else {
                // Include specifiers for expressions like <user: active>
                let specsJSON = varRefExpr.noun.specifiers.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")
                return "{\"$var\":\"\(escaped)\",\"$specs\":[\(specsJSON)]}"
            }
        } else if let binaryExpr = expr as? BinaryExpression {
            return binaryExpressionToJSON(binaryExpr)
        } else if let groupedExpr = expr as? GroupedExpression {
            return expressionToEvalJSON(groupedExpr.expression)
        } else {
            // Fallback: treat as string literal
            let escaped = expr.description.replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"$lit\":\"\(escaped)\"}"
        }
    }

    /// Convert any Expression to JSON string (for nested values)
    private func expressionToJSON(_ expr: any AROParser.Expression) -> String {
        if let literalExpr = expr as? LiteralExpression {
            return literalToJSON(literalExpr.value)
        } else if let varRefExpr = expr as? VariableRefExpression {
            // Variable reference: use $ref: prefix so runtime can resolve it
            let escaped = varRefExpr.noun.base.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"$ref:\(escaped)\""
        } else if let mapExpr = expr as? MapLiteralExpression {
            return mapExpressionToJSON(mapExpr)
        } else if let arrayExpr = expr as? ArrayLiteralExpression {
            return arrayExpressionToJSON(arrayExpr)
        } else {
            // Fallback: use description as string
            let escaped = expr.description.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
    }

    private func collectStringsFromLiteral(_ literal: LiteralValue) {
        switch literal {
        case .string(let s):
            registerString(s)
        case .object(let pairs):
            // Register JSON representation
            let jsonString = literalToJSON(literal)
            registerString(jsonString)
            // Also register nested strings
            for (key, value) in pairs {
                registerString(key)
                collectStringsFromLiteral(value)
            }
        case .array(let items):
            // Register JSON representation
            let jsonString = literalToJSON(literal)
            registerString(jsonString)
            // Also register nested strings
            for item in items {
                collectStringsFromLiteral(item)
            }
        default:
            break
        }
    }

    /// Convert a LiteralValue to its JSON string representation
    private func literalToJSON(_ literal: LiteralValue) -> String {
        switch literal {
        case .string(let s):
            // Escape special characters for JSON
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "\"\(escaped)\""
        case .integer(let i):
            return String(i)
        case .float(let f):
            return String(f)
        case .boolean(let b):
            return b ? "true" : "false"
        case .null:
            return "null"
        case .array(let items):
            let itemsJson = items.map { literalToJSON($0) }.joined(separator: ",")
            return "[\(itemsJson)]"
        case .object(let pairs):
            let pairsJson = pairs.map { key, value in
                "\"\(key)\":\(literalToJSON(value))"
            }.joined(separator: ",")
            return "{\(pairsJson)}"
        case .regex(let pattern, let flags):
            // Convert regex to JSON object with pattern and flags
            let escapedPattern = pattern
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"pattern\":\"\(escapedPattern)\",\"flags\":\"\(flags)\"}"
        }
    }

    private func registerString(_ str: String) {
        guard stringConstants[str] == nil else { return }
        let name = "@.str.\(uniqueCounter)"
        uniqueCounter += 1
        stringConstants[str] = name
    }

    private func emitStringConstants() {
        emit("; String constants")
        for (str, name) in stringConstants.sorted(by: { $0.value < $1.value }) {
            let escaped = escapeStringForLLVM(str)
            let length = str.utf8.count + 1  // +1 for null terminator
            emit("\(name) = private unnamed_addr constant [\(length) x i8] c\"\(escaped)\\00\"")
        }
        emit("")
    }

    private func stringConstantRef(_ str: String) -> String {
        guard let name = stringConstants[str] else {
            fatalError("String not registered: \(str)")
        }
        return "ptr \(name)"
    }

    // MARK: - Feature Set Generation

    private func generateFeatureSet(_ featureSet: AnalyzedFeatureSet) throws {
        // For Application-End handlers, include business activity to differentiate Success vs Error
        let funcName: String
        if featureSet.featureSet.name == "Application-End" {
            funcName = mangleFeatureSetName(featureSet.featureSet.name + "_" + featureSet.featureSet.businessActivity)
        } else {
            funcName = mangleFeatureSetName(featureSet.featureSet.name)
        }

        emit("; Feature Set: \(featureSet.featureSet.name)")
        emit("; Business Activity: \(featureSet.featureSet.businessActivity)")
        emit("define ptr @\(funcName)(ptr \(currentContext)) {")
        emit("entry:")

        // Create local result variable
        emit("  %__result = alloca ptr")
        emit("  store ptr null, ptr %__result")
        emit("")

        // Generate each statement
        for (index, statement) in featureSet.featureSet.statements.enumerated() {
            try generateStatement(statement, index: index)
        }

        // Return the result
        emit("  %final_result = load ptr, ptr %__result")
        emit("  ret ptr %final_result")
        emit("}")
        emit("")

        // Generate any pending loop body functions for this feature set
        try generatePendingLoopBodies()
    }

    private func generateStatement(_ statement: Statement, index: Int) throws {
        if let aroStatement = statement as? AROStatement {
            try generateAROStatement(aroStatement, index: index)
        } else if let publishStatement = statement as? PublishStatement {
            try generatePublishStatement(publishStatement, index: index)
        } else if let matchStatement = statement as? MatchStatement {
            try generateMatchStatement(matchStatement, index: index)
        } else if let forEachLoop = statement as? ForEachLoop {
            try generateForEachLoop(forEachLoop, index: index)
        }
    }

    // MARK: - ARO Statement Generation

    private func generateAROStatement(_ statement: AROStatement, index: Int) throws {
        let prefix = "s\(index)"

        emit("  ; <\(statement.action.verb)> the <\(statement.result.base)> ...")

        // If there's a literal value, bind it first
        if let literalValue = statement.literalValue {
            try emitLiteralBinding(literalValue, prefix: prefix)
        }

        // If there's an expression (ARO-0002), bind it to _expression_
        if let expression = statement.expression {
            try emitExpressionBinding(expression, prefix: prefix)
        }

        // ARO-0043: Bind result expression for sink syntax (e.g., <Log> "message" to <console>)
        if let resultExpression = statement.resultExpression {
            try emitExpressionBinding(resultExpression, prefix: prefix)
        }

        // ARO-0018: Bind aggregation clause if present
        if let aggregation = statement.aggregation {
            try emitAggregationBinding(aggregation, prefix: prefix)
        }

        // ARO-0018: Bind where clause if present
        if let whereClause = statement.whereClause {
            try emitWhereClauseBinding(whereClause, prefix: prefix)
        }

        // ARO-0037: Bind by clause if present (for Split action)
        if let byClause = statement.byClause {
            emitByClauseBinding(byClause, prefix: prefix)
        }

        // Allocate result descriptor
        emit("  %\(prefix)_result_desc = alloca %AROResultDescriptor")

        // Store result base name
        let resultBaseStr = stringConstants[statement.result.base]!
        emit("  %\(prefix)_rd_base_ptr = getelementptr inbounds %AROResultDescriptor, ptr %\(prefix)_result_desc, i32 0, i32 0")
        emit("  store ptr \(resultBaseStr), ptr %\(prefix)_rd_base_ptr")

        // Store result specifiers
        emit("  %\(prefix)_rd_specs_ptr = getelementptr inbounds %AROResultDescriptor, ptr %\(prefix)_result_desc, i32 0, i32 1")
        if statement.result.specifiers.isEmpty {
            emit("  store ptr null, ptr %\(prefix)_rd_specs_ptr")
        } else {
            // Allocate array for specifiers
            let count = statement.result.specifiers.count
            emit("  %\(prefix)_rd_specs_arr = alloca [\(count) x ptr]")
            for (i, spec) in statement.result.specifiers.enumerated() {
                let specStr = stringConstants[spec]!
                emit("  %\(prefix)_rd_spec_\(i)_ptr = getelementptr inbounds [\(count) x ptr], ptr %\(prefix)_rd_specs_arr, i32 0, i32 \(i)")
                emit("  store ptr \(specStr), ptr %\(prefix)_rd_spec_\(i)_ptr")
            }
            emit("  store ptr %\(prefix)_rd_specs_arr, ptr %\(prefix)_rd_specs_ptr")
        }

        // Store result specifier count
        emit("  %\(prefix)_rd_count_ptr = getelementptr inbounds %AROResultDescriptor, ptr %\(prefix)_result_desc, i32 0, i32 2")
        emit("  store i32 \(statement.result.specifiers.count), ptr %\(prefix)_rd_count_ptr")

        // Allocate object descriptor
        emit("  %\(prefix)_object_desc = alloca %AROObjectDescriptor")

        // Store object base name
        let objectBaseStr = stringConstants[statement.object.noun.base]!
        emit("  %\(prefix)_od_base_ptr = getelementptr inbounds %AROObjectDescriptor, ptr %\(prefix)_object_desc, i32 0, i32 0")
        emit("  store ptr \(objectBaseStr), ptr %\(prefix)_od_base_ptr")

        // Store preposition
        let prepValue = prepositionToInt(statement.object.preposition)
        emit("  %\(prefix)_od_prep_ptr = getelementptr inbounds %AROObjectDescriptor, ptr %\(prefix)_object_desc, i32 0, i32 1")
        emit("  store i32 \(prepValue), ptr %\(prefix)_od_prep_ptr")

        // Store object specifiers
        emit("  %\(prefix)_od_specs_ptr = getelementptr inbounds %AROObjectDescriptor, ptr %\(prefix)_object_desc, i32 0, i32 2")
        if statement.object.noun.specifiers.isEmpty {
            emit("  store ptr null, ptr %\(prefix)_od_specs_ptr")
        } else {
            let count = statement.object.noun.specifiers.count
            emit("  %\(prefix)_od_specs_arr = alloca [\(count) x ptr]")
            for (i, spec) in statement.object.noun.specifiers.enumerated() {
                let specStr = stringConstants[spec]!
                emit("  %\(prefix)_od_spec_\(i)_ptr = getelementptr inbounds [\(count) x ptr], ptr %\(prefix)_od_specs_arr, i32 0, i32 \(i)")
                emit("  store ptr \(specStr), ptr %\(prefix)_od_spec_\(i)_ptr")
            }
            emit("  store ptr %\(prefix)_od_specs_arr, ptr %\(prefix)_od_specs_ptr")
        }

        // Store object specifier count
        emit("  %\(prefix)_od_count_ptr = getelementptr inbounds %AROObjectDescriptor, ptr %\(prefix)_object_desc, i32 0, i32 3")
        emit("  store i32 \(statement.object.noun.specifiers.count), ptr %\(prefix)_od_count_ptr")

        // Call the action function
        let actionName = canonicalizeVerb(statement.action.verb.lowercased())
        emit("  %\(prefix)_action_result = call ptr @aro_action_\(actionName)(ptr \(currentContext), ptr %\(prefix)_result_desc, ptr %\(prefix)_object_desc)")

        // Store result
        emit("  store ptr %\(prefix)_action_result, ptr %__result")
        emit("")
    }

    private func emitLiteralBinding(_ literal: LiteralValue, prefix: String) throws {
        let literalNameStr = stringConstants["_literal_"]!

        switch literal {
        case .string(let s):
            let strConst = stringConstants[s]!
            emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(literalNameStr), ptr \(strConst))")

        case .integer(let i):
            emit("  call void @aro_variable_bind_int(ptr \(currentContext), ptr \(literalNameStr), i64 \(i))")

        case .float(let f):
            // Format double as hex for exact representation
            let bits = f.bitPattern
            emit("  call void @aro_variable_bind_double(ptr \(currentContext), ptr \(literalNameStr), double 0x\(String(bits, radix: 16, uppercase: true)))")

        case .boolean(let b):
            emit("  call void @aro_variable_bind_bool(ptr \(currentContext), ptr \(literalNameStr), i32 \(b ? 1 : 0))")

        case .null:
            // No binding needed
            break

        case .array:
            // Bind array as JSON string
            let jsonString = literalToJSON(literal)
            let jsonConst = stringConstants[jsonString]!
            emit("  call void @aro_variable_bind_array(ptr \(currentContext), ptr \(literalNameStr), ptr \(jsonConst))")

        case .object:
            // Bind object as JSON string
            let jsonString = literalToJSON(literal)
            let jsonConst = stringConstants[jsonString]!
            emit("  call void @aro_variable_bind_dict(ptr \(currentContext), ptr \(literalNameStr), ptr \(jsonConst))")

        case .regex:
            // Bind regex as JSON object with pattern and flags
            let jsonString = literalToJSON(literal)
            let jsonConst = stringConstants[jsonString]!
            emit("  call void @aro_variable_bind_dict(ptr \(currentContext), ptr \(literalNameStr), ptr \(jsonConst))")
        }
    }

    private func emitExpressionBinding(_ expression: any AROParser.Expression, prefix: String) throws {
        let exprNameStr = stringConstants["_expression_"]!

        // Handle literal expressions (most common case for "with" clause)
        if let literalExpr = expression as? LiteralExpression {
            switch literalExpr.value {
            case .string(let s):
                let strConst = stringConstants[s]!
                emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(exprNameStr), ptr \(strConst))")

            case .integer(let i):
                emit("  call void @aro_variable_bind_int(ptr \(currentContext), ptr \(exprNameStr), i64 \(i))")

            case .float(let f):
                let bits = f.bitPattern
                emit("  call void @aro_variable_bind_double(ptr \(currentContext), ptr \(exprNameStr), double 0x\(String(bits, radix: 16, uppercase: true)))")

            case .boolean(let b):
                emit("  call void @aro_variable_bind_bool(ptr \(currentContext), ptr \(exprNameStr), i32 \(b ? 1 : 0))")

            case .null:
                break

            case .array:
                // Bind array as JSON string
                let jsonString = literalToJSON(literalExpr.value)
                let jsonConst = stringConstants[jsonString]!
                emit("  call void @aro_variable_bind_array(ptr \(currentContext), ptr \(exprNameStr), ptr \(jsonConst))")

            case .object:
                // Bind object as JSON string
                let jsonString = literalToJSON(literalExpr.value)
                let jsonConst = stringConstants[jsonString]!
                emit("  call void @aro_variable_bind_dict(ptr \(currentContext), ptr \(exprNameStr), ptr \(jsonConst))")

            case .regex:
                // Bind regex as JSON object with pattern and flags
                let jsonString = literalToJSON(literalExpr.value)
                let jsonConst = stringConstants[jsonString]!
                emit("  call void @aro_variable_bind_dict(ptr \(currentContext), ptr \(exprNameStr), ptr \(jsonConst))")
            }
        } else if let varRefExpr = expression as? VariableRefExpression {
            // Variable reference expression: <user>, <user: id>, etc.
            // Resolve the variable and access specifiers if present
            let varName = varRefExpr.noun.base
            let varNameStr = stringConstants[varName]!

            emit("  ; Resolve variable reference <\(varName)> for expression binding")

            if varRefExpr.noun.specifiers.isEmpty {
                // Simple variable reference: <user>
                emit("  %\(prefix)_varref = call ptr @aro_variable_resolve(ptr \(currentContext), ptr \(varNameStr))")
                emit("  call void @aro_copy_value_to_expression(ptr \(currentContext), ptr %\(prefix)_varref)")
            } else {
                // Variable with specifiers: <user: name>
                emit("  %\(prefix)_varref_base = call ptr @aro_variable_resolve(ptr \(currentContext), ptr \(varNameStr))")
                // Access each specifier property
                for (specIdx, spec) in varRefExpr.noun.specifiers.enumerated() {
                    let specStr = stringConstants[spec]!
                    let prevPtr = specIdx == 0 ? "%\(prefix)_varref_base" : "%\(prefix)_varref_spec\(specIdx - 1)"
                    if specIdx == varRefExpr.noun.specifiers.count - 1 {
                        // Last specifier - store in final result
                        emit("  %\(prefix)_varref = call ptr @aro_dict_get(ptr \(prevPtr), ptr \(specStr))")
                    } else {
                        emit("  %\(prefix)_varref_spec\(specIdx) = call ptr @aro_dict_get(ptr \(prevPtr), ptr \(specStr))")
                    }
                }
                emit("  call void @aro_copy_value_to_expression(ptr \(currentContext), ptr %\(prefix)_varref)")
            }
        } else if let mapExpr = expression as? MapLiteralExpression {
            // Map literal expression: { key: value, ... }
            // Bind as JSON string and let runtime parse it
            let jsonString = mapExpressionToJSON(mapExpr)
            let jsonConst = stringConstants[jsonString]!
            emit("  ; Bind map expression as JSON")
            emit("  call void @aro_variable_bind_dict(ptr \(currentContext), ptr \(exprNameStr), ptr \(jsonConst))")
        } else if let arrayExpr = expression as? ArrayLiteralExpression {
            // Array literal expression: [elem1, elem2, ...]
            // Bind as JSON string and let runtime parse it
            let jsonString = arrayExpressionToJSON(arrayExpr)
            let jsonConst = stringConstants[jsonString]!
            emit("  ; Bind array expression as JSON")
            emit("  call void @aro_variable_bind_array(ptr \(currentContext), ptr \(exprNameStr), ptr \(jsonConst))")
        } else if let binaryExpr = expression as? BinaryExpression {
            // Binary expression: <a> + <b>, <x> * <y>, <s> ++ <t>, etc.
            // Serialize to JSON and evaluate at runtime
            let jsonString = binaryExpressionToJSON(binaryExpr)
            let jsonConst = stringConstants[jsonString]!
            emit("  ; Evaluate binary expression at runtime")
            emit("  call void @aro_evaluate_expression(ptr \(currentContext), ptr \(jsonConst))")
        } else if let groupedExpr = expression as? GroupedExpression {
            // Grouped expression: (expr) - evaluate the inner expression
            try emitExpressionBinding(groupedExpr.expression, prefix: prefix)
        } else if let interpolatedExpr = expression as? InterpolatedStringExpression {
            // Interpolated string: "Hello ${<name>}!"
            // Build the string by concatenating literal parts and resolved variable parts
            try emitInterpolatedStringBinding(interpolatedExpr, prefix: prefix)
        }
    }

    /// Emit LLVM IR to bind interpolated string expression
    /// Uses runtime's aro_interpolate_string() for simpler code generation
    private func emitInterpolatedStringBinding(_ interpolatedExpr: InterpolatedStringExpression, prefix: String) throws {
        let exprNameStr = stringConstants["_expression_"]!

        emit("  ; Interpolated string - using runtime interpolation")

        // Reconstruct the template string from parts
        var template = ""
        for part in interpolatedExpr.parts {
            switch part {
            case .literal(let str):
                template += str
            case .interpolation(let expr):
                // Only support simple variable references for now
                if let varRefExpr = expr as? VariableRefExpression {
                    template += "${\(varRefExpr.noun.base)}"
                } else {
                    // Fallback for complex expressions
                    template += "${}"
                }
            }
        }

        // Register template string and get constant
        registerString(template)
        let templateStr = stringConstants[template]!

        // Call aro_interpolate_string(context, template)
        emit("  %\(prefix)_interp_result = call ptr @aro_interpolate_string(ptr \(currentContext), ptr \(templateStr))")

        // Bind the result to _expression_
        emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(exprNameStr), ptr %\(prefix)_interp_result)")
    }

    /// Emit LLVM IR to bind aggregation clause context variables (ARO-0018)
    /// Binds _aggregation_type_ and optionally _aggregation_field_
    private func emitAggregationBinding(_ aggregation: AggregationClause, prefix: String) throws {
        let aggTypeNameStr = stringConstants["_aggregation_type_"]!
        let aggTypeValueStr = stringConstants[aggregation.type.rawValue]!

        emit("  ; ARO-0018: Bind aggregation type '\(aggregation.type.rawValue)'")
        emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(aggTypeNameStr), ptr \(aggTypeValueStr))")

        // Bind field if present (e.g., sum(<amount>))
        if let field = aggregation.field {
            let aggFieldNameStr = stringConstants["_aggregation_field_"]!
            let aggFieldValueStr = stringConstants[field]!
            emit("  ; ARO-0018: Bind aggregation field '\(field)'")
            emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(aggFieldNameStr), ptr \(aggFieldValueStr))")
        }
    }

    /// Emit LLVM IR to bind where clause context variables (ARO-0018)
    /// Binds _where_field_, _where_op_, _where_value_
    private func emitWhereClauseBinding(_ whereClause: WhereClause, prefix: String) throws {
        let whereFieldNameStr = stringConstants["_where_field_"]!
        let whereFieldValueStr = stringConstants[whereClause.field]!

        let whereOpNameStr = stringConstants["_where_op_"]!
        let whereOpValueStr = stringConstants[whereClause.op.rawValue]!

        emit("  ; ARO-0018: Bind where clause: <\(whereClause.field)> \(whereClause.op.rawValue) ...")
        emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(whereFieldNameStr), ptr \(whereFieldValueStr))")
        emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(whereOpNameStr), ptr \(whereOpValueStr))")

        // Bind where value - evaluate the expression and bind as _where_value_
        let whereValueNameStr = stringConstants["_where_value_"]!

        // Handle the where value expression
        if let literalExpr = whereClause.value as? LiteralExpression {
            switch literalExpr.value {
            case .string(let s):
                let strConst = stringConstants[s]!
                emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(whereValueNameStr), ptr \(strConst))")
            case .integer(let i):
                emit("  call void @aro_variable_bind_int(ptr \(currentContext), ptr \(whereValueNameStr), i64 \(i))")
            case .float(let f):
                let bits = f.bitPattern
                emit("  call void @aro_variable_bind_double(ptr \(currentContext), ptr \(whereValueNameStr), double 0x\(String(bits, radix: 16, uppercase: true)))")
            case .boolean(let b):
                emit("  call void @aro_variable_bind_bool(ptr \(currentContext), ptr \(whereValueNameStr), i32 \(b ? 1 : 0))")
            default:
                // Complex literals - bind as string
                let jsonString = literalToJSON(literalExpr.value)
                if let jsonConst = stringConstants[jsonString] {
                    emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(whereValueNameStr), ptr \(jsonConst))")
                }
            }
        } else if let varRefExpr = whereClause.value as? VariableRefExpression {
            // Variable reference - resolve and copy
            let varNameStr = stringConstants[varRefExpr.noun.base]!
            emit("  %\(prefix)_where_var = call ptr @aro_variable_resolve(ptr \(currentContext), ptr \(varNameStr))")
            emit("  call void @aro_variable_bind_value(ptr \(currentContext), ptr \(whereValueNameStr), ptr %\(prefix)_where_var)")
        }
    }

    /// Emit LLVM IR to bind by clause context variables (ARO-0037)
    /// Binds _by_pattern_, _by_flags_ for Split action
    private func emitByClauseBinding(_ byClause: ByClause, prefix: String) {
        let patternNameStr = stringConstants["_by_pattern_"]!
        let patternValueStr = stringConstants[byClause.pattern]!
        let flagsNameStr = stringConstants["_by_flags_"]!
        let flagsValueStr = stringConstants[byClause.flags]!

        emit("  ; ARO-0037: Bind by clause: /\(byClause.pattern)/\(byClause.flags)")
        emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(patternNameStr), ptr \(patternValueStr))")
        emit("  call void @aro_variable_bind_string(ptr \(currentContext), ptr \(flagsNameStr), ptr \(flagsValueStr))")
    }

    private func generatePublishStatement(_ statement: PublishStatement, index: Int) throws {
        let prefix = "p\(index)"

        emit("  ; Publish <\(statement.externalName)> as <\(statement.internalVariable)>")

        // Allocate result descriptor for external name
        emit("  %\(prefix)_result_desc = alloca %AROResultDescriptor")

        let extNameStr = stringConstants[statement.externalName]!
        emit("  %\(prefix)_rd_base_ptr = getelementptr inbounds %AROResultDescriptor, ptr %\(prefix)_result_desc, i32 0, i32 0")
        emit("  store ptr \(extNameStr), ptr %\(prefix)_rd_base_ptr")

        emit("  %\(prefix)_rd_specs_ptr = getelementptr inbounds %AROResultDescriptor, ptr %\(prefix)_result_desc, i32 0, i32 1")
        emit("  store ptr null, ptr %\(prefix)_rd_specs_ptr")

        emit("  %\(prefix)_rd_count_ptr = getelementptr inbounds %AROResultDescriptor, ptr %\(prefix)_result_desc, i32 0, i32 2")
        emit("  store i32 0, ptr %\(prefix)_rd_count_ptr")

        // Allocate object descriptor for internal variable
        emit("  %\(prefix)_object_desc = alloca %AROObjectDescriptor")

        let intNameStr = stringConstants[statement.internalVariable]!
        emit("  %\(prefix)_od_base_ptr = getelementptr inbounds %AROObjectDescriptor, ptr %\(prefix)_object_desc, i32 0, i32 0")
        emit("  store ptr \(intNameStr), ptr %\(prefix)_od_base_ptr")

        emit("  %\(prefix)_od_prep_ptr = getelementptr inbounds %AROObjectDescriptor, ptr %\(prefix)_object_desc, i32 0, i32 1")
        emit("  store i32 3, ptr %\(prefix)_od_prep_ptr")  // 3 = .with

        emit("  %\(prefix)_od_specs_ptr = getelementptr inbounds %AROObjectDescriptor, ptr %\(prefix)_object_desc, i32 0, i32 2")
        emit("  store ptr null, ptr %\(prefix)_od_specs_ptr")

        emit("  %\(prefix)_od_count_ptr = getelementptr inbounds %AROObjectDescriptor, ptr %\(prefix)_object_desc, i32 0, i32 3")
        emit("  store i32 0, ptr %\(prefix)_od_count_ptr")

        // Call publish action
        emit("  %\(prefix)_result = call ptr @aro_action_publish(ptr \(currentContext), ptr %\(prefix)_result_desc, ptr %\(prefix)_object_desc)")
        emit("  store ptr %\(prefix)_result, ptr %__result")
        emit("")
    }

    // MARK: - Match Statement Generation (ARO-0004)

    private func generateMatchStatement(_ statement: MatchStatement, index: Int) throws {
        let prefix = "m\(index)"
        let subjectName = statement.subject.base

        emit("  ; match <\(subjectName)>")

        // Resolve the subject value
        let subjectStr = stringConstants[subjectName]!
        emit("  %\(prefix)_subject_val = call ptr @aro_variable_resolve(ptr \(currentContext), ptr \(subjectStr))")
        emit("  %\(prefix)_subject_str = call ptr @aro_value_as_string(ptr %\(prefix)_subject_val)")

        // Generate labels for each case and the end
        let caseLabels = statement.cases.enumerated().map { "\(prefix)_case\($0.offset)" }
        let otherwiseLabel = "\(prefix)_otherwise"
        let endLabel = "\(prefix)_end"

        // Jump to first case
        if !statement.cases.isEmpty {
            emit("  br label %\(caseLabels[0])_check")
        } else if statement.otherwise != nil {
            emit("  br label %\(otherwiseLabel)")
        } else {
            emit("  br label %\(endLabel)")
        }
        emit("")

        // Generate each case
        for (caseIndex, caseClause) in statement.cases.enumerated() {
            let caseLabel = caseLabels[caseIndex]
            let nextLabel = caseIndex + 1 < statement.cases.count ?
                "\(caseLabels[caseIndex + 1])_check" :
                (statement.otherwise != nil ? otherwiseLabel : endLabel)

            // Case check block
            emit("\(caseLabel)_check:")

            switch caseClause.pattern {
            case .literal(let literalValue):
                switch literalValue {
                case .string(let s):
                    let patternStr = stringConstants[s]!
                    emit("  %\(caseLabel)_cmp = call i32 @strcmp(ptr %\(prefix)_subject_str, ptr \(patternStr))")
                    emit("  %\(caseLabel)_match = icmp eq i32 %\(caseLabel)_cmp, 0")
                case .integer(let i):
                    emit("  %\(caseLabel)_int_ptr = alloca i64")
                    emit("  %\(caseLabel)_int_ok = call i32 @aro_value_as_int(ptr %\(prefix)_subject_val, ptr %\(caseLabel)_int_ptr)")
                    emit("  %\(caseLabel)_int_val = load i64, ptr %\(caseLabel)_int_ptr")
                    emit("  %\(caseLabel)_match = icmp eq i64 %\(caseLabel)_int_val, \(i)")
                default:
                    // For other patterns, just skip to next
                    emit("  %\(caseLabel)_match = icmp eq i32 0, 1")  // Always false
                }
            case .wildcard:
                emit("  %\(caseLabel)_match = icmp eq i32 1, 1")  // Always true
            case .variable:
                emit("  %\(caseLabel)_match = icmp eq i32 0, 1")  // TODO: variable comparison
            case .regex(let pattern, let flags):
                // Register pattern and flags as strings
                let patternStr = stringConstants[pattern]!
                let flagsStr = stringConstants[flags]!
                emit("  %\(caseLabel)_match = call i1 @aro_regex_matches(ptr %\(prefix)_subject_str, ptr \(patternStr), ptr \(flagsStr))")
            }

            emit("  br i1 %\(caseLabel)_match, label %\(caseLabel)_body, label %\(nextLabel)")
            emit("")

            // Case body block
            emit("\(caseLabel)_body:")
            for (bodyIndex, bodyStatement) in caseClause.body.enumerated() {
                try generateStatement(bodyStatement, index: index * 100 + caseIndex * 10 + bodyIndex)
            }
            emit("  br label %\(endLabel)")
            emit("")
        }

        // Otherwise block
        if let otherwiseBody = statement.otherwise {
            emit("\(otherwiseLabel):")
            for (bodyIndex, bodyStatement) in otherwiseBody.enumerated() {
                try generateStatement(bodyStatement, index: index * 100 + 90 + bodyIndex)
            }
            emit("  br label %\(endLabel)")
            emit("")
        }

        // End block
        emit("\(endLabel):")
    }

    // MARK: - ForEach Loop Generation (ARO-0005)

    private func generateForEachLoop(_ loop: ForEachLoop, index: Int) throws {
        let prefix = "fe\(index)"

        if loop.isParallel {
            emit("  ; parallel for each <\(loop.itemVariable)> in <\(loop.collection.base)>")
            try generateParallelForEachLoop(loop, index: index, prefix: prefix)
            return
        }

        emit("  ; for each <\(loop.itemVariable)> in <\(loop.collection.base)>")

        // Get the collection variable name
        let collectionName = loop.collection.base
        let collectionStr = stringConstants[collectionName]!

        // Resolve collection - handle specifiers
        if loop.collection.specifiers.isEmpty {
            // Direct collection: <users>
            emit("  %\(prefix)_collection = call ptr @aro_variable_resolve(ptr \(currentContext), ptr \(collectionStr))")
        } else {
            // Collection with specifiers: <team: members>
            emit("  %\(prefix)_base = call ptr @aro_variable_resolve(ptr \(currentContext), ptr \(collectionStr))")
            // Access each specifier
            for (specIdx, spec) in loop.collection.specifiers.enumerated() {
                let specStr = stringConstants[spec]!
                let prevPtr = specIdx == 0 ? "%\(prefix)_base" : "%\(prefix)_spec\(specIdx - 1)"
                if specIdx == loop.collection.specifiers.count - 1 {
                    // Last specifier - store directly in _collection
                    emit("  %\(prefix)_collection = call ptr @aro_dict_get(ptr \(prevPtr), ptr \(specStr))")
                } else {
                    emit("  %\(prefix)_spec\(specIdx) = call ptr @aro_dict_get(ptr \(prevPtr), ptr \(specStr))")
                }
            }
        }

        // Check if collection is null
        emit("  %\(prefix)_col_null = icmp eq ptr %\(prefix)_collection, null")
        emit("  br i1 %\(prefix)_col_null, label %\(prefix)_end, label %\(prefix)_init")
        emit("")

        // Initialize loop
        emit("\(prefix)_init:")
        emit("  %\(prefix)_count = call i64 @aro_array_count(ptr %\(prefix)_collection)")
        emit("  %\(prefix)_has_items = icmp sgt i64 %\(prefix)_count, 0")
        emit("  br i1 %\(prefix)_has_items, label %\(prefix)_header, label %\(prefix)_end")
        emit("")

        // Loop header
        emit("\(prefix)_header:")
        emit("  %\(prefix)_i = phi i64 [ 0, %\(prefix)_init ], [ %\(prefix)_next_i, %\(prefix)_continue ]")

        // Create child context for this iteration to avoid immutability violations
        emit("  %\(prefix)_iter_ctx = call ptr @aro_context_create_child(ptr \(currentContext), ptr null)")

        // Get element at index
        emit("  %\(prefix)_element = call ptr @aro_array_get(ptr %\(prefix)_collection, i64 %\(prefix)_i)")

        // Bind element to item variable in the child context
        let itemVarStr = stringConstants[loop.itemVariable]!
        emit("  call void @aro_variable_bind_value(ptr %\(prefix)_iter_ctx, ptr \(itemVarStr), ptr %\(prefix)_element)")

        // Bind index variable if present
        if let indexVar = loop.indexVariable {
            let indexVarStr = stringConstants[indexVar]!
            emit("  call void @aro_variable_bind_int(ptr %\(prefix)_iter_ctx, ptr \(indexVarStr), i64 %\(prefix)_i)")
        }

        // Handle filter if present
        if let filter = loop.filter {
            let filterJSON = filterExpressionToJSON(filter, itemVar: loop.itemVariable)
            let filterStr = stringConstants[filterJSON]!
            emit("  %\(prefix)_filter_result = call i32 @aro_evaluate_filter(ptr %\(prefix)_iter_ctx, ptr \(filterStr))")
            emit("  %\(prefix)_passes_filter = icmp ne i32 %\(prefix)_filter_result, 0")
            emit("  br i1 %\(prefix)_passes_filter, label %\(prefix)_body, label %\(prefix)_cleanup")
            emit("")
            emit("\(prefix)_body:")
        } else {
            emit("  br label %\(prefix)_body")
            emit("")
            emit("\(prefix)_body:")
        }

        // Save current context and use child context for body
        let savedContext = currentContext
        currentContext = "%\(prefix)_iter_ctx"

        // Generate body statements
        for (bodyIndex, bodyStatement) in loop.body.enumerated() {
            try generateStatement(bodyStatement, index: index * 1000 + bodyIndex)
        }

        // Restore context
        currentContext = savedContext

        // Cleanup iteration context
        emit("  br label %\(prefix)_cleanup")
        emit("")
        emit("\(prefix)_cleanup:")
        emit("  call void @aro_context_destroy(ptr %\(prefix)_iter_ctx)")
        emit("  call void @aro_value_free(ptr %\(prefix)_element)")
        emit("  br label %\(prefix)_continue")
        emit("")

        // Continue to next iteration
        emit("\(prefix)_continue:")
        emit("  %\(prefix)_next_i = add i64 %\(prefix)_i, 1")
        emit("  %\(prefix)_done = icmp sge i64 %\(prefix)_next_i, %\(prefix)_count")
        emit("  br i1 %\(prefix)_done, label %\(prefix)_end, label %\(prefix)_header")
        emit("")

        // End loop
        emit("\(prefix)_end:")
        emit("")
    }

    /// Generate parallel for-each loop using runtime parallelization
    /// Generate parallel for-each loop using runtime parallelization with function pointers
    private func generateParallelForEachLoop(_ loop: ForEachLoop, index: Int, prefix: String) throws {
        // Get the collection variable name
        let collectionName = loop.collection.base
        let collectionStr = stringConstants[collectionName]!

        // Resolve collection - handle specifiers
        if loop.collection.specifiers.isEmpty {
            // Direct collection: <users>
            emit("  %\(prefix)_collection = call ptr @aro_variable_resolve(ptr \(currentContext), ptr \(collectionStr))")
        } else {
            // Collection with specifiers: <team: members>
            emit("  %\(prefix)_base = call ptr @aro_variable_resolve(ptr \(currentContext), ptr \(collectionStr))")
            // Access each specifier
            for (specIdx, spec) in loop.collection.specifiers.enumerated() {
                let specStr = stringConstants[spec]!
                let prevPtr = specIdx == 0 ? "%\(prefix)_base" : "%\(prefix)_spec\(specIdx - 1)"
                if specIdx == loop.collection.specifiers.count - 1 {
                    // Last specifier - store directly in _collection
                    emit("  %\(prefix)_collection = call ptr @aro_dict_get(ptr \(prevPtr), ptr \(specStr))")
                } else {
                    emit("  %\(prefix)_spec\(specIdx) = call ptr @aro_dict_get(ptr \(prevPtr), ptr \(specStr))")
                }
            }
        }

        // Check if collection is null
        emit("  %\(prefix)_col_null = icmp eq ptr %\(prefix)_collection, null")
        emit("  br i1 %\(prefix)_col_null, label %\(prefix)_end, label %\(prefix)_execute")
        emit("")

        emit("\(prefix)_execute:")

        // Generate unique loop body function name
        let bodyFuncName = "aro_loop_body_\(loopBodyCounter)"
        loopBodyCounter += 1

        // Determine concurrency value (0 = use System.coreCount)
        let concurrencyValue = loop.concurrency ?? 0

        // Get item and index variable name strings
        let itemVarStr = stringConstants[loop.itemVariable]!
        let indexVarStr = loop.indexVariable.map { stringConstants[$0]! }

        // Call parallel executor with function pointer
        emit("  ; Call parallel for-each executor")
        emit("  %\(prefix)_runtime = load ptr, ptr @global_runtime")
        if let indexStr = indexVarStr {
            emit("  %\(prefix)_result = call i32 @aro_parallel_for_each_execute(ptr %\(prefix)_runtime, ptr \(currentContext), ptr %\(prefix)_collection, ptr @\(bodyFuncName), i64 \(concurrencyValue), ptr \(itemVarStr), ptr \(indexStr))")
        } else {
            emit("  %\(prefix)_result = call i32 @aro_parallel_for_each_execute(ptr %\(prefix)_runtime, ptr \(currentContext), ptr %\(prefix)_collection, ptr @\(bodyFuncName), i64 \(concurrencyValue), ptr \(itemVarStr), ptr null)")
        }

        // Check for errors
        emit("  %\(prefix)_success = icmp eq i32 %\(prefix)_result, 0")
        emit("  br i1 %\(prefix)_success, label %\(prefix)_end, label %\(prefix)_error")
        emit("")

        emit("\(prefix)_error:")
        emit("  ; Parallel loop execution failed")
        emit("  br label %\(prefix)_end")
        emit("")

        emit("\(prefix)_end:")
        emit("  call void @aro_value_free(ptr %\(prefix)_collection)")
        emit("")

        // Store loop body for later emission after feature set
        pendingLoopBodies.append((bodyFuncName, loop, prefix))
    }

    /// Generate all pending loop body functions
    private func generatePendingLoopBodies() throws {
        for (bodyFuncName, loop, prefix) in pendingLoopBodies {
            try generateLoopBodyFunction(name: bodyFuncName, loop: loop, prefix: prefix)
        }
        pendingLoopBodies.removeAll()
    }

    /// Generate a separate function for a loop body
    /// Signature: ptr function(ptr context, ptr item, i64 index)
    private func generateLoopBodyFunction(name: String, loop: ForEachLoop, prefix: String) throws {
        emit("; Loop body function for parallel execution")
        emit("define ptr @\(name)(ptr %loop_ctx, ptr %loop_item, i64 %loop_index) {")
        emit("entry:")

        // Create local result variable
        emit("  %__result = alloca ptr")
        emit("  store ptr null, ptr %__result")
        emit("")

        // Bind item variable to context
        let itemVarStr = stringConstants[loop.itemVariable]!
        emit("  call void @aro_variable_bind_value(ptr %loop_ctx, ptr \(itemVarStr), ptr %loop_item)")

        // Bind index variable if present
        if let indexVar = loop.indexVariable {
            let indexVarStr = stringConstants[indexVar]!
            emit("  call void @aro_variable_bind_int(ptr %loop_ctx, ptr \(indexVarStr), i64 %loop_index)")
        }

        // Handle filter if present
        if let filter = loop.filter {
            let filterJSON = filterExpressionToJSON(filter, itemVar: loop.itemVariable)
            let filterStr = stringConstants[filterJSON]!
            emit("  %filter_result = call i32 @aro_evaluate_filter(ptr %loop_ctx, ptr \(filterStr))")
            emit("  %passes_filter = icmp ne i32 %filter_result, 0")
            emit("  br i1 %passes_filter, label %body_start, label %body_skip")
            emit("")
            emit("body_start:")
        }

        // Save current context and switch to loop context
        let savedContext = currentContext
        currentContext = "%loop_ctx"

        // Generate body statements
        for (bodyIndex, bodyStatement) in loop.body.enumerated() {
            try generateStatement(bodyStatement, index: bodyIndex)
        }

        // Restore context
        currentContext = savedContext

        // Return null (loop bodies don't return values)
        if loop.filter != nil {
            emit("  br label %body_end")
            emit("")
            emit("body_skip:")
            emit("  br label %body_end")
            emit("")
            emit("body_end:")
        }
        emit("  ret ptr null")
        emit("}")
        emit("")
    }

    /// Convert a filter expression to JSON for runtime evaluation
    /// Handles expressions like: <user: active> is true
    private func filterExpressionToJSON(_ expr: any AROParser.Expression, itemVar: String) -> String {
        // Most filters are binary expressions: <user: active> is true, <user: active> == true, etc.
        if let binaryExpr = expr as? BinaryExpression {
            return binaryExpressionToJSON(binaryExpr)
        }
        // Type check expression: <user: active> is boolean
        if let typeCheck = expr as? TypeCheckExpression {
            let inner = expressionToEvalJSON(typeCheck.expression)
            return "{\"$typecheck\":{\"expr\":\(inner),\"type\":\"\(typeCheck.typeName)\"}}"
        }
        // Fallback: evaluate as-is
        return expressionToEvalJSON(expr)
    }

    // MARK: - Observer Registration

    /// Scan program for repository observers
    /// Returns array of tuples: (repository name, feature set)
    private func scanRepositoryObservers(_ program: AnalyzedProgram) -> [(repositoryName: String, featureSet: AnalyzedFeatureSet)] {
        var observers: [(String, AnalyzedFeatureSet)] = []

        for analyzedFS in program.featureSets {
            let activity = analyzedFS.featureSet.businessActivity

            // Match pattern: "{repository-name} Observer"
            // Examples: "directory-repository Observer", "user-repository Observer"
            if activity.contains(" Observer") && activity.contains("-repository") {
                // Extract repository name from "directory-repository Observer"
                let parts = activity.split(separator: " ")
                if let repoIndex = parts.firstIndex(where: { $0.hasSuffix("-repository") }) {
                    let repositoryName = String(parts[repoIndex])
                    observers.append((repositoryName, analyzedFS))
                }
            }
        }

        return observers
    }

    // MARK: - Main Function Generation

    private func generateMain(program: AnalyzedProgram) throws {
        // Verify Application-Start exists
        guard program.featureSets.contains(where: { $0.featureSet.name == "Application-Start" }) else {
            throw LLVMCodeGeneratorError.noEntryPoint
        }

        let entryFuncName = mangleFeatureSetName("Application-Start")
        let appStartStr = stringConstants["Application-Start"]!

        emit("; Main entry point")
        emit("define i32 @main(i32 %argc, ptr %argv) {")
        emit("entry:")

        // Initialize runtime
        emit("  %runtime = call ptr @aro_runtime_init()")

        // Store runtime pointer in global variable for parallel execution
        emit("  store ptr %runtime, ptr @global_runtime")

        // Check runtime initialization
        emit("  %runtime_null = icmp eq ptr %runtime, null")
        emit("  br i1 %runtime_null, label %runtime_fail, label %runtime_ok")
        emit("")

        emit("runtime_fail:")
        emit("  ret i32 1")
        emit("")

        emit("runtime_ok:")
        // Set embedded OpenAPI spec if available
        if let specJSON = openAPISpecJSON {
            let specStr = stringConstants[specJSON]!
            emit("  ; Set embedded OpenAPI spec")
            emit("  call void @aro_set_embedded_openapi(ptr \(specStr))")
            emit("")
        }

        // Load pre-compiled plugins from the binary's directory
        emit("  %plugin_result = call i32 @aro_load_precompiled_plugins()")
        emit("")
        // Create named context
        emit("  %ctx = call ptr @aro_context_create_named(ptr %runtime, ptr \(appStartStr))")

        // Check context creation
        emit("  %ctx_null = icmp eq ptr \(currentContext), null")
        emit("  br i1 %ctx_null, label %ctx_fail, label %ctx_ok")
        emit("")

        emit("ctx_fail:")
        emit("  call void @aro_runtime_shutdown(ptr %runtime)")
        emit("  ret i32 1")
        emit("")

        emit("ctx_ok:")

        // Register event handlers before executing Application-Start
        emit("  ; Register event handlers")
        for featureSet in program.featureSets {
            let activity = featureSet.featureSet.businessActivity

            // Find handler feature sets (but not Socket/File handlers or Application-End)
            let hasHandler = activity.contains(" Handler")
            let isSpecialHandler = activity.contains("Socket Event Handler") ||
                                   activity.contains("File Event Handler") ||
                                   activity.contains("Application-End")

            guard hasHandler && !isSpecialHandler else { continue }

            // Extract event type from business activity
            // e.g., "UserCreated Handler" -> "UserCreated"
            // e.g., "NumberTriggered Handler" -> "NumberTriggered"
            guard let handlerRange = activity.range(of: " Handler") else { continue }
            let eventType = String(activity[..<handlerRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)

            guard let eventTypeStr = stringConstants[eventType] else { continue }

            let handlerFuncName = mangleFeatureSetName(featureSet.featureSet.name)

            emit("  ; Register handler '\(featureSet.featureSet.name)' for event '\(eventType)'")
            emit("  call void @aro_runtime_register_handler(ptr %runtime, ptr \(eventTypeStr), ptr @\(handlerFuncName))")
        }
        emit("")

        // Register repository observers
        emit("  ; Register repository observers")
        let observers = scanRepositoryObservers(program)
        for (repositoryName, observerFS) in observers {
            // Get observer function name
            let observerFuncName = mangleFeatureSetName(observerFS.featureSet.name)

            // Get repository name string constant (registered during collection phase)
            guard let repoNameStr = stringConstants[repositoryName] else {
                continue
            }

            emit("  ; Register observer '\(observerFS.featureSet.name)' for repository '\(repositoryName)'")
            emit("  call void @aro_register_repository_observer(ptr %runtime, ptr \(repoNameStr), ptr @\(observerFuncName))")
        }
        emit("")

        // Execute Application-Start
        emit("  %result = call ptr @\(entryFuncName)(ptr \(currentContext))")

        // CRITICAL: Wait for all in-flight event handlers to complete
        // This ensures events emitted during Application-Start finish executing
        emit("  ; Wait for pending event handlers (timeout: 10 seconds)")
        emit("  %await_result = call i32 @aro_runtime_await_pending_events(ptr %runtime, double 1.000000e+01)")
        emit("  %timeout_occurred = icmp eq i32 %await_result, 0")
        emit("  br i1 %timeout_occurred, label %warn_timeout, label %continue_shutdown")
        emit("")

        emit("warn_timeout:")
        let warnMsgStr = stringConstants["Event handlers did not complete within timeout"]!
        emit("  call void @aro_log_warning(ptr \(warnMsgStr))")
        emit("  br label %continue_shutdown")
        emit("")

        emit("continue_shutdown:")
        // Print the response (if any) before cleanup
        emit("  call void @aro_context_print_response(ptr \(currentContext))")

        // Check if result needs to be freed
        emit("  %result_null = icmp eq ptr %result, null")
        emit("  br i1 %result_null, label %cleanup, label %free_result")
        emit("")

        emit("free_result:")
        emit("  call void @aro_value_free(ptr %result)")
        emit("  br label %cleanup")
        emit("")

        emit("cleanup:")
        emit("  call void @aro_context_destroy(ptr \(currentContext))")
        emit("  call void @aro_runtime_shutdown(ptr %runtime)")
        emit("  ret i32 0")
        emit("}")
    }

    // MARK: - Helper Methods

    private func emit(_ line: String) {
        output += line + "\n"
    }

    private func mangleFeatureSetName(_ name: String) -> String {
        return "aro_fs_" + name
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private func canonicalizeVerb(_ verb: String) -> String {
        // NOTE: "map", "filter", "reduce" are NOT synonyms - they are their own
        // data pipeline actions (ARO-0018). Do not map them to other verbs.
        let mapping: [String: String] = [
            "calculate": "compute", "derive": "compute",
            "verify": "validate", "check": "validate",
            "match": "compare",
            "convert": "transform",
            "make": "create", "build": "create", "construct": "create",
            "modify": "update", "change": "update", "set": "update",
            "respond": "return",
            "raise": "throw", "fail": "throw",
            "dispatch": "send",
            "print": "log", "output": "log", "debug": "log",
            "save": "store", "persist": "store",
            "export": "publish", "expose": "publish", "share": "publish",
            "initialize": "start", "boot": "start",
            "await": "listen", "wait": "listen",
            "forward": "route",
            "monitor": "watch", "observe": "watch"
        ]
        return mapping[verb] ?? verb
    }

    private func prepositionToInt(_ preposition: Preposition) -> Int {
        switch preposition {
        case .from: return 1
        case .for: return 2
        case .with: return 3
        case .to: return 4
        case .into: return 5
        case .via: return 6
        case .against: return 7
        case .on: return 8
        case .by: return 9
        case .at: return 10
        }
    }

    private func escapeStringForLLVM(_ str: String) -> String {
        var result = ""
        for char in str.utf8 {
            switch char {
            case 0x00...0x1F, 0x7F...0xFF, 0x22, 0x5C:
                // Control chars, DEL, extended ASCII, quote, backslash
                result += String(format: "\\%02X", char)
            default:
                result += String(Character(UnicodeScalar(char)))
            }
        }
        return result
    }
}

// MARK: - Code Generator Errors

public enum LLVMCodeGeneratorError: Error, CustomStringConvertible {
    case noEntryPoint
    case unsupportedAction(String)
    case invalidType(String)
    case compilationFailed(String)

    public var description: String {
        switch self {
        case .noEntryPoint:
            return "No Application-Start feature set found"
        case .unsupportedAction(let verb):
            return "Unsupported action verb: \(verb)"
        case .invalidType(let type):
            return "Invalid type: \(type)"
        case .compilationFailed(let message):
            return "Compilation failed: \(message)"
        }
    }
}
