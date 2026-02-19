# ARO-0009: Native Compilation

* Proposal: ARO-0009
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004, ARO-0005

## Abstract

This proposal defines native binary compilation for ARO applications via the `aro build` command. ARO programs are compiled to LLVM IR, then to native machine code, enabling deployment as standalone executables while maintaining full access to runtime services through a Swift-based runtime library.

## Motivation

While the interpreted `aro run` command is excellent for development and rapid iteration, production deployments benefit from native compilation:

1. **Faster Startup** - No interpreter initialization overhead
2. **Lower Memory Footprint** - No interpreter runtime in memory
3. **Distribution Simplicity** - Single binary deployment
4. **Cross-Platform Deployment** - Compile for different target platforms
5. **Integration** - Link with existing native codebases

---

## 1. Compilation Pipeline

The `aro build` command transforms ARO source files into a native executable through a multi-stage pipeline:

```
+----------------------------------------------------------+
|                    ARO Source Files                       |
|                      (.aro files)                         |
+---------------------------+------------------------------+
                            |
                            v
+----------------------------------------------------------+
|                       AROParser                           |
|                                                           |
|          Lexer --> Parser --> Semantic Analyzer           |
+---------------------------+------------------------------+
                            |
                            v
+----------------------------------------------------------+
|                   LLVMCodeGenerator                       |
|                                                           |
|              Transforms AST to LLVM IR text               |
+---------------------------+------------------------------+
                            |
                            v
+----------------------------------------------------------+
|                    LLVM IR Text (.ll)                     |
|                                                           |
|           Feature sets as LLVM function calls             |
+---------------------------+------------------------------+
                            |
                            v
+----------------------------------------------------------+
|                  llc (LLVM Compiler)                      |
|                                                           |
|              Compiles IR to object file (.o)              |
+---------------------------+------------------------------+
                            |
                            v
+----------------------------------------------------------+
|                    Linker (clang)                         |
|                                                           |
|              Links with libAROCRuntime.a                  |
+---------------------------+------------------------------+
                            |
                            v
+----------------------------------------------------------+
|                    Native Binary                          |
|                                                           |
|               Standalone executable                       |
+----------------------------------------------------------+
```

### Pipeline Stages

| Stage | Input | Output | Tool |
|-------|-------|--------|------|
| Parse | `.aro` files | AST | AROParser |
| Code Gen | AST | LLVM IR (.ll) | LLVMCodeGenerator |
| Compile | LLVM IR | Object file (.o) | llc |
| Link | Object file + runtime | Executable | clang |

---

## 2. The aro build Command

### Basic Usage

```bash
# Compile application to native binary
aro build ./MyApp

# Output: ./MyApp/MyApp (executable)
```

### Command Options

| Option | Description |
|--------|-------------|
| `--verbose` | Show detailed compilation progress |
| `--optimize` | Enable LLVM optimizations (O2) |
| `--emit-llvm` | Output LLVM IR file for inspection |
| `--keep-intermediate` | Preserve `.ll` and `.o` files |

### Examples

```bash
# Basic build
aro build ./MyApp

# Verbose build with optimizations
aro build ./MyApp --verbose --optimize

# Emit LLVM IR for inspection
aro build ./MyApp --emit-llvm

# Keep intermediate files for debugging
aro build ./MyApp --keep-intermediate
```

### Output Structure

```
MyApp/
+-- main.aro
+-- users.aro
+-- MyApp              # Final executable
+-- .build/            # Build artifacts (if --keep-intermediate)
    +-- MyApp.ll       # Generated LLVM IR
    +-- MyApp.o        # Object file
```

---

## 3. LLVM Code Generation

The `LLVMCodeGenerator` transforms the analyzed AST into textual LLVM IR.

### Generation Strategy

1. **Module Header** - Target triple and data layout
2. **Type Definitions** - Descriptor structures for ARO statements
3. **External Declarations** - Runtime function declarations
4. **String Constants** - All string literals as global constants
5. **Feature Set Functions** - One LLVM function per feature set
6. **Main Function** - Entry point calling Application-Start

### Example Transformation

