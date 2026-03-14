# Chapter 8: Native Compilation

## Why Native Compilation?

The interpreter is great for development. But when you ship to production, you want something leaner. Native compilation gives you three things:

- **Startup time**: No parsing, no compilation at launch — the binary just runs.
- **Single binary**: One file, no separate runtime, no `aro run` wrapper.
- **Performance**: Direct machine code execution.

ARO generates LLVM IR using the Swifty-LLVM C API, compiles it to object code via `llc`, and links with the Swift runtime.

---

## Compilation Pipeline

```
Source Files (.aro)
       ↓
    Parser
       ↓
AnalyzedProgram (AST)
       ↓
LLVMCodeGenerator
  (Swifty-LLVM API)
       ↓
  LLVM IR (.ll)
       ↓
    llc
       ↓
Object File (.o)
       ↓
   Linker
       ↓
Executable
```

<svg viewBox="0 0 700 400" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .compiler { fill: #e8f4e8; }
    .external { fill: #f4e8e8; }
    .output { fill: #e8e8f4; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow20); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow20" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Source Files -->
  <rect x="30" y="30" width="140" height="50" rx="5" class="box"/>
  <text x="100" y="50" class="title" text-anchor="middle">Source Files</text>
  <text x="100" y="70" class="label" text-anchor="middle">*.aro</text>

  <!-- Parser/Analyzer -->
  <rect x="30" y="110" width="140" height="50" rx="5" class="box compiler"/>
  <text x="100" y="130" class="title" text-anchor="middle">Parser</text>
  <text x="100" y="150" class="label" text-anchor="middle">AnalyzedProgram</text>

  <!-- LLVMCodeGenerator -->
  <rect x="30" y="190" width="140" height="50" rx="5" class="box compiler"/>
  <text x="100" y="210" class="title" text-anchor="middle">LLVMCodeGenerator</text>
  <text x="100" y="230" class="label" text-anchor="middle">AST → IR (C API)</text>

  <!-- LLVM IR -->
  <rect x="30" y="270" width="140" height="50" rx="5" class="box output"/>
  <text x="100" y="290" class="title" text-anchor="middle">LLVM IR</text>
  <text x="100" y="310" class="label" text-anchor="middle">program.ll</text>

  <!-- llc -->
  <rect x="220" y="270" width="100" height="50" rx="5" class="box external"/>
  <text x="270" y="300" class="title" text-anchor="middle">llc</text>

  <!-- Object File -->
  <rect x="370" y="270" width="100" height="50" rx="5" class="box output"/>
  <text x="420" y="290" class="title" text-anchor="middle">Object</text>
  <text x="420" y="310" class="label" text-anchor="middle">program.o</text>

  <!-- Linker -->
  <rect x="520" y="270" width="100" height="50" rx="5" class="box external"/>
  <text x="570" y="300" class="title" text-anchor="middle">Linker</text>

  <!-- Executable -->
  <rect x="520" y="350" width="100" height="40" rx="5" class="box output"/>
  <text x="570" y="375" class="title" text-anchor="middle">Executable</text>

  <!-- Swift Runtime (side box) -->
  <rect x="370" y="140" width="150" height="100" rx="5" class="box"/>
  <text x="445" y="165" class="title" text-anchor="middle">Runtime Libraries</text>
  <text x="380" y="185" class="label">libARORuntime.dylib</text>
  <text x="380" y="200" class="label">Swift runtime</text>
  <text x="380" y="215" class="label">System libraries</text>
  <text x="380" y="230" class="label">Foundation</text>

  <!-- Arrows -->
  <path d="M 100 80 L 100 110" class="arrow"/>
  <path d="M 100 160 L 100 190" class="arrow"/>
  <path d="M 100 240 L 100 270" class="arrow"/>
  <path d="M 170 295 L 220 295" class="arrow"/>
  <path d="M 320 295 L 370 295" class="arrow"/>
  <path d="M 470 295 L 520 295" class="arrow"/>
  <path d="M 445 240 L 570 270" class="arrow"/>
  <path d="M 570 320 L 570 350" class="arrow"/>
</svg>

**Figure 8.1**: Compilation pipeline. ARO generates LLVM IR, `llc` emits object code, the linker produces the final executable.

---

## LLVM C API via Swifty-LLVM

ARO generates LLVM IR using [Swifty-LLVM](https://github.com/hylo-lang/Swifty-LLVM), a Swift wrapper around LLVM's C API. This gives us type-safe IR construction with compile-time checking.

### Historical Note

The original implementation generated LLVM IR as text strings. Simple to start with, but painful in practice:

- No compile-time type checking — IR syntax errors only surfaced when running `llc`
- String manipulation overhead everywhere
- Easy to generate invalid IR through typos or format mismatches

Swifty-LLVM was the upgrade we needed.

### Why Swifty-LLVM?

**Advantages:**
- **Type safety**: `Module`, `Function`, and `BasicBlock` are distinct types; mismatches are caught at compile time
- **Performance**: Direct memory operations, no text parsing
- **API stability**: The C API is more stable than the textual IR format across LLVM versions
- **Debuggability**: You can still dump IR to text for inspection when you need to

**Trade-offs:**
- Requires LLVM 20 as a build dependency
- More complex build setup (pkg-config, library paths)
- Tighter coupling to a specific LLVM version

### Code Generator Architecture

Four components work together to produce IR:

| Component | Role |
|-----------|------|
| `LLVMCodeGenerator` | Main traversal: walks the AST, drives IR emission |
| `LLVMCodeGenContext` | Holds the LLVM module, current builder position, and type/string caches |
| `LLVMTypeMapper` | Defines the `AROResultDescriptor` and `AROObjectDescriptor` struct types |
| `LLVMExternalDeclEmitter` | Declares all 61 runtime action functions so the generated code can call them |

---

## Module Structure

Every generated module starts with a standard header:

```llvm
; ModuleID = 'aro_program'
source_filename = "aro_program.ll"
target datalayout = "e-m:o-i64:64-i128:128-n32:64-S128"
target triple = "arm64-apple-macosx14.0.0"
```

The target triple is platform-specific:
- **macOS ARM64**: `arm64-apple-macosx14.0.0`
- **macOS x86_64**: `x86_64-apple-macosx14.0.0`
- **Linux ARM64**: `aarch64-unknown-linux-gnu`
- **Linux x86_64**: `x86_64-unknown-linux-gnu`
- **Windows**: `x86_64-pc-windows-msvc`

---

## Type Definitions

ARO uses two struct types to pass statement metadata to runtime actions:

```llvm
; AROResultDescriptor: { base, specifiers, count }
%AROResultDescriptor = type { ptr, ptr, i32 }

; AROObjectDescriptor: { base, preposition, specifiers, count }
%AROObjectDescriptor = type { ptr, i32, ptr, i32 }
```

These mirror the Swift `ResultDescriptor` and `ObjectDescriptor` types. The runtime bridge converts between C structs and Swift types.

---

## External Declarations

The generated code calls into the runtime through C-callable functions:

```llvm
; Runtime lifecycle
declare ptr @aro_runtime_init()
declare void @aro_runtime_shutdown(ptr)
declare ptr @aro_context_create(ptr)
declare void @aro_context_destroy(ptr)

; Variable operations
declare void @aro_variable_bind_string(ptr, ptr, ptr)
declare void @aro_variable_bind_int(ptr, ptr, i64)
declare ptr @aro_variable_resolve(ptr, ptr)

; Actions
declare ptr @aro_action_extract(ptr, ptr, ptr)
declare ptr @aro_action_compute(ptr, ptr, ptr)
declare ptr @aro_action_return(ptr, ptr, ptr)
; ... 47 more action declarations
```

The generator emits declarations for all 61 built-in actions, plus runtime lifecycle and variable operations.

---

## String Constant Collection

Before generating any function bodies, we do a full pre-pass to collect every string that appears in the program — feature set names, business activities, variable names, literal values, even internal markers like `_literal_`. Each unique string becomes one global constant in the data section. The generated code then references these by pointer — no string allocation at runtime.

```llvm
@.str.0 = private unnamed_addr constant [18 x i8] c"Application-Start\00"
@.str.1 = private unnamed_addr constant [8 x i8] c"console\00"
@.str.2 = private unnamed_addr constant [14 x i8] c"Hello, World!\00"
```

<svg viewBox="0 0 600 200" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .str { fill: #e8f4e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow21); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow21" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- String table concept -->
  <rect x="30" y="30" width="250" height="150" rx="5" class="box"/>
  <text x="155" y="55" class="title" text-anchor="middle">String Constants (Data Section)</text>

  <rect x="45" y="70" width="220" height="25" rx="3" class="str"/>
  <text x="55" y="88" class="label">@.str.0 = "Application-Start\0"</text>

  <rect x="45" y="100" width="220" height="25" rx="3" class="str"/>
  <text x="55" y="118" class="label">@.str.1 = "console\0"</text>

  <rect x="45" y="130" width="220" height="25" rx="3" class="str"/>
  <text x="55" y="148" class="label">@.str.2 = "Hello, World!\0"</text>

  <!-- Code references -->
  <rect x="350" y="70" width="220" height="90" rx="5" class="box"/>
  <text x="460" y="95" class="title" text-anchor="middle">Generated Code</text>
  <text x="360" y="115" class="label">call @aro_log(ptr @.str.0, ...)</text>
  <text x="360" y="135" class="label">store ptr @.str.2, ptr %lit_ptr</text>

  <!-- Arrows -->
  <path d="M 280 95 L 350 95" class="arrow"/>
  <path d="M 280 135 L 350 135" class="arrow"/>
</svg>

**Figure 8.2**: String constants are collected first, then referenced by pointer in generated code.

---

## Feature Set Generation

Each feature set becomes an LLVM function taking a context pointer and returning a result pointer. The function always has two exit blocks: `normal_return` (loads the result and returns it) and `error_exit` (prints the error message and returns null). Statements fill in between. The Swifty-LLVM API builds this programmatically — no string templates.

Name mangling converts `"Application-Start"` to `aro_fs_application_start`. Every feature set function has a dedicated `error_exit` block: actions that fail branch into it, which prints the error message before returning null.

The resulting IR looks like this:

```llvm
define ptr @aro_fs_application_start(ptr %0) {
entry:
  %1 = alloca ptr
  store ptr null, ptr %1
  ...
  br label %normal_return

normal_return:
  %2 = load ptr, ptr %1
  ret ptr %2

error_exit:
  call void @aro_context_print_error(ptr %0)
  ret ptr null
}
```

---

## Statement Generation

For each statement, the generator: binds literal values to the special `_literal_` variable, allocates descriptor structs on the stack, fills their fields with string pointers, and calls the action function.

The generated LLVM IR for a statement like `Log "Hello, World!" to the <console>.` looks like:

```llvm
  ; Bind literal to _literal_
  call void @aro_variable_bind_string(ptr %ctx, ptr @.str._literal_, ptr @.str.hello)

  ; Allocate and fill result descriptor
  %s0_rd = alloca %AROResultDescriptor
  %s0_rd_base = getelementptr inbounds %AROResultDescriptor, ptr %s0_rd, i32 0, i32 0
  store ptr @.str.message, ptr %s0_rd_base
  ; ... fill specifiers ptr and count

  ; Allocate and fill object descriptor
  %s0_od = alloca %AROObjectDescriptor
  ; ... fill base ("console"), preposition (4=to), specifiers, count

  ; Call action
  %s0_result = call ptr @aro_action_log(ptr %ctx, ptr %s0_rd, ptr %s0_od)
  store ptr %s0_result, ptr %result_ptr
```

The descriptor structs are allocated on the stack within each feature set function call frame, so there is no heap allocation overhead per statement.

<svg viewBox="0 0 600 280" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .struct { fill: #e8f4e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow22); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow22" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- ResultDescriptor -->
  <rect x="30" y="30" width="220" height="100" rx="5" class="box struct"/>
  <text x="140" y="55" class="title" text-anchor="middle">%AROResultDescriptor</text>
  <text x="45" y="75" class="label">ptr base      → "message"</text>
  <text x="45" y="95" class="label">ptr specifiers → null | [ptr*]</text>
  <text x="45" y="115" class="label">i32 count     → 0</text>

  <!-- ObjectDescriptor -->
  <rect x="30" y="150" width="220" height="110" rx="5" class="box struct"/>
  <text x="140" y="175" class="title" text-anchor="middle">%AROObjectDescriptor</text>
  <text x="45" y="195" class="label">ptr base       → "console"</text>
  <text x="45" y="215" class="label">i32 preposition → 4 (to)</text>
  <text x="45" y="235" class="label">ptr specifiers  → null</text>
  <text x="45" y="255" class="label">i32 count       → 0</text>

  <!-- Action call -->
  <rect x="320" y="90" width="250" height="80" rx="5" class="box"/>
  <text x="445" y="115" class="title" text-anchor="middle">Action Call</text>
  <text x="330" y="140" class="label">@aro_action_log(</text>
  <text x="340" y="155" class="label">ptr %ctx,</text>
  <text x="340" y="170" class="label">ptr %result_desc, ptr %object_desc)</text>

  <!-- Arrows -->
  <path d="M 250 80 L 320 115" class="arrow"/>
  <path d="M 250 200 L 320 145" class="arrow"/>
</svg>

**Figure 8.3**: Descriptor struct layout. Base names are string pointers, specifiers are arrays of pointers.

---

## Control Flow: When Guards

A `when` condition is serialized to JSON and passed to the runtime's `aro_evaluate_when_guard` function. This generates a conditional branch: if the guard passes, execute the statement body; if not, jump to the next statement.

---

## Control Flow: Match Expressions

Match statements generate a chain of comparisons:

```llvm
; match <status>
m0:
  %m0_subject_val = call ptr @aro_variable_resolve(ptr %ctx, ptr @.str.status)
  %m0_subject_str = call ptr @aro_value_as_string(ptr %m0_subject_val)
  br label %m0_case0_check

m0_case0_check:
  %m0_case0_cmp = call i32 @strcmp(ptr %m0_subject_str, ptr @.str.active)
  %m0_case0_match = icmp eq i32 %m0_case0_cmp, 0
  br i1 %m0_case0_match, label %m0_case0_body, label %m0_case1_check

m0_case0_body:
  ; ... statements for "active" case
  br label %m0_end

m0_case1_check:
  ; ... check next pattern
```

---

## Control Flow: For-Each Loops

Sequential loops create iteration contexts:

```llvm
fe0_header:
  %fe0_i = phi i64 [ 0, %fe0_init ], [ %fe0_next_i, %fe0_continue ]

  ; Create child context for this iteration (avoids immutability violation)
  %fe0_iter_ctx = call ptr @aro_context_create_child(ptr %ctx, ptr null)

  ; Get element and bind to item variable
  %fe0_element = call ptr @aro_array_get(ptr %fe0_collection, i64 %fe0_i)
  call void @aro_variable_bind_value(ptr %fe0_iter_ctx, ptr @.str.item, ptr %fe0_element)

  ; Execute body statements (using child context)
  ; ...

  ; Cleanup
  call void @aro_context_destroy(ptr %fe0_iter_ctx)
  br label %fe0_continue

fe0_continue:
  %fe0_next_i = add i64 %fe0_i, 1
  %fe0_done = icmp sge i64 %fe0_next_i, %fe0_count
  br i1 %fe0_done, label %fe0_end, label %fe0_header
```

---

## Control Flow: Range Loops and While Loops

ARO added `RangeLoop` and `WhileLoop` statements. Both follow the same Swifty-LLVM API pattern as `ForEachLoop`.

### Range Loop

```aro
for <i> from 1 to <count> { ... }
```

Generates a phi-node based integer loop with bounds from the `from`/`to` expressions:

```llvm
rl0_init:
  %rl0_start = ... ; evaluate from-expression
  %rl0_end   = ... ; evaluate to-expression
  br label %rl0_header

rl0_header:
  %rl0_i = phi i64 [ %rl0_start, %rl0_init ], [ %rl0_next, %rl0_continue ]
  call void @aro_variable_bind_int(ptr %iter_ctx, ptr @.str.i, i64 %rl0_i)
  ; ... body statements ...
  br label %rl0_continue

rl0_continue:
  %rl0_next = add i64 %rl0_i, 1
  %rl0_done = icmp sgt i64 %rl0_next, %rl0_end
  br i1 %rl0_done, label %rl0_end, label %rl0_header
```

### While Loop

```aro
while <condition> { ... }
```

Evaluates the condition JSON expression on each iteration. `BreakStatement` branches to the `while_end` block:

```llvm
wl0_header:
  %wl0_cond = call i32 @aro_evaluate_when_guard(ptr %ctx, ptr @.str.while_cond)
  %wl0_pass = icmp ne i32 %wl0_cond, 0
  br i1 %wl0_pass, label %wl0_body, label %wl0_end

wl0_body:
  ; ... body statements ...
  ; BreakStatement → br label %wl0_end
  br label %wl0_header

wl0_end:
```

---

## Parallel Loops

Parallel for-each loops extract the loop body into a separate LLVM function. The feature set calls a runtime function (`aro_parallel_for_each_execute`), passing the body function as a pointer. The runtime runs iterations concurrently via Swift's `TaskGroup`, calling the body function once per item.

The body function is emitted as a sibling of the feature set function:

```llvm
define ptr @aro_loop_body_0(ptr %loop_ctx, ptr %loop_item, i64 %loop_index) {
entry:
  call void @aro_variable_bind_value(ptr %loop_ctx, ptr @.str.item, ptr %loop_item)
  ; ... body statements using %loop_ctx
  ret ptr null
}
```

<svg viewBox="0 0 600 250" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 1.5; }
    .func { fill: #e8f4e8; }
    .runtime { fill: #f4e8e8; }
    .arrow { fill: none; stroke: #333; stroke-width: 1.5; marker-end: url(#arrow23); }
    .label { font-family: monospace; font-size: 10px; fill: #333; }
    .title { font-family: monospace; font-size: 11px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrow23" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#333"/>
    </marker>
  </defs>

  <!-- Feature set function -->
  <rect x="30" y="30" width="180" height="80" rx="5" class="box func"/>
  <text x="120" y="55" class="title" text-anchor="middle">aro_fs_main</text>
  <text x="40" y="75" class="label">call @aro_parallel_for_each</text>
  <text x="40" y="90" class="label">  (..., ptr @body_0, ...)</text>

  <!-- Parallel executor (runtime) -->
  <rect x="260" y="30" width="180" height="80" rx="5" class="box runtime"/>
  <text x="350" y="55" class="title" text-anchor="middle">Runtime Executor</text>
  <text x="270" y="75" class="label">TaskGroup.addTask {</text>
  <text x="280" y="90" class="label">body_func(ctx, item, i)</text>
  <text x="270" y="105" class="label">}</text>

  <!-- Body function -->
  <rect x="260" y="150" width="180" height="80" rx="5" class="box func"/>
  <text x="350" y="175" class="title" text-anchor="middle">@aro_loop_body_0</text>
  <text x="270" y="195" class="label">Bind item variable</text>
  <text x="270" y="210" class="label">Execute body statements</text>
  <text x="270" y="225" class="label">Return null</text>

  <!-- Arrows -->
  <path d="M 210 70 L 260 70" class="arrow"/>
  <text x="218" y="63" class="label">func ptr</text>
  <path d="M 350 110 L 350 150" class="arrow"/>
  <text x="360" y="135" class="label">calls</text>
</svg>

**Figure 8.4**: Parallel loop code structure. The feature set passes a function pointer to the runtime executor.

---

## Main Function Generation

The `main` function orchestrates initialization, handler registration, and execution:

```llvm
define i32 @main(i32 %argc, ptr %argv) {
entry:
  ; Initialize runtime
  %runtime = call ptr @aro_runtime_init()
  store ptr %runtime, ptr @global_runtime

  ; Set embedded OpenAPI spec (if available)
  call void @aro_set_embedded_openapi(ptr @.str.openapi_json)

  ; Create context
  %ctx = call ptr @aro_context_create_named(ptr %runtime, ptr @.str.app_start)

  ; Register event handlers BEFORE execution
  call void @aro_runtime_register_handler(ptr %runtime,
      ptr @.str.UserCreated, ptr @aro_fs_send_welcome_email)

  ; Execute Application-Start
  %result = call ptr @aro_fs_application_start(ptr %ctx)

  ; Wait for pending event handlers
  %await_result = call i32 @aro_runtime_await_pending_events(ptr %runtime, double 10.0)

  ; Cleanup and exit
  call void @aro_context_print_response(ptr %ctx)
  call void @aro_context_destroy(ptr %ctx)
  call void @aro_runtime_shutdown(ptr %runtime)
  ret i32 0
}
```

---

## Linking Process

After `llc` produces the object file, the linker calls `clang` to combine it with:

| Linked Component | Purpose |
|-----------------|---------|
| `libARORuntime` | All 61 actions, event bus, runtime lifecycle |
| Swift runtime | `libswiftCore` and friends |
| Foundation | Networking, file system, JSON |
| Platform libc | Standard C runtime |

Platform differences:
- **macOS**: Uses `@rpath` for library discovery. May need code signing for distribution.
- **Linux**: Sets rpath via `-Wl,-rpath`. Uses system Swift libraries.
- **Windows**: Uses MSVC runtime. Different library naming conventions (`.dll` vs `.dylib`).

---

## Optimization Levels

The `llc` tool accepts standard LLVM optimization flags:

| Flag | Level |
|------|-------|
| `-O0` | No optimization (default) |
| `-O1` | Basic optimization |
| `-O2` | Standard optimization |
| `-O3` | Aggressive optimization |

Size optimization (`-Os`, `-Oz`) is applied during linking. Strip flags can be added to remove debug symbols from the final binary.

---

## Chapter Summary

Native compilation transforms ARO programs into standalone executables:

1. **LLVMCodeGenerator** traverses the AST using the Swifty-LLVM C API for type-safe IR generation
2. **String constants** are collected first, then referenced by pointer throughout
3. **Feature sets** become functions with dedicated `normal_return` and `error_exit` blocks
4. **Statements** become descriptor allocations and action calls, with descriptors on the stack
5. **Control flow** (when, match, for-each, range-loop, while-loop, break) uses LLVM branches and phi nodes
6. **Parallel loops** extract the body into a separate function, called via function pointer
7. **Main function** initializes the runtime, registers handlers, executes the entry point
8. **Linking** combines object code with the Swift runtime and ARO library

The Swifty-LLVM C API approach provides compile-time type safety and module verification, replacing the earlier text-based generator. The cost is requiring LLVM 20 as a build dependency and a more complex build setup — a worthwhile trade for a production compiler.

Implementation references:
- `Sources/AROCompiler/LLVMC/LLVMCodeGenerator.swift` — Main code generator
- `Sources/AROCompiler/LLVMC/LLVMTypeMapper.swift` — Descriptor struct type definitions
- `Sources/AROCompiler/LLVMC/LLVMExternalDeclEmitter.swift` — Runtime function declarations
- `Sources/AROCompiler/Linker.swift` — Object linking

---

*Next: Chapter 9 — Runtime Bridge*
