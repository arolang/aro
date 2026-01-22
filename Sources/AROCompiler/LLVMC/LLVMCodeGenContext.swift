// ============================================================
// LLVMCodeGenContext.swift
// ARO Compiler - LLVM Code Generation Context
// ============================================================

#if !os(Windows)
import SwiftyLLVM
import AROParser

/// Code generation errors with source location tracking
public enum LLVMCodeGenError: Error, CustomStringConvertible {
    case typeMismatch(expected: String, actual: String, context: String, span: SourceSpan?)
    case undefinedSymbol(name: String, span: SourceSpan?)
    case invalidAction(verb: String, span: SourceSpan?)
    case invalidExpression(description: String, span: SourceSpan?)
    case moduleVerificationFailed(message: String)
    case llvmInternalError(message: String)
    case noEntryPoint
    case multipleEntryPoints

    public var description: String {
        switch self {
        case .typeMismatch(let expected, let actual, let context, let span):
            if let span = span {
                return "\(span): Type mismatch in \(context): expected \(expected), got \(actual)"
            }
            return "Type mismatch in \(context): expected \(expected), got \(actual)"
        case .undefinedSymbol(let name, let span):
            if let span = span {
                return "\(span): Undefined symbol '\(name)'"
            }
            return "Undefined symbol '\(name)'"
        case .invalidAction(let verb, let span):
            if let span = span {
                return "\(span): Unknown or unsupported action '\(verb)'"
            }
            return "Unknown or unsupported action '\(verb)'"
        case .invalidExpression(let desc, let span):
            if let span = span {
                return "\(span): Invalid expression: \(desc)"
            }
            return "Invalid expression: \(desc)"
        case .moduleVerificationFailed(let msg):
            return "LLVM module verification failed: \(msg)"
        case .llvmInternalError(let msg):
            return "LLVM internal error: \(msg)"
        case .noEntryPoint:
            return "No Application-Start feature set found"
        case .multipleEntryPoints:
            return "Multiple Application-Start feature sets found"
        }
    }

    public var span: SourceSpan? {
        switch self {
        case .typeMismatch(_, _, _, let span): return span
        case .undefinedSymbol(_, let span): return span
        case .invalidAction(_, let span): return span
        case .invalidExpression(_, let span): return span
        default: return nil
        }
    }
}

/// Context for LLVM IR code generation
/// Holds the module, builder state, and tracks source locations for error reporting
public final class LLVMCodeGenContext {
    // MARK: - LLVM Module

    /// The LLVM module being built
    public var module: Module

    // MARK: - String Constants Pool

    /// Maps string content to global variable references
    private var stringConstants: [String: GlobalVariable] = [:]

    /// Counter for generating unique string constant names
    private var stringCounter: Int = 0

    // MARK: - Generation State

    /// The current function being generated
    public var currentFunction: Function?

    /// The current basic block for insertion
    public var currentBlock: BasicBlock?

    /// Current insertion point
    public var currentInsertionPoint: InsertionPoint?

    /// The current context variable (%ctx parameter)
    public var currentContextVar: IRValue?

    /// The result storage variable (%__result)
    public var currentResultPtr: IRValue?

    // MARK: - Source Location Tracking

    /// Current source span for error reporting
    public var currentSourceSpan: SourceSpan?

    /// The source file being compiled
    public var sourceFile: String?

    // MARK: - Error Collection

    /// Collected errors during generation
    public private(set) var errors: [LLVMCodeGenError] = []

    // MARK: - Counters

    /// Counter for unique variable names
    private var uniqueCounter: Int = 0

    /// Counter for loop body functions
    private var loopBodyCounter: Int = 0

    // MARK: - Initialization

    /// Creates a new code generation context
    public init(moduleName: String = "aro_program") {
        self.module = Module(moduleName)
    }

    // MARK: - String Constants

    /// Gets or creates a global string constant
    /// - Parameter value: The string value
    /// - Returns: A global variable containing the null-terminated string
    public func stringConstant(_ value: String) -> GlobalVariable {
        if let existing = stringConstants[value] {
            return existing
        }

        let name = ".str.\(stringCounter)"
        stringCounter += 1

        // Create the string constant
        let constant = StringConstant(value, nullTerminated: true, in: &module)
        let global = module.addGlobalVariable(name, constant.type)
        module.setInitializer(constant, for: global)
        module.setLinkage(.private, for: global)
        module.setGlobalConstant(true, for: global)

        stringConstants[value] = global
        return global
    }

    // MARK: - Unique Names

    /// Generates a unique name with given prefix
    public func uniqueName(prefix: String) -> String {
        let name = "\(prefix)\(uniqueCounter)"
        uniqueCounter += 1
        return name
    }

    /// Generates a unique loop body function name
    public func uniqueLoopBodyName() -> String {
        let name = "aro_loop_body_\(loopBodyCounter)"
        loopBodyCounter += 1
        return name
    }

    // MARK: - Error Handling

    /// Records an error with the current source location
    public func recordError(_ error: LLVMCodeGenError) {
        errors.append(error)
    }

    /// Returns true if any errors have been recorded
    public var hasErrors: Bool {
        !errors.isEmpty
    }

    // MARK: - Insertion Point Management

    /// Sets the insertion point to the end of the given block
    public func setInsertionPoint(atEndOf block: BasicBlock) {
        currentBlock = block
        currentInsertionPoint = module.endOf(block)
    }

    /// Sets the insertion point to the start of the given block
    public func setInsertionPoint(atStartOf block: BasicBlock) {
        currentBlock = block
        currentInsertionPoint = module.startOf(block)
    }

    // MARK: - Convenience Accessors

    /// The current insertion point (crashes if not set)
    public var insertionPoint: InsertionPoint {
        guard let ip = currentInsertionPoint else {
            fatalError("No insertion point set")
        }
        return ip
    }

    /// Convenience accessor for common types
    public var ptrType: PointerType { module.ptr }
    public var i8Type: IntegerType { module.i8 }
    public var i32Type: IntegerType { module.i32 }
    public var i64Type: IntegerType { module.i64 }
    public var doubleType: FloatingPointType { module.double }
    public var voidType: VoidType { module.void }
}

#endif
