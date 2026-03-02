// ============================================================
// LLVMExternalDeclEmitter.swift
// ARO Compiler - External Function Declaration Emitter
// ============================================================

#if !os(Windows)
import SwiftyLLVM
import AROParser

/// Declares external functions from the ARO runtime bridge
public final class LLVMExternalDeclEmitter {
    private let ctx: LLVMCodeGenContext
    private let types: LLVMTypeMapper

    // MARK: - Cached Function References

    // Runtime lifecycle
    private var _runtimeInit: Function?
    private var _runtimeShutdown: Function?
    private var _runtimeAwaitPendingEvents: Function?
    private var _runtimeRegisterHandler: Function?
    private var _parseArguments: Function?
    private var _hasKeepAlive: Function?
    private var _registerRepositoryObserver: Function?
    private var _registerRepositoryObserverWithGuard: Function?
    private var _registerFeatureSetMetadata: Function?
    private var _logWarning: Function?
    private var _contextCreate: Function?
    private var _contextCreateNamed: Function?
    private var _contextCreateChild: Function?
    private var _contextDestroy: Function?
    private var _contextPrintResponse: Function?
    private var _contextHasError: Function?
    private var _contextPrintError: Function?
    private var _loadPrecompiledPlugins: Function?
    private var _setEmbeddedOpenapi: Function?
    private var _setEmbeddedTemplates: Function?

    // Variable operations
    private var _variableBindString: Function?
    private var _variableBindInt: Function?
    private var _variableBindDouble: Function?
    private var _variableBindBool: Function?
    private var _variableBindDict: Function?
    private var _variableBindArray: Function?
    private var _variableBindValue: Function?
    private var _variableUnbind: Function?
    private var _variableResolve: Function?
    private var _variableResolveString: Function?
    private var _variableResolveInt: Function?
    private var _copyValueToExpression: Function?
    private var _valueFree: Function?
    private var _valueAsString: Function?
    private var _valueAsInt: Function?
    private var _stringConcat: Function?
    private var _interpolateString: Function?
    private var _evaluateWhenGuard: Function?
    private var _evaluateExpression: Function?
    private var _evaluateAndBind: Function?
    private var _evaluateFilter: Function?
    private var _matchPattern: Function?
    private var _valueCreateInt: Function?

    // Collection operations
    private var _arrayCount: Function?
    private var _arrayGet: Function?
    private var _dictGet: Function?
    private var _parallelForEachExecute: Function?

    // Standard library
    private var _strcmp: Function?

    // Action functions cache
    private var actionFunctions: [String: Function] = [:]

    // Dynamic action function for plugin-provided actions
    private var _actionDynamic: Function?

    // MARK: - Initialization

    public init(context: LLVMCodeGenContext, types: LLVMTypeMapper) {
        self.ctx = context
        self.types = types
    }

    // MARK: - Declare All External Functions

    /// Declares all external functions needed by the generated code
    public func declareAllExternals() {
        declareRuntimeLifecycle()
        declareVariableOperations()
        declareCollectionOperations()
        declareAllActionFunctions()
        declareStandardLibrary()
    }

    // MARK: - Runtime Lifecycle

