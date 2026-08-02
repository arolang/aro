// ============================================================
// ModifierBinder.swift
// ARO Compiler - Query / range / value-source binding into the runtime context
// ============================================================

#if !os(Windows)
import SwiftyLLVM
import AROParser

/// Emits the IR that binds a statement's query modifiers, range modifiers, and
/// value source into the runtime execution context before the action call.
///
/// Extracted from `LLVMCodeGenerator` (issue #334). Holds references to the
/// shared codegen context, the external declaration emitter, and the
/// expression serializer (composition, mirroring `LLVMExternalDeclEmitter`).
struct ModifierBinder {
    private let ctx: LLVMCodeGenContext
    private let externals: LLVMExternalDeclEmitter
    private let serializer: ExpressionSerializer

    init(
        context: LLVMCodeGenContext,
        externals: LLVMExternalDeclEmitter,
        serializer: ExpressionSerializer
    ) {
        self.ctx = context
        self.externals = externals
        self.serializer = serializer
    }

    // MARK: - Value Source Binding

    func bindValueSource(_ valueSource: ValueSource, prefix: String) {
        let ip = ctx.insertionPoint

        switch valueSource {
        case .none:
            // No binding needed
            break

        case .literal(let literal):
            bindLiteral(literal)

        case .expression(let expr):
            // Serialize expression (with constant folding if applicable)
            let exprJSON = ctx.stringConstant(serializer.serializeExpression(expr))
            _ = ctx.module.insertCall(
                externals.evaluateExpression,
                on: [ctx.currentContextVar!, exprJSON],
                at: ip
            )

        case .sinkExpression(let expr):
            // Sink expression: evaluate and bind to _result_expression_ for LogAction/response actions
            // Constant folding happens in serializeExpression (GitLab #102)
            let resultExprName = ctx.stringConstant("_result_expression_")
            let exprJSON = ctx.stringConstant(serializer.serializeExpression(expr))
            _ = ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, resultExprName, exprJSON],
                at: ip
            )
        }
    }

    // MARK: - Query and Range Modifiers Binding

    func bindQueryModifiers(_ modifiers: QueryModifiers) {
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
            let valueJSON = ctx.stringConstant(serializer.serializeExpression(whereClause.value))
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

        // Bind by clause if present (for Split action with regex, or Group action with field name)
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

            // Bind _by_field_ for Group action (field-based grouping)
            if byClause.isFieldName {
                let fieldName = ctx.stringConstant("_by_field_")
                let fieldValue = ctx.stringConstant(byClause.pattern)
                _ = ctx.module.insertCall(
                    externals.variableBindString,
                    on: [ctx.currentContextVar!, fieldName, fieldValue],
                    at: ip
                )
            }
        }

        // Bind default value if present (for optional retrieve with fallback)
        if let defaultExpr = modifiers.defaultValue {
            let defaultName = ctx.stringConstant("_default_value_")
            let defaultJSON = ctx.stringConstant(serializer.serializeExpression(defaultExpr))
            _ = ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, defaultName, defaultJSON],
                at: ip
            )
        }
    }

    func bindRangeModifiers(_ modifiers: RangeModifiers) {
        guard !modifiers.isEmpty else { return }
        let ip = ctx.insertionPoint

        // Bind to clause if present (e.g., date range end) - evaluate expression
        if let toClause = modifiers.toClause {
            let toName = ctx.stringConstant("_to_")
            let toJSON = ctx.stringConstant(serializer.serializeExpression(toClause))
            _ = ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, toName, toJSON],
                at: ip
            )
        }

        // Bind with clause if present (e.g., set operations) - evaluate expression
        if let withClause = modifiers.withClause {
            let withName = ctx.stringConstant("_with_")
            let withJSON = ctx.stringConstant(serializer.serializeExpression(withClause))
            _ = ctx.module.insertCall(
                externals.evaluateAndBind,
                on: [ctx.currentContextVar!, withName, withJSON],
                at: ip
            )
        }
    }

    // MARK: - Literal Binding

    func bindLiteral(_ literal: LiteralValue) {
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
            let json = serializer.serializeLiteralArrayPlain(elements)
            let jsonStr = ctx.stringConstant(json)
            _ = ctx.module.insertCall(
                externals.variableBindArray,
                on: [ctx.currentContextVar!, literalVar, jsonStr],
                at: ip
            )

        case .object(let entries):
            // Serialize object as plain JSON (not expression-wrapped) for variableBindDict
            let json = serializer.serializeLiteralObjectPlain(entries)
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
}

#endif