**ARO Source:**
```aro
(Application-Start: Hello World) {
    Create the <greeting> with "Hello, World!".
    Log "Ready!" to the <console>.
    Return an <OK: status> for the <application>.
}
```

**Generated LLVM IR:**
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
@.str.fs_name = private unnamed_addr constant [18 x i8] c"Application-Start\00"
@.str.greeting = private unnamed_addr constant [14 x i8] c"Hello, World!\00"
@.str.ready = private unnamed_addr constant [7 x i8] c"Ready!\00"
@.str.console = private unnamed_addr constant [8 x i8] c"console\00"

; Feature Set: Application-Start
define ptr @aro_fs_application_start(ptr %ctx) {
entry:
  %__result = alloca ptr
  store ptr null, ptr %__result

  ; Create the <greeting> with "Hello, World!"
  call void @aro_variable_bind_string(ptr %ctx, ptr @.str.greeting, ptr @.str.greeting)
  ; ... descriptor setup and action call ...

  ; Log "Ready!" to the <console>
  ; ... log action call ...

  ; Return an <OK: status> for the <application>
  ; ... return action call ...

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
  %ctx = call ptr @aro_context_create_named(ptr %runtime, ptr @.str.fs_name)
  %result = call ptr @aro_fs_application_start(ptr %ctx)
  call void @aro_context_destroy(ptr %ctx)
  call void @aro_runtime_shutdown(ptr %runtime)
  ret i32 0
}
```

### Descriptor Structures

ARO statements pass metadata to runtime functions through descriptor structures:

```llvm
; Result descriptor: base name, specifiers array, specifier count
%AROResultDescriptor = type { ptr, ptr, i32 }

; Object descriptor: base name, preposition enum, specifiers array, count
%AROObjectDescriptor = type { ptr, i32, ptr, i32 }
```

### Preposition Encoding

Prepositions are encoded as integers for efficient runtime dispatch:

| Preposition | Integer Value |
|-------------|---------------|
| `from` | 1 |
| `for` | 2 |
| `with` | 3 |
| `to` | 4 |
| `into` | 5 |
| `via` | 6 |
| `against` | 7 |
| `on` | 8 |

---

## 4. AROCRuntime Bridge

The `AROCRuntime` is a Swift static library that provides C-callable functions for the compiled code.

### Architecture

```
+----------------------------------------------------------+
|                    Compiled ARO Binary                    |
|                                                           |
|  main() --> aro_fs_*() --> aro_action_*() calls          |
+---------------------------+------------------------------+
                            |
                            | C function calls
                            v
+----------------------------------------------------------+
|                    libAROCRuntime.a                       |
|                                                           |
|  +----------------+  +----------------+  +-------------+  |
|  | RuntimeBridge  |  | ActionBridge   |  | ServiceBridge| |
|  |                |  |                |  |             |  |
|  | @_cdecl funcs  |  | @_cdecl funcs  |  | @_cdecl     |  |
|  | for lifecycle  |  | for all 50     |  | for HTTP,   |  |
|  |                |  | actions        |  | File, Socket|  |
|  +----------------+  +----------------+  +-------------+  |
+---------------------------+------------------------------+
                            |
                            | Swift calls
                            v
+----------------------------------------------------------+
|                      ARORuntime                           |
|                                                           |
|        ExecutionEngine, ActionRegistry, Services          |
+----------------------------------------------------------+
```

### @_cdecl Function Declarations

Swift functions are exposed to C using the `@_cdecl` attribute:

```swift
@_cdecl("aro_runtime_init")
public func aro_runtime_init() -> UnsafeMutableRawPointer? {
    let runtime = ARORuntime()
    return Unmanaged.passRetained(runtime).toOpaque()
}