    private func declareRuntimeLifecycle() {
        let ptr = ctx.ptrType
        let i32 = ctx.i32Type
        let double = ctx.doubleType

        // ptr @aro_runtime_init()
        _runtimeInit = ctx.module.declareFunction(
            "aro_runtime_init",
            types.functionType(parameters: [], returning: ptr)
        )

        // void @aro_runtime_shutdown(ptr)
        _runtimeShutdown = ctx.module.declareFunction(
            "aro_runtime_shutdown",
            types.voidFunctionType(parameters: [ptr])
        )

        // i32 @aro_runtime_await_pending_events(ptr, double)
        _runtimeAwaitPendingEvents = ctx.module.declareFunction(
            "aro_runtime_await_pending_events",
            types.functionType(parameters: [ptr, double], returning: i32)
        )

        // void @aro_runtime_register_handler(ptr, ptr, ptr)
        _runtimeRegisterHandler = ctx.module.declareFunction(
            "aro_runtime_register_handler",
            types.voidFunctionType(parameters: [ptr, ptr, ptr])
        )

        // void @aro_parse_arguments(i32, ptr) - ARO-0047
        _parseArguments = ctx.module.declareFunction(
            "aro_parse_arguments",
            types.voidFunctionType(parameters: [i32, ptr])
        )

        // i32 @aro_has_keep_alive() - Check for --keep-alive flag
        _hasKeepAlive = ctx.module.declareFunction(
            "aro_has_keep_alive",
            types.functionType(parameters: [], returning: i32)
        )

        // void @aro_register_repository_observer(ptr, ptr, ptr)
        _registerRepositoryObserver = ctx.module.declareFunction(
            "aro_register_repository_observer",
            types.voidFunctionType(parameters: [ptr, ptr, ptr])
        )

        // void @aro_register_repository_observer_with_guard(ptr, ptr, ptr, ptr)
        _registerRepositoryObserverWithGuard = ctx.module.declareFunction(
            "aro_register_repository_observer_with_guard",
            types.voidFunctionType(parameters: [ptr, ptr, ptr, ptr])
        )

        // void @aro_register_feature_set_metadata(ptr, ptr)
        _registerFeatureSetMetadata = ctx.module.declareFunction(
            "aro_register_feature_set_metadata",
            types.voidFunctionType(parameters: [ptr, ptr])
        )

        // void @aro_log_warning(ptr)
        _logWarning = ctx.module.declareFunction(
            "aro_log_warning",
            types.voidFunctionType(parameters: [ptr])
        )

        // ptr @aro_context_create(ptr)
        _contextCreate = ctx.module.declareFunction(
            "aro_context_create",
            types.functionType(parameters: [ptr], returning: ptr)
        )

        // ptr @aro_context_create_named(ptr, ptr)
        _contextCreateNamed = ctx.module.declareFunction(
            "aro_context_create_named",
            types.functionType(parameters: [ptr, ptr], returning: ptr)
        )

        // ptr @aro_context_create_child(ptr, ptr)
        _contextCreateChild = ctx.module.declareFunction(
            "aro_context_create_child",
            types.functionType(parameters: [ptr, ptr], returning: ptr)
        )

        // void @aro_context_destroy(ptr)
        _contextDestroy = ctx.module.declareFunction(
            "aro_context_destroy",
            types.voidFunctionType(parameters: [ptr])
        )

        // void @aro_context_print_response(ptr)
        _contextPrintResponse = ctx.module.declareFunction(
            "aro_context_print_response",
            types.voidFunctionType(parameters: [ptr])
        )

        // i32 @aro_context_has_error(ptr)
        _contextHasError = ctx.module.declareFunction(
            "aro_context_has_error",
            types.functionType(parameters: [ptr], returning: i32)
        )

        // void @aro_context_print_error(ptr)
        _contextPrintError = ctx.module.declareFunction(
            "aro_context_print_error",
            types.voidFunctionType(parameters: [ptr])
        )

        // i32 @aro_load_precompiled_plugins()
        _loadPrecompiledPlugins = ctx.module.declareFunction(
            "aro_load_precompiled_plugins",
            types.functionType(parameters: [], returning: i32)
        )

        // void @aro_set_embedded_openapi(ptr)
        _setEmbeddedOpenapi = ctx.module.declareFunction(
            "aro_set_embedded_openapi",
            types.voidFunctionType(parameters: [ptr])
        )

        // void @aro_set_embedded_templates(ptr) - ARO-0050
        _setEmbeddedTemplates = ctx.module.declareFunction(
            "aro_set_embedded_templates",
            types.voidFunctionType(parameters: [ptr])
        )
    }

    // MARK: - Variable Operations

