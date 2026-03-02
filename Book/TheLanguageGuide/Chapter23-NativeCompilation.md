# Chapter 23: Native Compilation

*"From script to standalone binary."*

---

## 23.1 What Is Native Compilation?

ARO can compile applications to standalone native binaries that run without the ARO runtime installed. This transforms your application from an interpreted script into a self-contained executable that can be deployed anywhere the target platform runs.

The native compilation process translates ARO source code into LLVM IR (intermediate representation), compiles it to machine code, and links the result with a precompiled runtime library. The output is a native executable—a binary file that the operating system can run directly without any interpreter.

This capability matters for deployment scenarios. When you deploy an interpreted ARO application, you must ensure the ARO runtime is available on the target system. When you deploy a native binary, you deploy just the binary (and any required data files like openapi.yaml). This simplifies deployment, reduces dependencies, and can improve startup time.

Native binaries also provide some intellectual property protection. While not impossible to reverse engineer, native binaries obscure your application logic more than source code would. For applications where source visibility is a concern, native compilation provides a degree of protection.

---

## 23.2 The Build Command

The aro build command compiles an ARO application to a native binary. You provide the path to your application directory, and the compiler produces an executable.

The basic invocation takes just the application path. The output executable is named after your application directory. If you want a different name, use the output option to specify it explicitly.

Optimization options control how aggressively the compiler optimizes the generated code. The optimize flag enables performance optimizations that may increase compile time but produce faster code. The size flag optimizes for smaller binary size. The strip flag removes debug symbols, reducing binary size but making debugging harder.

The release flag combines optimization, size optimization, and symbol stripping for production builds. This produces the smallest and fastest binaries at the cost of debugging capability. Use release for deployment; use unoptimized builds during development when you might need to debug.

Verbose output shows what the compiler is doing at each step: discovering source files, parsing, generating LLVM IR, compiling to machine code, and linking. This visibility helps diagnose build problems and understand what the compiler does.

---

## 23.3 The Compilation Pipeline

