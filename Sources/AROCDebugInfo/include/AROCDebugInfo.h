// ============================================================
// AROCDebugInfo.h
// ARO Compiler - Thin umbrella over LLVM's DebugInfo C API (#231)
// ============================================================
//
// Swifty-LLVM's bundled `llvmc` module exposes only `llvm-c/Core.h`,
// so we cannot reach `LLVMDIBuilder*` / `llvm.dbg.*` symbols through
// it. This umbrella header pulls in the rest of the LLVM C surface
// AROCompiler needs to emit DWARF debug info — `Core.h` for the
// foundational refs (LLVMModuleRef, LLVMValueRef, LLVMContextRef)
// and `DebugInfo.h` for the DI builder and metadata-construction
// entry points.
//
// Issue #231 (DWARF source mapping). Once Swifty-LLVM upstream exposes
// `InsertionPoint.llvm` publicly we can wire per-instruction
// `LLVMSetCurrentDebugLocation2` calls and get real per-line
// breakpoints. Until then this header gives us function-level DI:
// each ARO feature set becomes an LLVM function with a `DISubprogram`
// pointing at its `.aro` source location, so lldb backtraces report
// file + line of the function entry.

#ifndef AROC_DEBUG_INFO_H
#define AROC_DEBUG_INFO_H

#include <llvm-c/Core.h>
#include <llvm-c/DebugInfo.h>
#include <llvm-c/Types.h>

#endif // AROC_DEBUG_INFO_H