    private func declareVariableOperations() {
        let ptr = ctx.ptrType
        let i32 = ctx.i32Type
        let i64 = ctx.i64Type
        let double = ctx.doubleType

        // void @aro_variable_bind_string(ptr, ptr, ptr)
        _variableBindString = ctx.module.declareFunction(
            "aro_variable_bind_string",
            types.voidFunctionType(parameters: [ptr, ptr, ptr])
        )

        // void @aro_variable_bind_int(ptr, ptr, i64)
        _variableBindInt = ctx.module.declareFunction(
            "aro_variable_bind_int",
            types.voidFunctionType(parameters: [ptr, ptr, i64])
        )

        // void @aro_variable_bind_double(ptr, ptr, double)
        _variableBindDouble = ctx.module.declareFunction(
            "aro_variable_bind_double",
            types.voidFunctionType(parameters: [ptr, ptr, double])
        )

        // void @aro_variable_bind_bool(ptr, ptr, i32)
        _variableBindBool = ctx.module.declareFunction(
            "aro_variable_bind_bool",
            types.voidFunctionType(parameters: [ptr, ptr, i32])
        )

        // void @aro_variable_bind_dict(ptr, ptr, ptr)
        _variableBindDict = ctx.module.declareFunction(
            "aro_variable_bind_dict",
            types.voidFunctionType(parameters: [ptr, ptr, ptr])
        )

        // void @aro_variable_bind_array(ptr, ptr, ptr)
        _variableBindArray = ctx.module.declareFunction(
            "aro_variable_bind_array",
            types.voidFunctionType(parameters: [ptr, ptr, ptr])
        )

        // void @aro_variable_bind_value(ptr, ptr, ptr)
        _variableBindValue = ctx.module.declareFunction(
            "aro_variable_bind_value",
            types.voidFunctionType(parameters: [ptr, ptr, ptr])
        )

        // void @aro_variable_unbind(ptr, ptr)
        _variableUnbind = ctx.module.declareFunction(
            "aro_variable_unbind",
            types.voidFunctionType(parameters: [ptr, ptr])
        )

        // ptr @aro_variable_resolve(ptr, ptr)
        _variableResolve = ctx.module.declareFunction(
            "aro_variable_resolve",
            types.functionType(parameters: [ptr, ptr], returning: ptr)
        )

        // ptr @aro_variable_resolve_string(ptr, ptr)
        _variableResolveString = ctx.module.declareFunction(
            "aro_variable_resolve_string",
            types.functionType(parameters: [ptr, ptr], returning: ptr)
        )

        // i32 @aro_variable_resolve_int(ptr, ptr, ptr)
        _variableResolveInt = ctx.module.declareFunction(
            "aro_variable_resolve_int",
            types.functionType(parameters: [ptr, ptr, ptr], returning: i32)
        )

        // void @aro_copy_value_to_expression(ptr, ptr)
        _copyValueToExpression = ctx.module.declareFunction(
            "aro_copy_value_to_expression",
            types.voidFunctionType(parameters: [ptr, ptr])
        )

        // void @aro_value_free(ptr)
        _valueFree = ctx.module.declareFunction(
            "aro_value_free",
            types.voidFunctionType(parameters: [ptr])
        )

        // ptr @aro_value_as_string(ptr)
        _valueAsString = ctx.module.declareFunction(
            "aro_value_as_string",
            types.functionType(parameters: [ptr], returning: ptr)
        )

        // i32 @aro_value_as_int(ptr, ptr)
        _valueAsInt = ctx.module.declareFunction(
            "aro_value_as_int",
            types.functionType(parameters: [ptr, ptr], returning: i32)
        )

        // ptr @aro_string_concat(ptr, ptr)
        _stringConcat = ctx.module.declareFunction(
            "aro_string_concat",
            types.functionType(parameters: [ptr, ptr], returning: ptr)
        )

        // ptr @aro_interpolate_string(ptr, ptr)
        _interpolateString = ctx.module.declareFunction(
            "aro_interpolate_string",
            types.functionType(parameters: [ptr, ptr], returning: ptr)
        )

        // i32 @aro_evaluate_when_guard(ptr, ptr)
        _evaluateWhenGuard = ctx.module.declareFunction(
            "aro_evaluate_when_guard",
            types.functionType(parameters: [ptr, ptr], returning: i32)
        )

        // void @aro_evaluate_expression(ptr, ptr)
        _evaluateExpression = ctx.module.declareFunction(
            "aro_evaluate_expression",
            types.voidFunctionType(parameters: [ptr, ptr])
        )

        // void @aro_evaluate_and_bind(ptr, ptr, ptr)
        _evaluateAndBind = ctx.module.declareFunction(
            "aro_evaluate_and_bind",
            types.voidFunctionType(parameters: [ptr, ptr, ptr])
        )

        // i32 @aro_evaluate_filter(ptr, ptr)
        _evaluateFilter = ctx.module.declareFunction(
            "aro_evaluate_filter",
            types.functionType(parameters: [ptr, ptr], returning: i32)
        )

        // i32 @aro_match_pattern(ptr, ptr, ptr)
        _matchPattern = ctx.module.declareFunction(
            "aro_match_pattern",
            types.functionType(parameters: [ptr, ptr, ptr], returning: i32)
        )

        // ptr @aro_value_create_int(i64)
        _valueCreateInt = ctx.module.declareFunction(
            "aro_value_create_int",
            types.functionType(parameters: [i64], returning: ptr)
        )
    }