@_cdecl("aro_action_log")
public func aro_action_log(
    _ ctx: UnsafeRawPointer?,
    _ result: UnsafeRawPointer?,
    _ object: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctx = ctx else { return nil }
    let context = Unmanaged<ExecutionContext>.fromOpaque(ctx).takeUnretainedValue()
    // Execute log action...
    return nil
}
```

### Source Files

```
Sources/AROCRuntime/
+-- RuntimeBridge.swift    # Core runtime C interface
+-- ActionBridge.swift     # All action @_cdecl functions
+-- ServiceBridge.swift    # HTTP/File/Socket C interface
```

---

## 5. Runtime Function Table

### Lifecycle Functions

| Function | Description |
|----------|-------------|
| `aro_runtime_init` | Initialize the ARO runtime, returns runtime pointer |
| `aro_runtime_shutdown` | Shutdown runtime and cleanup resources |
| `aro_context_create` | Create anonymous execution context |
| `aro_context_create_named` | Create named execution context |
| `aro_context_destroy` | Destroy execution context |

### Variable Functions

| Function | Description |
|----------|-------------|
| `aro_variable_bind_string` | Bind string value to variable |
| `aro_variable_bind_int` | Bind integer value to variable |
| `aro_variable_bind_double` | Bind float value to variable |
| `aro_variable_bind_bool` | Bind boolean value to variable |
| `aro_variable_resolve` | Resolve variable to value |
| `aro_value_free` | Free allocated value memory |

### Action Functions

All built-in actions are exposed as C-callable functions:

**Request Actions (External --> Internal):**

| Function | Verb |
|----------|------|
| `aro_action_extract` | Extract |
| `aro_action_parse` | Parse |
| `aro_action_retrieve` | Retrieve |
| `aro_action_fetch` | Fetch |
| `aro_action_read` | Read |
| `aro_action_receive` | Receive |
| `aro_action_get` | Get |
| `aro_action_load` | Load |

**Own Actions (Internal --> Internal):**

| Function | Verb |
|----------|------|
| `aro_action_compute` | Compute |
| `aro_action_validate` | Validate |
| `aro_action_compare` | Compare |
| `aro_action_transform` | Transform |
| `aro_action_filter` | Filter |
| `aro_action_sort` | Sort |
| `aro_action_merge` | Merge |
| `aro_action_create` | Create |
| `aro_action_update` | Update |
| `aro_action_delete` | Delete |

**Response Actions (Internal --> External):**

| Function | Verb |
|----------|------|
| `aro_action_return` | Return |
| `aro_action_throw` | Throw |

**Export Actions:**

| Function | Verb |
|----------|------|
| `aro_action_send` | Send |
| `aro_action_log` | Log |
| `aro_action_store` | Store |
| `aro_action_write` | Write |
| `aro_action_publish` | Publish |
| `aro_action_emit` | Emit |

**Server Actions:**

| Function | Verb |
|----------|------|
| `aro_action_start` | Start |
| `aro_action_stop` | Stop |
| `aro_action_listen` | Listen |
| `aro_action_route` | Route |
| `aro_action_watch` | Watch |
| `aro_action_keepalive` | Keepalive |

**External Actions:**

| Function | Verb |
|----------|------|
| `aro_action_call` | Call |

### Service Functions

| Function | Description |
|----------|-------------|
| `aro_http_server_create` | Create HTTP server instance |
| `aro_http_server_start` | Start listening on host:port |
| `aro_http_server_stop` | Stop the server gracefully |
| `aro_http_client_request` | Make HTTP request |
| `aro_file_read` | Read file contents |
| `aro_file_write` | Write file contents |
| `aro_file_watch` | Start watching file/directory |
| `aro_socket_connect` | Connect to socket server |
| `aro_socket_send` | Send data over socket |
| `aro_socket_close` | Close socket connection |

---

## 6. Platform Support

### Supported Platforms

| Platform | Architecture | Status |
|----------|--------------|--------|
| macOS | arm64 (Apple Silicon) | Supported |
| macOS | x86_64 (Intel) | Supported |
| Linux | x86_64 | Supported |
| Linux | arm64 | Supported |
| Windows | x86_64 | Future |

### Requirements

| Dependency | Purpose | Installation |
|------------|---------|--------------|
| LLVM | Compile IR to object code | `brew install llvm` (macOS) |
| Clang | Link object files | Included with Xcode / LLVM |
| Swift | Build AROCRuntime | Swift 6.2+ toolchain |

### Target Triple Examples

```llvm
; macOS Apple Silicon
target triple = "arm64-apple-macosx14.0.0"

