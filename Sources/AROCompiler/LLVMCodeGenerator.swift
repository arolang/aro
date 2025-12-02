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

    // MARK: - Initialization

    public init() {}

    // MARK: - Code Generation

    /// Generate LLVM IR for an analyzed program
    /// - Parameter program: The analyzed ARO program
    /// - Returns: Result containing the LLVM IR text
    public func generate(program: AnalyzedProgram) throws -> LLVMCodeGenerationResult {
        output = ""
        stringConstants = [:]
        uniqueCounter = 0

        // Emit module header
        emitModuleHeader()

        // Emit type definitions
        emitTypeDefinitions()

        // Emit external function declarations
        emitExternalDeclarations()

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
        emit("declare ptr @aro_context_create(ptr)")
        emit("declare ptr @aro_context_create_named(ptr, ptr)")
        emit("declare void @aro_context_destroy(ptr)")
        emit("")

        // Variable operations
        emit("; Variable operations")
        emit("declare void @aro_variable_bind_string(ptr, ptr, ptr)")
        emit("declare void @aro_variable_bind_int(ptr, ptr, i64)")
        emit("declare void @aro_variable_bind_double(ptr, ptr, double)")
        emit("declare void @aro_variable_bind_bool(ptr, ptr, i32)")
        emit("declare ptr @aro_variable_resolve(ptr, ptr)")
        emit("declare ptr @aro_variable_resolve_string(ptr, ptr)")
        emit("declare i32 @aro_variable_resolve_int(ptr, ptr, ptr)")
        emit("declare void @aro_value_free(ptr)")
        emit("declare ptr @aro_value_as_string(ptr)")
        emit("declare i32 @aro_value_as_int(ptr, ptr)")
        emit("")

        // All action functions
        emit("; Action functions")
        let actions = [
            "extract", "fetch", "retrieve", "parse", "read",
            "compute", "validate", "compare", "transform", "create", "update",
            "return", "throw", "emit", "send", "log", "store", "write", "publish",
            "start", "listen", "route", "watch", "stop", "keepalive"
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

        // File operations
        emit("; File operations")
        emit("declare ptr @aro_file_read(ptr, ptr)")
        emit("declare i32 @aro_file_write(ptr, ptr)")
        emit("declare i32 @aro_file_exists(ptr)")
        emit("declare i32 @aro_file_delete(ptr)")
        emit("")
    }

    // MARK: - String Constants

    private func collectStringConstants(_ program: AnalyzedProgram) {
        // Collect all strings used in the program
        for featureSet in program.featureSets {
            registerString(featureSet.featureSet.name)
            registerString(featureSet.featureSet.businessActivity)

            for statement in featureSet.featureSet.statements {
                collectStringsFromStatement(statement)
            }
        }

        // Always register these strings for main
        registerString("Application-Start")
        registerString("_literal_")
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

            if case .string(let s) = aroStatement.literalValue {
                registerString(s)
            }
        } else if let publishStatement = statement as? PublishStatement {
            registerString(publishStatement.externalName)
            registerString(publishStatement.internalVariable)
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
        let length = str.utf8.count + 1
        return "ptr \(name)"
    }

    // MARK: - Feature Set Generation

    private func generateFeatureSet(_ featureSet: AnalyzedFeatureSet) throws {
        let funcName = mangleFeatureSetName(featureSet.featureSet.name)

        emit("; Feature Set: \(featureSet.featureSet.name)")
        emit("; Business Activity: \(featureSet.featureSet.businessActivity)")
        emit("define ptr @\(funcName)(ptr %ctx) {")
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
    }

    private func generateStatement(_ statement: Statement, index: Int) throws {
        if let aroStatement = statement as? AROStatement {
            try generateAROStatement(aroStatement, index: index)
        } else if let publishStatement = statement as? PublishStatement {
            try generatePublishStatement(publishStatement, index: index)
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
        emit("  %\(prefix)_action_result = call ptr @aro_action_\(actionName)(ptr %ctx, ptr %\(prefix)_result_desc, ptr %\(prefix)_object_desc)")

        // Store result
        emit("  store ptr %\(prefix)_action_result, ptr %__result")
        emit("")
    }

    private func emitLiteralBinding(_ literal: LiteralValue, prefix: String) throws {
        let literalNameStr = stringConstants["_literal_"]!

        switch literal {
        case .string(let s):
            let strConst = stringConstants[s]!
            emit("  call void @aro_variable_bind_string(ptr %ctx, ptr \(literalNameStr), ptr \(strConst))")

        case .integer(let i):
            emit("  call void @aro_variable_bind_int(ptr %ctx, ptr \(literalNameStr), i64 \(i))")

        case .float(let f):
            // Format double as hex for exact representation
            let bits = f.bitPattern
            emit("  call void @aro_variable_bind_double(ptr %ctx, ptr \(literalNameStr), double 0x\(String(bits, radix: 16, uppercase: true)))")

        case .boolean(let b):
            emit("  call void @aro_variable_bind_bool(ptr %ctx, ptr \(literalNameStr), i32 \(b ? 1 : 0))")

        case .null:
            // No binding needed
            break
        }
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
        emit("  %\(prefix)_result = call ptr @aro_action_publish(ptr %ctx, ptr %\(prefix)_result_desc, ptr %\(prefix)_object_desc)")
        emit("  store ptr %\(prefix)_result, ptr %__result")
        emit("")
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

        // Check runtime initialization
        emit("  %runtime_null = icmp eq ptr %runtime, null")
        emit("  br i1 %runtime_null, label %runtime_fail, label %runtime_ok")
        emit("")

        emit("runtime_fail:")
        emit("  ret i32 1")
        emit("")

        emit("runtime_ok:")
        // Create named context
        emit("  %ctx = call ptr @aro_context_create_named(ptr %runtime, ptr \(appStartStr))")

        // Check context creation
        emit("  %ctx_null = icmp eq ptr %ctx, null")
        emit("  br i1 %ctx_null, label %ctx_fail, label %ctx_ok")
        emit("")

        emit("ctx_fail:")
        emit("  call void @aro_runtime_shutdown(ptr %runtime)")
        emit("  ret i32 1")
        emit("")

        emit("ctx_ok:")
        // Execute Application-Start
        emit("  %result = call ptr @\(entryFuncName)(ptr %ctx)")

        // Check if result needs to be freed
        emit("  %result_null = icmp eq ptr %result, null")
        emit("  br i1 %result_null, label %cleanup, label %free_result")
        emit("")

        emit("free_result:")
        emit("  call void @aro_value_free(ptr %result)")
        emit("  br label %cleanup")
        emit("")

        emit("cleanup:")
        emit("  call void @aro_context_destroy(ptr %ctx)")
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
