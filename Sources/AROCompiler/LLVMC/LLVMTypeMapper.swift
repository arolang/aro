// ============================================================
// LLVMTypeMapper.swift
// ARO Compiler - LLVM Type Mapping and Validation
// ============================================================

#if !os(Windows)
import SwiftyLLVM
import AROParser

/// Maps ARO types to LLVM types and creates runtime structure types
public final class LLVMTypeMapper {
    private let ctx: LLVMCodeGenContext

    // MARK: - Cached Struct Types

    /// AROResultDescriptor: { ptr base, ptr specs_array, i32 spec_count }
    private var _resultDescriptorType: StructType?

    /// AROObjectDescriptor: { ptr base, i32 preposition, ptr specs_array, i32 spec_count }
    private var _objectDescriptorType: StructType?

    /// Cached FunctionTypes for the four well-known signatures
    /// and a generic signature dict for `functionType(parameters:returning:)`.
    /// Repeated declarations with the same signature reuse the
    /// stored instance instead of re-asking SwiftyLLVM (#347).
    private var _actionFunctionType: FunctionType?
    private var _featureSetFunctionType: FunctionType?
    private var _mainFunctionType: FunctionType?
    private var _loopBodyFunctionType: FunctionType?
    private var _genericFunctionTypeCache: [String: FunctionType] = [:]

    // MARK: - Initialization

    public init(context: LLVMCodeGenContext) {
        self.ctx = context
    }

    // MARK: - Runtime Struct Types

    /// Gets the AROResultDescriptor struct type
    /// Layout: { ptr base, ptr specs_array, i32 spec_count }
    public var resultDescriptorType: StructType {
        if let existing = _resultDescriptorType {
            return existing
        }
        let type = StructType(
            [ctx.ptrType, ctx.ptrType, ctx.i32Type],
            in: &ctx.module
        )
        _resultDescriptorType = type
        return type
    }

    /// Gets the AROObjectDescriptor struct type
    /// Layout: { ptr base, i32 preposition, ptr specs_array, i32 spec_count }
    public var objectDescriptorType: StructType {
        if let existing = _objectDescriptorType {
            return existing
        }
        let type = StructType(
            [ctx.ptrType, ctx.i32Type, ctx.ptrType, ctx.i32Type],
            in: &ctx.module
        )
        _objectDescriptorType = type
        return type
    }

    // MARK: - Function Types

    /// Function type for action functions: (ptr ctx, ptr result_desc, ptr object_desc) -> ptr
    public var actionFunctionType: FunctionType {
        if let cached = _actionFunctionType { return cached }
        let type = FunctionType(from: [ctx.ptrType, ctx.ptrType, ctx.ptrType], to: ctx.ptrType, in: &ctx.module)
        _actionFunctionType = type
        return type
    }

    /// Function type for feature set functions: (ptr ctx) -> ptr
    public var featureSetFunctionType: FunctionType {
        if let cached = _featureSetFunctionType { return cached }
        let type = FunctionType(from: [ctx.ptrType], to: ctx.ptrType, in: &ctx.module)
        _featureSetFunctionType = type
        return type
    }

    /// Function type for main: (i32 argc, ptr argv) -> i32
    public var mainFunctionType: FunctionType {
        if let cached = _mainFunctionType { return cached }
        let type = FunctionType(from: [ctx.i32Type, ctx.ptrType], to: ctx.i32Type, in: &ctx.module)
        _mainFunctionType = type
        return type
    }

    /// Function type for loop body: (ptr ctx, ptr item, i64 index) -> ptr
    public var loopBodyFunctionType: FunctionType {
        if let cached = _loopBodyFunctionType { return cached }
        let type = FunctionType(from: [ctx.ptrType, ctx.ptrType, ctx.i64Type], to: ctx.ptrType, in: &ctx.module)
        _loopBodyFunctionType = type
        return type
    }

    /// Function type for void returning functions: (...) -> void
    public func voidFunctionType(parameters: [IRType]) -> FunctionType {
        let key = Self.signatureKey(parameters: parameters, returningName: "void")
        if let cached = _genericFunctionTypeCache[key] { return cached }
        let type = FunctionType(from: parameters, to: nil, in: &ctx.module)
        _genericFunctionTypeCache[key] = type
        return type
    }

    /// Function type with given return type
    public func functionType(parameters: [IRType], returning: IRType) -> FunctionType {
        let key = Self.signatureKey(parameters: parameters, returningName: "\(returning)")
        if let cached = _genericFunctionTypeCache[key] { return cached }
        let type = FunctionType(from: parameters, to: returning, in: &ctx.module)
        _genericFunctionTypeCache[key] = type
        return type
    }

    private static func signatureKey(parameters: [IRType], returningName: String) -> String {
        var s = returningName
        s.append("(")
        for (i, p) in parameters.enumerated() {
            if i > 0 { s.append(",") }
            s.append("\(p)")
        }
        s.append(")")
        return s
    }

    // MARK: - Type Validation

    /// Validates that the expected type matches the actual type
    /// - Throws: LLVMCodeGenError.typeMismatch if types don't match
    public func validate(
        expected: IRType,
        actual: IRType,
        context: String,
        span: SourceSpan? = nil
    ) throws {
        if expected != actual {
            throw LLVMCodeGenError.typeMismatch(
                expected: describeType(expected),
                actual: describeType(actual),
                context: context,
                span: span ?? ctx.currentSourceSpan
            )
        }
    }

    /// Describes an LLVM type for error messages
    public func describeType(_ type: IRType) -> String {
        // Use LLVM's built-in type printing
        return "\(type)"
    }

    // MARK: - Array Types

    /// Creates an array type with the given element type and count
    public func arrayType(of elementType: IRType, count: Int) -> ArrayType {
        ArrayType(count, elementType, in: &ctx.module)
    }

    /// Creates a pointer array type for the given count
    public func pointerArrayType(count: Int) -> ArrayType {
        arrayType(of: ctx.ptrType, count: count)
    }
}

// MARK: - Preposition Mapping

extension LLVMTypeMapper {
    /// Maps ARO prepositions to integer values for the runtime
    public static func prepositionValue(_ preposition: Preposition) -> Int32 {
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
}

#endif