    // MARK: - Collection Operations

    private func declareCollectionOperations() {
        let ptr = ctx.ptrType
        let i32 = ctx.i32Type
        let i64 = ctx.i64Type

        // i64 @aro_array_count(ptr)
        _arrayCount = ctx.module.declareFunction(
            "aro_array_count",
            types.functionType(parameters: [ptr], returning: i64)
        )

        // ptr @aro_array_get(ptr, i64)
        _arrayGet = ctx.module.declareFunction(
            "aro_array_get",
            types.functionType(parameters: [ptr, i64], returning: ptr)
        )

        // ptr @aro_dict_get(ptr, ptr)
        _dictGet = ctx.module.declareFunction(
            "aro_dict_get",
            types.functionType(parameters: [ptr, ptr], returning: ptr)
        )

        // i32 @aro_parallel_for_each_execute(ptr, ptr, ptr, ptr, i64, ptr, ptr)
        _parallelForEachExecute = ctx.module.declareFunction(
            "aro_parallel_for_each_execute",
            types.functionType(parameters: [ptr, ptr, ptr, ptr, i64, ptr, ptr], returning: i32)
        )
    }

    // MARK: - Action Functions

    /// All action function names
    private static let actionNames: [String] = [
        // Request actions
        "extract", "fetch", "retrieve", "parse", "parsehtml", "read", "request", "receive",
        // Own actions
        "compute", "validate", "compare", "transform", "create", "update", "accept",
        // Response actions
        "return", "throw", "emit", "send", "log", "store", "write", "publish",
        // Server actions
        "start", "listen", "route", "watch", "stop", "keepalive", "broadcast", "connect",
        // External call
        "call",
        // Data pipeline (ARO-0018)
        "filter", "reduce", "map",
        // Sort
        "sort", "order", "arrange",
        // System exec (ARO-0033)
        "exec", "shell",
        // Repository
        "delete", "merge", "combine", "join", "concat", "close",
        // String (ARO-0037)
        "split",
        // File operations (ARO-0036)
        "list", "stat", "exists", "make", "touch", "createdirectory", "mkdir",
        "copy", "move", "rename", "append",
        // Configuration
        "configure",
        // Notifications
        "notify", "alert", "signal"
    ]

    private func declareAllActionFunctions() {
        let actionType = types.actionFunctionType

        for name in Self.actionNames {
            let funcName = "aro_action_\(name)"
            let func_ = ctx.module.declareFunction(funcName, actionType)
            actionFunctions[name] = func_
        }

        // Dynamic action function for plugin-provided custom actions
        // ptr @aro_action_dynamic(ptr verb, ptr ctx, ptr result_desc, ptr object_desc)
        let ptr = ctx.ptrType
        let dynamicActionType = types.functionType(
            parameters: [ptr, ptr, ptr, ptr],
            returning: ptr
        )
        _actionDynamic = ctx.module.declareFunction("aro_action_dynamic", dynamicActionType)
    }

