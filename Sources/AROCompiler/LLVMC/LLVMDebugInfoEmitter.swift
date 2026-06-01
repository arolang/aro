// ============================================================
// LLVMDebugInfoEmitter.swift
// ARO Compiler - DWARF emission via llvm-c/DebugInfo.h (#231)
// ============================================================
//
// Wraps just enough of LLVM's C debug-info API to give compiled ARO
// binaries function-level DWARF: each feature set lands an
// `DISubprogram` that points at its `.aro` source file + line. lldb
// uses this to produce source-aware backtraces (`(lldb) bt` shows
// `users.aro:5` instead of `0x10003a4f0`) and `(lldb) info functions`
// lists the feature sets by name.
//
// Per-instruction `DILocation` (the metadata that powers
// `breakpoint set --file users.aro --line 5`) requires reaching
// `LLVMSetCurrentDebugLocation2` on the active builder. Swifty-LLVM
// keeps `InsertionPoint.llvm` internal; emitting per-line locations
// needs an upstream change to expose it (or a non-trivial bitcast hack
// against `ManagedPointer`). That work is tracked separately — see
// #231 for the path-forward writeup.

import Foundation
import AROParser
import SwiftyLLVM
import AROCDebugInfo

/// Emits DWARF function-level debug info for an LLVM module.
///
/// Lifetime: create once per module, call `beginFunction` per feature
/// set's `LLVMValueRef`, and call `finalize` exactly once before the
/// module's IR is read for emission. Calling `finalize` more than once
/// is undefined behavior in LLVM.
final class LLVMDebugInfoEmitter {

    private let module: LLVMModuleRef
    private let context: LLVMContextRef
    private let builder: LLVMDIBuilderRef
    private let compileUnit: LLVMMetadataRef
    private let primaryFile: LLVMMetadataRef
    /// Reused subroutine type for every feature set. ARO's emitted
    /// functions all have the same signature
    /// `i64 (i64 ctx_handle)`-ish shape, so one `DISubroutineType`
    /// suffices for now.
    private let subroutineType: LLVMMetadataRef

    /// One synthesized "source file" per `.aro` filename we've seen.
    /// LLVM dedupes these internally but caching avoids repeated
    /// allocations.
    private var fileCache: [String: LLVMMetadataRef] = [:]

    /// Creates an emitter and seeds the module-level DI metadata:
    /// CompileUnit, primary File, BasicType for the implicit return.
    ///
    /// - Parameters:
    ///   - swiftyModule: the Swifty-LLVM `Module` we're augmenting.
    ///     The underlying `LLVMModuleRef` is recovered via
    ///     `unsafeBitCast(swiftyModule.llvm, to: LLVMModuleRef.self)`.
    ///     This works because `ModuleRef` is a single-pointer struct
    ///     wrapping the same C handle.
    ///   - primaryFilename: the `.aro` source filename used in the
    ///     CompileUnit metadata. Per-function filenames are derived
    ///     separately in `beginFunction`.
    ///   - producerVersion: the ARO compiler version string baked into
    ///     the DWARF metadata, useful for `lldb image dump-line-table`.
    init?(swiftyModule: SwiftyLLVM.Module, primaryFilename: String, producerVersion: String) {
        let moduleRef = unsafeBitCast(swiftyModule.llvm, to: LLVMModuleRef.self)
        self.module = moduleRef

        guard let ctxRef: LLVMContextRef = LLVMGetModuleContext(moduleRef) else { return nil }
        self.context = ctxRef

        guard let diBuilder = LLVMCreateDIBuilder(moduleRef) else { return nil }
        self.builder = diBuilder

        // DIFile for the CompileUnit. ARO's source files are flat per-
        // application; we don't track per-feature-set directory paths
        // yet, so the directory string is empty.
        let primary = primaryFilename.withCString { cFilename -> LLVMMetadataRef? in
            "".withCString { cDir in
                LLVMDIBuilderCreateFile(
                    diBuilder,
                    cFilename, primaryFilename.utf8.count,
                    cDir, 0
                )
            }
        }
        guard let primary else { return nil }
        self.primaryFile = primary

        // CompileUnit. DW_LANG_C_plus_plus is the closest match for what
        // ARO emits at the IR level — it's a host-language hint, not a
        // claim about the surface syntax. lldb only uses it to pick the
        // right demangler, which doesn't apply to ARO anyway.
        let cu: LLVMMetadataRef? = producerVersion.withCString { cProducer in
            "".withCString { cFlags in
                "".withCString { cSplitName in
                    "".withCString { cSysroot in
                        "".withCString { cSDK in
                            LLVMDIBuilderCreateCompileUnit(
                                diBuilder,
                                LLVMDWARFSourceLanguageC_plus_plus,
                                primary,
                                cProducer, producerVersion.utf8.count,
                                /* isOptimized */ 0,
                                cFlags, 0,
                                /* runtimeVer */ 0,
                                cSplitName, 0,
                                LLVMDWARFEmissionFull,
                                /* DWOId */ 0,
                                /* SplitDebugInlining */ 0,
                                /* DebugInfoForProfiling */ 0,
                                cSysroot, 0,
                                cSDK, 0
                            )
                        }
                    }
                }
            }
        }
        guard let cu else { return nil }
        self.compileUnit = cu

        // SubroutineType: `void(void)` shape suffices for lldb's
        // purposes — we're not surfacing parameters/locals through DI
        // yet. When per-line breakpoints land we revisit this.
        var emptyTypes: [LLVMMetadataRef?] = []
        let subRoutType = emptyTypes.withUnsafeMutableBufferPointer { buf -> LLVMMetadataRef? in
            LLVMDIBuilderCreateSubroutineType(
                diBuilder,
                primary,
                buf.baseAddress,
                UInt32(buf.count),
                LLVMDIFlagZero
            )
        }
        guard let subRoutType else { return nil }
        self.subroutineType = subRoutType

        // Module-level DWARF version + Debug Info Version flags.
        // Without these, the linker may strip our metadata.
        addModuleFlag(name: "Debug Info Version", value: 3)
        addModuleFlag(name: "Dwarf Version", value: 4)
    }