<div style="text-align: center; margin: 2em 0;">
<svg width="500" height="180" viewBox="0 0 500 180" xmlns="http://www.w3.org/2000/svg">  <!-- Row 1 -->  <!-- Discovery -->  <rect x="10" y="20" width="70" height="45" rx="4" fill="#f3e8ff" stroke="#a855f7" stroke-width="2"/>  <text x="45" y="38" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#7c3aed">DISCOVER</text>  <text x="45" y="52" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#9333ea">.aro files</text>  <!-- Arrow -->  <line x1="80" y1="42" x2="95" y2="42" stroke="#9ca3af" stroke-width="1.5"/>  <polygon points="95,42 89,38 89,46" fill="#9ca3af"/>  <!-- Parse -->  <rect x="100" y="20" width="70" height="45" rx="4" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>  <text x="135" y="38" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#1e40af">PARSE</text>  <text x="135" y="52" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#3b82f6">→ AST</text>  <!-- Arrow -->  <line x1="170" y1="42" x2="185" y2="42" stroke="#9ca3af" stroke-width="1.5"/>  <polygon points="185,42 179,38 179,46" fill="#9ca3af"/>  <!-- Semantic -->  <rect x="190" y="20" width="70" height="45" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>  <text x="225" y="38" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#166534">ANALYZE</text>  <text x="225" y="52" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#22c55e">semantics</text>  <!-- Arrow -->  <line x1="260" y1="42" x2="275" y2="42" stroke="#9ca3af" stroke-width="1.5"/>  <polygon points="275,42 269,38 269,46" fill="#9ca3af"/>  <!-- Code Gen -->  <rect x="280" y="20" width="70" height="45" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>  <text x="315" y="38" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#92400e">GENERATE</text>  <text x="315" y="52" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#f59e0b">→ LLVM IR</text>  <!-- Arrow -->  <line x1="350" y1="42" x2="365" y2="42" stroke="#9ca3af" stroke-width="1.5"/>  <polygon points="365,42 359,38 359,46" fill="#9ca3af"/>  <!-- Compile -->  <rect x="370" y="20" width="55" height="45" rx="4" fill="#fee2e2" stroke="#ef4444" stroke-width="2"/>  <text x="397" y="38" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#991b1b">COMPILE</text>  <text x="397" y="52" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#ef4444">llc</text>  <!-- Arrow -->  <line x1="425" y1="42" x2="440" y2="42" stroke="#9ca3af" stroke-width="1.5"/>  <polygon points="440,42 434,38 434,46" fill="#9ca3af"/>  <!-- Link -->  <rect x="445" y="20" width="45" height="45" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>  <text x="467" y="38" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#ffffff">LINK</text>  <text x="467" y="52" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#9ca3af">binary</text>  <!-- Bottom: File representations -->  <text x="45" y="85" text-anchor="middle" font-family="monospace" font-size="8" fill="#6b7280">*.aro</text>  <text x="135" y="85" text-anchor="middle" font-family="monospace" font-size="8" fill="#6b7280">AST</text>  <text x="225" y="85" text-anchor="middle" font-family="monospace" font-size="8" fill="#6b7280">validated</text>  <text x="315" y="85" text-anchor="middle" font-family="monospace" font-size="8" fill="#6b7280">*.ll</text>  <text x="397" y="85" text-anchor="middle" font-family="monospace" font-size="8" fill="#6b7280">*.o</text>  <text x="467" y="85" text-anchor="middle" font-family="monospace" font-size="8" fill="#6b7280">MyApp</text>  <!-- Runtime library connection -->  <rect x="370" y="110" width="120" height="35" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="1" stroke-dasharray="4,2"/>  <text x="430" y="125" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#4338ca">ARO Runtime Library</text>  <text x="430" y="138" text-anchor="middle" font-family="monospace" font-size="8" fill="#6366f1">libaro.a</text>  <!-- Dashed line to Link -->  <line x1="430" y1="110" x2="467" y2="65" stroke="#6366f1" stroke-width="1" stroke-dasharray="3,2"/></svg>
</div>
Native compilation proceeds through a series of transformations that convert ARO source code into an executable binary.
The process begins with discovery. The compiler scans your application directory for ARO source files and auxiliary files like the OpenAPI specification. It validates that exactly one Application-Start feature set exists.
Parsing converts source text into abstract syntax trees. Each source file is parsed independently, producing AST representations of the feature sets and statements it contains. Parse errors at this stage indicate syntax problems in your source code.
Semantic analysis validates the parsed code. It checks that referenced variables are defined, that actions are used with valid prepositions, and that data flows correctly through feature sets. Semantic errors indicate logical problems that cannot be detected from syntax alone.
Code generation produces LLVM IR from the validated AST. Each ARO statement becomes one or more calls to the runtime library. The generated code follows a straightforward translation pattern that preserves the semantics of the original ARO code.
Compilation uses the LLVM toolchain to compile the generated IR into object code. Optimization happens at this stage—LLVM can apply its full range of optimizations to the generated code.
Linking combines the object code with the ARO runtime library to produce the final executable. The runtime library contains implementations of all the built-in actions, the event bus, HTTP client and server, and other infrastructure your application depends on.
---
## 23.4 Runtime Requirements
Native binaries link against the ARO runtime library, which provides implementations of actions and services. This library is included in every binary.
The OpenAPI specification file must still be present at runtime for applications that serve HTTP requests. The specification defines routing, and the runtime reads it when the HTTP server starts. Deploy the openapi.yaml file alongside your binary.
Any configuration files or data files your application reads must also be deployed. The native binary does not embed these files; it reads them at runtime just as the interpreted version would.
Plugins in the `Plugins/` directory are automatically compiled and bundled during `aro build`. Swift and C plugins are compiled to dynamic libraries; Python plugins are copied with their source files. The compiled plugins are placed in a `Plugins/` directory alongside the binary and loaded at runtime. This means plugin-based applications work identically in both interpreter and binary modes.
---
## 23.5 Binary Size and Performance
Native binaries have characteristic size and performance profiles that differ from interpreted execution.
Binary size depends on the complexity of your application and whether optimizations are enabled. Release builds with stripping produce the smallest binaries.
Startup time improves significantly with native binaries. Interpreted execution must parse source files and compile them to an internal representation before running. Native binaries skip this phase, starting execution immediately. For applications that start frequently—command-line tools, serverless functions—this improvement is meaningful.
Runtime performance for I/O-bound workloads (most ARO applications) is similar between interpreted and native execution. The bottleneck is usually I/O—network requests, database queries, file operations—not the execution of ARO statements. For compute-heavy workloads, native compilation may provide some improvement.
Memory usage is typically lower for native binaries because they do not maintain the interpreter infrastructure. This can be significant for memory-constrained environments.
---
## 23.6 Deployment
Native binaries simplify deployment because they have minimal runtime dependencies. The binary, the OpenAPI specification (if using HTTP), and any data files are all you need to deploy.
Containerization with Docker works well with native binaries. A multi-stage build can use the full ARO development image for compilation and a minimal base image for the final container. The resulting container contains only the binary and required files, producing small, efficient images.
Systemd and other service managers can run native binaries directly. Create a service unit file that specifies the binary location, working directory, user, and restart behavior. The binary behaves like any other system service.
Cloud deployment to platforms that accept binaries—EC2, GCE, bare metal—is straightforward. Upload the binary and supporting files, configure networking and security, and run the binary. Platform-specific considerations like health checks and logging integrations apply as they would to any application.
---
## 23.7 Debugging
Debugging native binaries requires different tools than debugging interpreted execution. The runtime's verbose output is not available; instead, you use traditional native debugging tools.
Compile without the strip flag to retain debug symbols. These symbols map binary locations back to source locations, enabling meaningful stack traces and debugger operation.
System debuggers like lldb on macOS and gdb on Linux can attach to your binary, set breakpoints, examine memory, and step through execution. The code you debug is the compiled machine code rather than the original ARO code, but the relationship is straightforward enough to follow.
Core dumps capture the state of a crashed binary for post-mortem analysis. Enable core dumps in your environment, and when a crash occurs, use the debugger to examine the core file and understand what happened.
Logging becomes more important when detailed runtime output is not available. Include logging statements in your ARO code to provide visibility into execution. The logged output is your primary window into what the native binary does during execution.
---
## 23.8 Output Formatting
Native binaries produce cleaner output than interpreted execution. This difference is intentional and reflects the different contexts in which each mode is used.
When running with the interpreter using `aro run`, log messages include a feature set name prefix:
```
[Application-Start] Starting server...
[Application-Start] Server ready on port 8080
[listUsers] Processing request...
```
When running a compiled binary, the same log messages appear without the prefix:
```
Starting server...
Server ready on port 8080
Processing request...
```
The interpreter's prefix identifies which feature set produced each message. This visibility aids debugging during development—when something goes wrong, you can see exactly where messages originated. The prefix becomes unnecessary noise in production, where the focus shifts from debugging to clean operation.
Response formatting remains unchanged between modes. The `[OK]` status prefix and response data appear identically in both cases, providing consistent machine-parseable output for scripts and monitoring tools.
---
## 23.9 Development Workflow
Development typically uses interpreted execution for rapid iteration. The interpreted mode has faster turnaround—you change code and immediately run the updated version without a compile step. Verbose output shows what the runtime does, aiding debugging and understanding.
Native compilation enters the workflow for testing deployment configurations and for final release builds. Testing with native binaries before deployment catches problems that might only appear in the native build, such as missing files or incorrect paths.
Continuous integration should build and test native binaries to ensure they work correctly. The CI pipeline builds the binary, runs tests against it, and produces artifacts for deployment. Catching problems in CI prevents deployment failures.
Release processes should produce native binaries with release optimizations. Tag releases in version control, build the release binary, and archive it alongside release notes and deployment documentation.
---
## 23.10 Limitations
Native compilation has limitations compared to interpreted execution.
Some runtime reflection capabilities may not be available. Features that depend on examining the structure of running code may behave differently or not work at all in native builds.
Cross-compilation is not currently supported. You build binaries for the platform where you run the compiler. Building for different target platforms requires building on those platforms or using platform emulation.
The compilation step adds time to the development cycle. For rapid iteration, this overhead makes interpreted execution preferable. Native compilation is best reserved for testing and release.
---
## 23.11 Best Practices
Use interpreted mode during development for fast iteration and detailed diagnostics. Switch to native compilation for deployment testing and release.
Test native binaries before deployment. Some problems only appear in native builds—missing files, path issues, platform differences. Running your test suite against the native binary catches these problems early.
Include native binary builds in continuous integration. Automated builds ensure that native compilation continues to work as the codebase evolves.
Use release optimizations for production deployments. The strip, optimize, and size options (or the combined release option) produce the smallest and fastest binaries.
Deploy the OpenAPI specification and other required files alongside the binary. The binary alone is not sufficient for applications that serve HTTP requests.
---
*Next: Chapter 23 — Multi-file Applications*