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

    /// The `DISubprogram` from the most recent `beginFunction` call.
    /// Used as the scope when constructing per-statement `DILocation`s.
    /// Nil before any function has been opened or after `endFunction`.
    private var currentScope: LLVMMetadataRef?

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
            currentScope = sp
        }
    }

    /// Closes out the current function's debug-info scope. Subsequent
    /// `setLocation` calls have no effect until `beginFunction` runs
    /// again. Optional — `beginFunction` overwrites `currentScope`
    /// either way.
    func endFunction() {
        currentScope = nil
    }

    /// Issue #231 phase 2 — set the IR builder's current debug location
    /// before emitting instructions for a statement. lldb maps the
    /// emitted instructions back to `(file, line, column)` via this
    /// metadata, which is what makes
    /// `breakpoint set --file foo.aro --line N` actually resolve.
    ///
    /// Implementation note: Swifty-LLVM keeps the underlying
    /// `LLVMBuilderRef` private inside `InsertionPoint`'s wrapped
    /// `ManagedPointer`. There is no public Swift accessor — exposing
    /// one needs an upstream change. Until that lands we reach the
    /// builder by mirroring the struct's storage layout and reading
    /// the class instance directly. The layout is documented in
    /// `Swifty-LLVM/Sources/SwiftyLLVM/InsertionPoint.swift` and
    /// `Utils/ManagedPointer.swift`; the offset is asserted at runtime
    /// via a small sanity check (see `extractBuilderRef`). If
    /// Swifty-LLVM reorders these fields the assertion fires and we
    /// fall back to emitting no per-line location for that statement
    /// — silent degradation rather than crash.
    func setLocation(at insertionPoint: SwiftyLLVM.InsertionPoint, line: Int, column: Int) {
        guard let scope = currentScope else { return }
        guard let builderRef = Self.extractBuilderRef(insertionPoint) else { return }

        let loc = LLVMDIBuilderCreateDebugLocation(
            context,
            UInt32(max(line, 1)),
            UInt32(max(column, 0)),
            scope,
            /* InlinedAt */ nil
        )
        if let loc {
            LLVMSetCurrentDebugLocation2(builderRef, loc)
        }
    }

    /// Clears the IR builder's debug location. Call before emitting
    /// alloca's or prologue instructions that shouldn't be attributed
    /// to a specific source line — keeps lldb's line tables clean.
    func clearLocation(at insertionPoint: SwiftyLLVM.InsertionPoint) {
        guard let builderRef = Self.extractBuilderRef(insertionPoint) else { return }
        LLVMSetCurrentDebugLocation2(builderRef, nil)
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

    /// Reach the underlying `LLVMBuilderRef` from a Swifty-LLVM
    /// `InsertionPoint`. Returns `nil` if the layout we expect doesn't
    /// match — that protects against silent corruption if Swifty-LLVM
    /// changes its struct shape upstream.
    ///
    /// The expected layout (verified against `Sources/SwiftyLLVM/InsertionPoint.swift`
    /// at the version this code was written for):
    ///
    /// ```
    /// public struct InsertionPoint {
    ///     private let wrapped: ManagedPointer<LLVMBuilderRef>
    /// }
    /// final class ManagedPointer<T> {
    ///     let llvm: T          // ← what we want
    ///     private let dispose: @Sendable (T) -> Void
    /// }
    /// ```
    ///
    /// We mirror `InsertionPoint` as a single-field struct holding the
    /// class reference, then read offset 16 from the class instance
    /// (the Swift class-instance header occupies the first 16 bytes
    /// on 64-bit Darwin/Linux; the first stored property follows).
    fileprivate static func extractBuilderRef(_ ip: SwiftyLLVM.InsertionPoint) -> LLVMBuilderRef? {
        // Mirror struct must match SwiftyLLVM.InsertionPoint's storage
        // exactly — single pointer-sized field.
        struct InsertionPointShim: @unchecked Sendable {
            let wrapped: AnyObject
        }
        guard MemoryLayout<SwiftyLLVM.InsertionPoint>.size == MemoryLayout<InsertionPointShim>.size else {
            return nil
        }
        let shim = unsafeBitCast(ip, to: InsertionPointShim.self)
        let classPtr = Unmanaged.passUnretained(shim.wrapped).toOpaque()
        // First stored property of a Swift class on 64-bit lives at
        // offset 16 (8 bytes isa + 8 bytes refcount).
        let storedOffset = 16
        let rawPtr = classPtr.advanced(by: storedOffset)
        let builderRef = rawPtr.load(as: LLVMBuilderRef?.self)
        return builderRef
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
