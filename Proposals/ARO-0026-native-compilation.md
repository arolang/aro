# ARO-0026: Native Compilation

**Status:** Implemented
**Version:** 1.1.0
**Authors:** Claude, ARO Team

## Summary

This proposal introduces native binary compilation support for ARO applications via the `aro build` command. ARO programs are compiled to LLVM IR, then to native machine code, enabling deployment without the interpreter while maintaining full access to runtime services through a Swift-based runtime library.

## Motivation

While the interpreted `aro run` command is excellent for development and quick iteration, production deployments often benefit from native compilation:

1. **Faster startup** - No interpreter initialization overhead
2. **Lower memory footprint** - No interpreter runtime in memory
3. **Distribution simplicity** - Single binary deployment
4. **Cross-platform deployment** - Compile for different targets
5. **Integration** - Link with existing native codebases

## Design Overview

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    ARO Source Files                          │
│                      (.aro files)                            │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    AROParser                                 │
│           (Lexer → Parser → Semantic Analyzer)              │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  LLVMCodeGenerator                           │
│         (Transforms AST to LLVM IR text)                     │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                   LLVM IR Text (.ll)                         │
│           (Feature sets as LLVM functions)                   │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  llc (LLVM Compiler)                         │
│           (Compiles IR to object file)                       │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    Linker (clang)                            │
│         (Links with libAROCRuntime.a)                        │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  Native Binary                               │
│            (Standalone executable)                           │
└─────────────────────────────────────────────────────────────┘
```

### Components

#### 1. LLVMCodeGenerator

Transforms the analyzed AST into LLVM IR text:

- Each feature set becomes an LLVM function (`define ptr @aro_fs_...`)
- ARO statements become calls to runtime bridge functions
- Literal values are stored as LLVM string constants
- `Application-Start` feature set generates `main()` entry point
- Type-safe descriptor structs for result/object passing

#### 2. LLVMEmitter

Uses the `llc` command-line tool to compile LLVM IR:

- Converts `.ll` files to object files (`.o`)
- Supports optimization levels (-O0 to -O3)
- Can emit assembly for debugging

#### 3. CCompiler (Linker)

Links object files with the runtime:

- Uses clang/gcc for final linking
- Links with `libAROCRuntime.a` (Swift static library)
- Handles platform-specific Swift runtime linking

#### 4. AROCRuntime (Swift Static Library)

A Swift static library exposing C-callable functions via `@_cdecl`:

```swift
@_cdecl("aro_runtime_init")
public func aro_runtime_init() -> UnsafeMutableRawPointer? { ... }

