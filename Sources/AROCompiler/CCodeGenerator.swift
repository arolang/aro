// ============================================================
// CCodeGenerator.swift
// AROCompiler - C Code Generation
// ============================================================

import Foundation
import AROParser

/// Generates C code from an analyzed ARO program
public final class CCodeGenerator {
    // MARK: - Properties

    private var output: String = ""
    private var indentLevel: Int = 0
    private let indentString = "    "

    // MARK: - Initialization

    public init() {}

    // MARK: - Code Generation

    /// Generate C code for an analyzed program
    /// - Parameter program: The analyzed ARO program
    /// - Returns: Generated C source code
    public func generate(program: AnalyzedProgram) throws -> String {
        output = ""

        // Emit header
        emitHeader()

        // Emit forward declarations
        emitForwardDeclarations(program)

        // Generate feature set functions
        for featureSet in program.featureSets {
            try generateFeatureSet(featureSet)
        }

        // Generate main function
        try generateMain(program: program)

        return output
    }

    // MARK: - Private Methods

    private func emitHeader() {
        emit("""
        // Generated C code from ARO source
        // Do not edit manually

        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <stdint.h>

        // ARO Runtime declarations
        typedef void* ARORuntime;
        typedef void* AROContext;
        typedef void* AROValue;

        // Runtime lifecycle
        extern ARORuntime aro_runtime_init(void);
        extern void aro_runtime_shutdown(ARORuntime runtime);
        extern AROContext aro_context_create(ARORuntime runtime);
        extern AROContext aro_context_create_named(ARORuntime runtime, const char* name);
        extern void aro_context_destroy(AROContext ctx);

        // Variable operations
        extern void aro_variable_bind_string(AROContext ctx, const char* name, const char* value);
        extern void aro_variable_bind_int(AROContext ctx, const char* name, int64_t value);
        extern void aro_variable_bind_double(AROContext ctx, const char* name, double value);
        extern void aro_variable_bind_bool(AROContext ctx, const char* name, int value);
        extern AROValue aro_variable_resolve(AROContext ctx, const char* name);
        extern char* aro_variable_resolve_string(AROContext ctx, const char* name);
        extern int aro_variable_resolve_int(AROContext ctx, const char* name, int64_t* out);
        extern void aro_value_free(AROValue value);
        extern char* aro_value_as_string(AROValue value);
        extern int aro_value_as_int(AROValue value, int64_t* out);

        // Result/Object descriptors
        typedef struct {
            const char* base;
            const char** specifiers;
            int specifier_count;
        } AROResultDescriptor;

        typedef struct {
            const char* base;
            int preposition;
            const char** specifiers;
            int specifier_count;
        } AROObjectDescriptor;

        // Action declarations
        extern AROValue aro_action_extract(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_fetch(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_retrieve(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_parse(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_read(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_compute(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_validate(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_compare(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_transform(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_create(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_update(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_return(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_throw(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_emit(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_send(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_log(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_store(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_write(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_publish(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_start(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_listen(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_route(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_watch(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_stop(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);
        extern AROValue aro_action_keepalive(AROContext ctx, AROResultDescriptor* result, AROObjectDescriptor* object);

        // HTTP operations
        extern void* aro_http_server_create(ARORuntime runtime);
        extern int aro_http_server_start(void* server, const char* host, int port);
        extern void aro_http_server_stop(void* server);
        extern void aro_http_server_destroy(void* server);

        // File operations
        extern char* aro_file_read(const char* path, int* out_length);
        extern int aro_file_write(const char* path, const char* content);
        extern int aro_file_exists(const char* path);
        extern int aro_file_delete(const char* path);


        """)
    }

    private func emitForwardDeclarations(_ program: AnalyzedProgram) {
        emit("// Forward declarations")
        for featureSet in program.featureSets {
            let funcName = mangleFeatureSetName(featureSet.featureSet.name)
            emit("AROValue \(funcName)(AROContext ctx);")
        }
        emit("")
    }

    private func generateFeatureSet(_ featureSet: AnalyzedFeatureSet) throws {
        let funcName = mangleFeatureSetName(featureSet.featureSet.name)

        emit("// Feature Set: \(featureSet.featureSet.name)")
        emit("// Business Activity: \(featureSet.featureSet.businessActivity)")
        emit("AROValue \(funcName)(AROContext ctx) {")
        indent()

        emit("AROValue __result = NULL;")
        emit("")

        for statement in featureSet.featureSet.statements {
            try generateStatement(statement)
        }

        emit("")
        emit("return __result;")
        dedent()
        emit("}")
        emit("")
    }

    private func generateStatement(_ statement: Statement) throws {
        if let aroStatement = statement as? AROStatement {
            try generateAROStatement(aroStatement)
        } else if let publishStatement = statement as? PublishStatement {
            try generatePublishStatement(publishStatement)
        }
    }

