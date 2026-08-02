// ============================================================
// DescriptorBuilder.swift
// ARO Compiler - Result / Object descriptor IR construction
// ============================================================

#if !os(Windows)
import SwiftyLLVM
import AROParser

/// Builds the `AROResultDescriptor` / `AROObjectDescriptor` stack structs that
/// are passed to action functions at runtime.
///
/// Extracted from `LLVMCodeGenerator` (issue #334). Holds references to the
/// shared codegen context and type mapper (composition, mirroring
/// `LLVMExternalDeclEmitter`); descriptor allocas are hoisted to the current
/// function's entry block and their fields filled at the live insertion point.
struct DescriptorBuilder {
    private let ctx: LLVMCodeGenContext
    private let types: LLVMTypeMapper

    init(context: LLVMCodeGenContext, types: LLVMTypeMapper) {
        self.ctx = context
        self.types = types
    }

    func buildResultDescriptor(_ result: QualifiedNoun, prefix: String) -> IRValue {
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

    func buildObjectDescriptor(_ object: ObjectClause, prefix: String) -> IRValue {
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
}

#endif