@_cdecl("aro_action_log")
public func aro_action_log(
    _ ctx: UnsafeRawPointer?,
    _ result: UnsafeRawPointer?,
    _ object: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? { ... }
```

## Usage

### Basic Build

```bash
# Compile to native binary
aro build ./MyApp

# Emit LLVM IR for inspection
aro build ./MyApp --emit-llvm

# Enable optimizations
aro build ./MyApp --optimize

# Verbose output
aro build ./MyApp --verbose

# Keep intermediate files (.ll, .o)
aro build ./MyApp --keep-intermediate
```

### Output Files

```
MyApp/
├── main.aro
├── MyApp           # Final executable
└── .build/
    ├── MyApp.ll    # Generated LLVM IR (if --keep-intermediate)
    └── MyApp.o     # Object file (if --keep-intermediate)
```

## Generated LLVM IR Structure

For an ARO program:

```aro
(Application-Start: Entry Point) {
    <Create> the <greeting: String> with "Hello, World!".
    <Log> the <greeting> for the <console>.
    <Return> an <OK: status> for the <application>.
}
```

The generated LLVM IR:

```llvm
; ModuleID = 'aro_program'
source_filename = "aro_program.ll"
target triple = "arm64-apple-macosx14.0.0"

; Type definitions
%AROResultDescriptor = type { ptr, ptr, i32 }
%AROObjectDescriptor = type { ptr, i32, ptr, i32 }

; External runtime function declarations
declare ptr @aro_runtime_init()
declare void @aro_runtime_shutdown(ptr)
declare ptr @aro_context_create_named(ptr, ptr)
declare void @aro_context_destroy(ptr)
declare void @aro_variable_bind_string(ptr, ptr, ptr)
declare ptr @aro_action_create(ptr, ptr, ptr)
declare ptr @aro_action_log(ptr, ptr, ptr)
declare ptr @aro_action_return(ptr, ptr, ptr)
declare void @aro_value_free(ptr)

; String constants
@.str.0 = private unnamed_addr constant [18 x i8] c"Application-Start\00"
@.str.1 = private unnamed_addr constant [14 x i8] c"Hello, World!\00"
@.str.2 = private unnamed_addr constant [9 x i8] c"greeting\00"
@.str.3 = private unnamed_addr constant [8 x i8] c"console\00"
@.str.4 = private unnamed_addr constant [3 x i8] c"OK\00"
@.str.5 = private unnamed_addr constant [9 x i8] c"_literal_\00"

; Feature Set: Application-Start
define ptr @aro_fs_application_start(ptr %ctx) {
entry:
  %__result = alloca ptr
  store ptr null, ptr %__result

  ; <Create> the <greeting> with "Hello, World!"
  call void @aro_variable_bind_string(ptr %ctx, ptr @.str.5, ptr @.str.1)
  %s0_result_desc = alloca %AROResultDescriptor
  ; ... descriptor setup ...
  %s0_action_result = call ptr @aro_action_create(ptr %ctx, ptr %s0_result_desc, ptr %s0_object_desc)
  store ptr %s0_action_result, ptr %__result

  ; <Log> the <greeting> for the <console>
  ; ... similar pattern ...

  ; <Return> an <OK: status> for the <application>
  ; ... similar pattern ...

  %final_result = load ptr, ptr %__result
  ret ptr %final_result
}

; Main entry point
define i32 @main(i32 %argc, ptr %argv) {
entry:
  %runtime = call ptr @aro_runtime_init()
  %runtime_null = icmp eq ptr %runtime, null
  br i1 %runtime_null, label %runtime_fail, label %runtime_ok

runtime_fail:
  ret i32 1

runtime_ok:
  %ctx = call ptr @aro_context_create_named(ptr %runtime, ptr @.str.0)
  %result = call ptr @aro_fs_application_start(ptr %ctx)
  ; ... cleanup ...
  ret i32 0
}
```

## Runtime Bridge Functions

### Lifecycle

| Function | Description |
|----------|-------------|
| `aro_runtime_init` | Initialize the ARO runtime |
| `aro_runtime_shutdown` | Shutdown and cleanup |
| `aro_context_create` | Create execution context |
| `aro_context_create_named` | Create named context |
| `aro_context_destroy` | Destroy context |

### Variables

| Function | Description |
|----------|-------------|
| `aro_variable_bind_string` | Bind string value |
| `aro_variable_bind_int` | Bind integer value |
| `aro_variable_bind_double` | Bind float value |
| `aro_variable_bind_bool` | Bind boolean value |
| `aro_variable_resolve` | Resolve variable value |
| `aro_value_free` | Free value memory |

### Actions

All built-in actions are exposed:

| Function | Semantic Role |
|----------|---------------|
| `aro_action_extract` | REQUEST |
| `aro_action_fetch` | REQUEST |
| `aro_action_retrieve` | REQUEST |
| `aro_action_read` | REQUEST |
| `aro_action_compute` | OWN |
| `aro_action_validate` | OWN |
| `aro_action_compare` | OWN |
| `aro_action_transform` | OWN |
| `aro_action_create` | OWN |
| `aro_action_update` | OWN |
| `aro_action_return` | RESPONSE |
| `aro_action_throw` | RESPONSE |
| `aro_action_send` | EXPORT |
| `aro_action_log` | EXPORT |
| `aro_action_store` | EXPORT |
| `aro_action_write` | EXPORT |
| `aro_action_publish` | EXPORT |
| `aro_action_start` | SERVER |
| `aro_action_listen` | SERVER |
| `aro_action_route` | SERVER |
| `aro_action_watch` | SERVER |
| `aro_action_keepalive` | SERVER |
| `aro_action_call` | EXTERNAL |

### Services

| Function | Description |
|----------|-------------|
| `aro_http_server_create` | Create HTTP server instance |
| `aro_http_server_start` | Start listening on host:port |
| `aro_http_server_stop` | Stop the server |
| `aro_file_read` | Read file contents |
| `aro_file_write` | Write file contents |

## Platform Support

### Supported Platforms

- **macOS** (arm64, x86_64)
- **Linux** (x86_64, arm64)

### Requirements

- LLVM toolchain (`llc` command) - `brew install llvm`
- C compiler (clang preferred)
- Swift toolchain (for building AROCRuntime)

## Implementation Details

### Source Files

```
Sources/
├── AROCompiler/
│   ├── LLVMCodeGenerator.swift   # AST to LLVM IR transformation
│   └── Linker.swift              # LLVMEmitter and CCompiler
├── AROCRuntime/
│   ├── RuntimeBridge.swift       # Core runtime C interface
│   ├── ActionBridge.swift        # Action C interface
│   └── ServiceBridge.swift       # HTTP/File/Socket C interface
└── AROCLI/Commands/
    └── BuildCommand.swift        # aro build command
```

### LLVM IR Generation

The `LLVMCodeGenerator` produces textual LLVM IR:

1. **Module header** - Target triple and data layout
2. **Type definitions** - `%AROResultDescriptor`, `%AROObjectDescriptor`
3. **External declarations** - Runtime function declarations
4. **String constants** - All string literals as global constants
5. **Feature set functions** - One function per feature set
6. **Main function** - Entry point calling Application-Start

### Descriptor Structures

```llvm
; Result descriptor: base name, specifiers array, specifier count
%AROResultDescriptor = type { ptr, ptr, i32 }

; Object descriptor: base name, preposition enum, specifiers array, count
%AROObjectDescriptor = type { ptr, i32, ptr, i32 }
```

### Preposition Encoding

| Preposition | Integer Value |
|-------------|---------------|
| from | 1 |
| for | 2 |
| with | 3 |
| to | 4 |
| into | 5 |
| via | 6 |
| against | 7 |
| on | 8 |

## Test Feature Set Stripping

When compiling, test feature sets (those with business activity ending in "Test" or "Tests") are automatically excluded from the binary (ARO-0015).

## Future Enhancements

1. **Full static linking** - Embed Swift runtime for truly standalone binaries
2. **Cross-compilation** - Compile for different target architectures
3. **Debug info** - DWARF debug information in compiled binaries
4. **Profile-guided optimization** - PGO support for hot paths
5. **WebAssembly target** - Compile to WASM for browser deployment
6. **Direct LLVM API** - Use LLVM C API instead of textual IR

## Related Proposals

- ARO-0020: Runtime Architecture
- ARO-0021: HTTP Server
- ARO-0022: HTTP Client
- ARO-0023: File System
- ARO-0024: Sockets

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification (C code generation) |
| 1.1 | 2024-12 | Updated to LLVM IR generation pipeline |