    private func generateAROStatement(_ statement: AROStatement) throws {
        let verb = statement.action.verb.lowercased()
        let canonicalVerb = canonicalizeVerb(verb)

        let resultName = escapeString(statement.result.base)
        let resultSpecifiers = statement.result.specifiers.map { escapeString($0) }

        let objectBase = escapeString(statement.object.noun.base)
        let objectPrep = prepositionToInt(statement.object.preposition)
        let objectSpecifiers = statement.object.noun.specifiers.map { escapeString($0) }

        emit("// <\(statement.action.verb)> the <\(statement.result.base)> ...")
        emit("{")
        indent()

        // If there's a literal value, bind it to the context first
        if let literalValue = statement.literalValue {
            switch literalValue {
            case .string(let s):
                emit("aro_variable_bind_string(ctx, \"_literal_\", \"\(escapeString(s))\");")
            case .integer(let i):
                emit("aro_variable_bind_int(ctx, \"_literal_\", \(i));")
            case .float(let f):
                emit("aro_variable_bind_double(ctx, \"_literal_\", \(f));")
            case .boolean(let b):
                emit("aro_variable_bind_bool(ctx, \"_literal_\", \(b ? 1 : 0));")
            case .null:
                emit("// null literal - no binding needed")
            }
        }

        // Create result descriptor
        if resultSpecifiers.isEmpty {
            emit("AROResultDescriptor result_desc = { \"\(resultName)\", NULL, 0 };")
        } else {
            let specsArray = resultSpecifiers.map { "\"\($0)\"" }.joined(separator: ", ")
            emit("const char* result_specs[] = { \(specsArray) };")
            emit("AROResultDescriptor result_desc = { \"\(resultName)\", result_specs, \(resultSpecifiers.count) };")
        }

        // Create object descriptor
        if objectSpecifiers.isEmpty {
            emit("AROObjectDescriptor object_desc = { \"\(objectBase)\", \(objectPrep), NULL, 0 };")
        } else {
            let specsArray = objectSpecifiers.map { "\"\($0)\"" }.joined(separator: ", ")
            emit("const char* object_specs[] = { \(specsArray) };")
            emit("AROObjectDescriptor object_desc = { \"\(objectBase)\", \(objectPrep), object_specs, \(objectSpecifiers.count) };")
        }

        // Call action
        emit("__result = aro_action_\(canonicalVerb)(ctx, &result_desc, &object_desc);")

        dedent()
        emit("}")
        emit("")
    }

    private func generatePublishStatement(_ statement: PublishStatement) throws {
        let externalName = escapeString(statement.externalName)
        let internalName = escapeString(statement.internalVariable)

        emit("// Publish <\(statement.externalName)> as <\(statement.internalVariable)>")
        emit("{")
        indent()
        emit("AROResultDescriptor result_desc = { \"\(externalName)\", NULL, 0 };")
        emit("AROObjectDescriptor object_desc = { \"\(internalName)\", 3, NULL, 0 };") // 3 = .with
        emit("__result = aro_action_publish(ctx, &result_desc, &object_desc);")
        dedent()
        emit("}")
        emit("")
    }

    private func generateMain(program: AnalyzedProgram) throws {
        // Find Application-Start feature set
        guard program.featureSets.contains(where: {
            $0.featureSet.name == "Application-Start"
        }) else {
            throw CCodeGeneratorError.noEntryPoint
        }

        let entryFuncName = mangleFeatureSetName("Application-Start")

        emit("// Main entry point")
        emit("int main(int argc, char* argv[]) {")
        indent()

        emit("// Initialize runtime")
        emit("ARORuntime runtime = aro_runtime_init();")
        emit("if (!runtime) {")
        indent()
        emit("fprintf(stderr, \"Failed to initialize ARO runtime\\n\");")
        emit("return 1;")
        dedent()
        emit("}")
        emit("")

        emit("// Create context")
        emit("AROContext ctx = aro_context_create_named(runtime, \"Application-Start\");")
        emit("if (!ctx) {")
        indent()
        emit("fprintf(stderr, \"Failed to create execution context\\n\");")
        emit("aro_runtime_shutdown(runtime);")
        emit("return 1;")
        dedent()
        emit("}")
        emit("")

        emit("// Execute Application-Start")
        emit("AROValue result = \(entryFuncName)(ctx);")
        emit("")

        emit("// Cleanup")
        emit("if (result) aro_value_free(result);")
        emit("aro_context_destroy(ctx);")
        emit("aro_runtime_shutdown(runtime);")
        emit("")
        emit("return 0;")

        dedent()
        emit("}")
    }

    // MARK: - Helpers

    private func mangleFeatureSetName(_ name: String) -> String {
        return "aro_fs_" + name
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private func canonicalizeVerb(_ verb: String) -> String {
        let mapping: [String: String] = [
            "calculate": "compute", "derive": "compute",
            "verify": "validate", "check": "validate",
            "match": "compare",
            "convert": "transform", "map": "transform",
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
        }
    }

    private func escapeString(_ str: String) -> String {
        return str
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func emit(_ line: String) {
        let lines = line.split(separator: "\n", omittingEmptySubsequences: false)
        for l in lines {
            if l.isEmpty {
                output += "\n"
            } else {
                output += String(repeating: indentString, count: indentLevel) + l + "\n"
            }
        }
    }

    private func indent() {
        indentLevel += 1
    }

    private func dedent() {
        indentLevel = max(0, indentLevel - 1)
    }
}

// MARK: - Code Generator Errors

public enum CCodeGeneratorError: Error, CustomStringConvertible {
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