    /// Attaches a `DISubprogram` to `function`, marking it as defined at
    /// `file`:`line`. Idempotent per function — the Swifty-LLVM value
    /// is bitcast to `LLVMValueRef` the same way as the module.
    func beginFunction(
        function: SwiftyLLVM.Function,
        name: String,
        linkageName: String,
        file: String,
        line: Int
    ) {
        let valueRef = unsafeBitCast(function.llvm, to: LLVMValueRef.self)
        let fileRef = fileFor(filename: file)

        let scopeLine = UInt32(max(line, 1))
        let definitionLine = UInt32(max(line, 1))

        let sp: LLVMMetadataRef? = name.withCString { cName in
            linkageName.withCString { cLinkName in
                LLVMDIBuilderCreateFunction(
                    builder,
                    /* Scope */ fileRef,
                    cName, name.utf8.count,
                    cLinkName, linkageName.utf8.count,
                    fileRef,
                    definitionLine,
                    subroutineType,
                    /* IsLocalToUnit */ 0,
                    /* IsDefinition */ 1,
                    scopeLine,
                    LLVMDIFlagPrototyped,
                    /* IsOptimized */ 0
                )
            }
        }

        if let sp {
            LLVMSetSubprogram(valueRef, sp)
        }
    }

    /// Finalizes all pending DI metadata and disposes the builder. Must
    /// be called exactly once after the last `beginFunction` and before
    /// the module's IR is read for emission.
    func finalize() {
        LLVMDIBuilderFinalize(builder)
        LLVMDisposeDIBuilder(builder)
    }

    // MARK: - Internal helpers

    private func fileFor(filename: String) -> LLVMMetadataRef {
        if let cached = fileCache[filename] { return cached }
        let made: LLVMMetadataRef = filename.withCString { cFilename in
            "".withCString { cDir in
                LLVMDIBuilderCreateFile(
                    builder,
                    cFilename, filename.utf8.count,
                    cDir, 0
                )!
            }
        }
        fileCache[filename] = made
        return made
    }

    private func addModuleFlag(name: String, value: UInt32) {
        // Behavior 1 = Warning if the linker sees a mismatch; matches
        // what clang/swiftc emit for the same flags.
        let intTy = LLVMInt32TypeInContext(context)
        let intConst = LLVMConstInt(intTy, UInt64(value), 0)
        guard let intConst else { return }
        guard let asMeta = LLVMValueAsMetadata(intConst) else { return }
        name.withCString { cName in
            LLVMAddModuleFlag(
                module,
                LLVMModuleFlagBehaviorWarning,
                cName, name.utf8.count,
                asMeta
            )
        }
    }
}