    // MARK: - Standard Library

    private func declareStandardLibrary() {
        let ptr = ctx.ptrType
        let i32 = ctx.i32Type

        // i32 @strcmp(ptr, ptr)
        _strcmp = ctx.module.declareFunction(
            "strcmp",
            types.functionType(parameters: [ptr, ptr], returning: i32)
        )
    }

    // MARK: - Public Accessors

    // Runtime lifecycle
    public var runtimeInit: Function { _runtimeInit! }
    public var runtimeShutdown: Function { _runtimeShutdown! }
    public var runtimeAwaitPendingEvents: Function { _runtimeAwaitPendingEvents! }
    public var runtimeRegisterHandler: Function { _runtimeRegisterHandler! }
    public var parseArguments: Function { _parseArguments! }
    public var hasKeepAlive: Function { _hasKeepAlive! }
    public var registerRepositoryObserver: Function { _registerRepositoryObserver! }
    public var registerRepositoryObserverWithGuard: Function { _registerRepositoryObserverWithGuard! }
    public var registerFeatureSetMetadata: Function { _registerFeatureSetMetadata! }
    public var logWarning: Function { _logWarning! }
    public var contextCreate: Function { _contextCreate! }
    public var contextCreateNamed: Function { _contextCreateNamed! }
    public var contextCreateChild: Function { _contextCreateChild! }
    public var contextDestroy: Function { _contextDestroy! }
    public var contextPrintResponse: Function { _contextPrintResponse! }
    public var contextHasError: Function { _contextHasError! }
    public var contextPrintError: Function { _contextPrintError! }
    public var loadPrecompiledPlugins: Function { _loadPrecompiledPlugins! }
    public var setEmbeddedOpenapi: Function { _setEmbeddedOpenapi! }
    public var setEmbeddedTemplates: Function { _setEmbeddedTemplates! }

    // Variable operations
    public var variableBindString: Function { _variableBindString! }
    public var variableBindInt: Function { _variableBindInt! }
    public var variableBindDouble: Function { _variableBindDouble! }
    public var variableBindBool: Function { _variableBindBool! }
    public var variableBindDict: Function { _variableBindDict! }
    public var variableBindArray: Function { _variableBindArray! }
    public var variableBindValue: Function { _variableBindValue! }
    public var variableUnbind: Function { _variableUnbind! }
    public var variableResolve: Function { _variableResolve! }
    public var variableResolveString: Function { _variableResolveString! }
    public var variableResolveInt: Function { _variableResolveInt! }
    public var copyValueToExpression: Function { _copyValueToExpression! }
    public var valueFree: Function { _valueFree! }
    public var valueAsString: Function { _valueAsString! }
    public var valueAsInt: Function { _valueAsInt! }
    public var stringConcat: Function { _stringConcat! }
    public var interpolateString: Function { _interpolateString! }
    public var evaluateWhenGuard: Function { _evaluateWhenGuard! }
    public var evaluateExpression: Function { _evaluateExpression! }
    public var evaluateAndBind: Function { _evaluateAndBind! }
    public var evaluateFilter: Function { _evaluateFilter! }
    public var matchPattern: Function { _matchPattern! }
    public var valueCreateInt: Function { _valueCreateInt! }

    // Collection operations
    public var arrayCount: Function { _arrayCount! }
    public var arrayGet: Function { _arrayGet! }
    public var dictGet: Function { _dictGet! }
    public var parallelForEachExecute: Function { _parallelForEachExecute! }

    // Standard library
    public var strcmp: Function { _strcmp! }

    /// Gets the function for the given action name
    public func actionFunction(for name: String) -> Function? {
        actionFunctions[name.lowercased()]
    }

    /// Dynamic action function for plugin-provided custom actions
    public var actionDynamic: Function { _actionDynamic! }
}

#endif