; macOS Intel
target triple = "x86_64-apple-macosx14.0.0"

; Linux x86_64
target triple = "x86_64-unknown-linux-gnu"

; Linux ARM64
target triple = "aarch64-unknown-linux-gnu"
```

---

## 7. Binary Structure

### What Gets Linked

The final executable contains:

```
+----------------------------------------------------------+
|                     Final Executable                      |
+----------------------------------------------------------+
|                                                           |
|  +----------------------------------------------------+  |
|  |              Compiled ARO Code                      |  |
|  |                                                     |  |
|  |  - main() entry point                              |  |
|  |  - aro_fs_*() feature set functions               |  |
|  |  - String constants                                |  |
|  +----------------------------------------------------+  |
|                                                           |
|  +----------------------------------------------------+  |
|  |              libAROCRuntime.a                       |  |
|  |                                                     |  |
|  |  - Runtime initialization/shutdown                 |  |
|  |  - All action implementations                      |  |
|  |  - Service implementations (HTTP, File, Socket)    |  |
|  +----------------------------------------------------+  |
|                                                           |
|  +----------------------------------------------------+  |
|  |              Swift Runtime Libraries                |  |
|  |                                                     |  |
|  |  - libswiftCore                                    |  |
|  |  - libswiftFoundation                              |  |
|  |  - libswift_Concurrency                            |  |
|  +----------------------------------------------------+  |
|                                                           |
|  +----------------------------------------------------+  |
|  |              System Libraries                       |  |
|  |                                                     |  |
|  |  - libc                                            |  |
|  |  - libpthread                                      |  |
|  |  - Network frameworks (platform-specific)          |  |
|  +----------------------------------------------------+  |
|                                                           |
+----------------------------------------------------------+
```

### Dependencies at Runtime

| Dependency | Bundled | Notes |
|------------|---------|-------|
| ARO Code | Yes | Compiled into binary |
| AROCRuntime | Yes | Statically linked |
| Swift Runtime | Dynamic | Required on target system |
| System Libraries | Dynamic | Standard on all platforms |

### Binary Size Considerations

| Component | Approximate Size |
|-----------|------------------|
| Compiled ARO code | ~10-100 KB |
| AROCRuntime | ~1-5 MB |
| Swift runtime overhead | ~20-50 MB (dynamic linking) |

---

## 8. Test Feature Set Exclusion

When compiling, test feature sets are automatically excluded from the binary. Feature sets with business activity ending in "Test" or "Tests" are stripped:

```aro
(* Included in binary *)
(User Authentication: Security) {
    ...
}

(* Excluded from binary - ends in "Test" *)
(User Authentication: Security Test) {
    ...
}

(* Excluded from binary - ends in "Tests" *)
(API Endpoints: Integration Tests) {
    ...
}
```

---

## Complete Example

### Source

**HelloWorld/main.aro:**
```aro
(Application-Start: Hello World) {
    Log "Hello, World!" to the <console>.
    Log "Native compilation works!" to the <console>.
    Return an <OK: status> for the <application>.
}
```

### Build

```bash
$ aro build ./HelloWorld --verbose

[1/4] Parsing HelloWorld/main.aro...
[2/4] Generating LLVM IR...
[3/4] Compiling to object file...
[4/4] Linking with AROCRuntime...

Build complete: HelloWorld/HelloWorld
```

### Run

```bash
$ ./HelloWorld/HelloWorld
Hello, World!
Native compilation works!
```

---

## Summary

| Aspect | Description |
|--------|-------------|
| **Command** | `aro build ./MyApp` |
| **Pipeline** | AST --> LLVM IR --> Object --> Executable |
| **Runtime** | libAROCRuntime.a (Swift static library) |
| **Bridge** | @_cdecl functions for C interoperability |
| **Platforms** | macOS (arm64, x86_64), Linux (x86_64, arm64) |
| **Output** | Single standalone executable |
| **Test Exclusion** | Feature sets ending in "Test/Tests" stripped |

Native compilation provides production-ready deployment while preserving the full ARO programming model and runtime services.
