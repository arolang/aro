<p align="center">
  <img src="./Graphics/logo.png" alt="ARO Logo" width="400">
</p>

<p align="center">
  <strong>Business Logic as Language</strong><br>
  A declarative language where code reads like documentation
</p>

<p align="center">
  <a href="https://arolang.github.io/aro/">Website</a> ·
  <a href="https://github.com/arolang/aro/wiki">Documentation</a> ·
  <a href="https://github.com/arolang/aro/releases/latest/download/ARO-Language-Guide.pdf">Language Guide (PDF)</a> ·
  <a href="https://github.com/arolang/aro/releases/latest/download/ARO-Debugging-Guide.pdf">Debugging Guide (PDF)</a> ·
  <a href="https://github.com/arolang/aro/discussions">Discussions</a> ·
  <a href="https://social.uitsmijter.io/@aro">Mastodon</a>
</p>

---

## What is ARO?

ARO is a programming language designed to express business features in a form that both developers and domain experts can read. Every statement follows a consistent grammatical pattern:

```aro
<Action> the <Result> preposition the <Object>.
```

This constraint is intentional. When there is only one way to express an operation, code review becomes trivial and onboarding becomes fast. ARO code reads like a description of what happens, not instructions for how to make it happen.

```aro
(createUser: User API) {
    <Extract> the <data> from the <request: body>.
    <Validate> the <data> against the <user: schema>.
    <Create> the <user> with <data>.
    <Store> the <user> into the <user-repository>.
    <Emit> a <UserCreated: event> with <user>.
    <Return> a <Created: status> with <user>.
}
```

A compliance officer can audit this. A new developer can understand it in seconds. The code is the documentation.

## Why This Exists

Right, here's the thing. This project exists because I wanted to see what happens when you let AI loose on a domain you don't feel confident enough to tackle on your own, but you're savvy enough to spot when it's talking rubbish. Turns out, the AI won't stop you doing daft things - it'll happily help you build something bonkers if you ask it to. But the real surprise? I've ended up learning more about language design, parsers, and compiler theory than I ever expected. Never thought I'd care about lexers and ASTs, but here we are. Sometimes the best education comes from poking at something you probably shouldn't, with tools that don't know any better.

## Features

### Contract First APIs

HTTP routes are defined in an OpenAPI specification. Feature sets are named after operation identifiers. No routing configuration in code.

```yaml
# openapi.yaml
paths:
  /users:
    get:
      operationId: listUsers
```

```aro
(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}
```

### Event Driven Architecture

Feature sets respond to events rather than being called directly. Emit an event and handlers execute automatically. Add new behaviors by adding handlers without modifying existing code.

```aro
(Send Welcome Email: UserCreated Handler) {
    <Extract> the <user> from the <event: user>.
    <Send> the <welcome-email> to the <user: email>.
    <Return> an <OK: status> for the <notification>.
}
```

### Native Compilation

Compile to standalone binaries. No runtime installation required on target systems.

```bash
aro build ./MyApp              # one self-contained binary (default: --static)
aro build ./MyApp --dynamic    # binary + bundled libswift*.so / libFoundation*.so next to it
./MyApp
```

On Linux, `--static` links the Swift runtime as static archives so the binary runs without a system Swift install. `--dynamic` keeps the Swift libraries as `.so`s and embeds `rpath=$ORIGIN` so the loader picks them up from the same directory as the binary — useful when targeting Linux distributions where Foundation isn't preinstalled. See [Guide-Linux-Deployment](https://git.ausdertechnik.de/arolang/aro/-/wikis/Guide-Linux-Deployment).

### Built in Services

HTTP server and client, file system operations with directory watching, and TCP sockets are available without external dependencies.

```aro
(Application-Start: File Watcher) {
    <Watch> the <file-monitor> for the <directory> with "./data".
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

### Extensible Actions

When the 60+ built-in actions are not enough, write custom actions in Swift or distribute them as plugins through Swift Package Manager.

### User Defined Actions

Factor reusable business logic into a feature set with the activity `Action`, then call it from anywhere as `Application.<Name>` — no plugin, no event bus.

```aro
(DoubleValue: Action takes <number>) {
    <Extract> the <n> from the <input: number>.
    <Compute> the <doubled> from <n> * 2.
    <Return> an <OK: status> with { doubled: <doubled> }.
}

(Application-Start: Demo) {
    Application.DoubleValue the <result> from 21.
    <Extract> the <answer> from the <result: doubled>.
    <Log> <answer> to the <console>.
    <Return> an <OK: status> for the <startup>.
}
```

### Native Git

Version control without shelling out. `<git>` defaults to the current repository; pass an explicit path for anything else.

```aro
<Retrieve> the <status> from the <git>.
<Stage> the <files> to the <git> with ".".
<Commit> the <result> to the <git> with "feat: add feature".
<Push> the <result> to the <git>.
```

Status, log, stage, commit, pull, push, clone, checkout, and tag all run in-process via libgit2 — and emit corresponding `GitCommit` / `GitPush` / `GitPull` events you can subscribe to.

### Lazy Action Execution

Actions return future handles and run on a dedicated executor; values are forced the first time something reads them. Independent results overlap automatically while effects keep source order within a feature set — no annotations, no explicit `await`s, no async-colour to manage.

### AI Coding Assistant

`aro ask` is a local LLM coding assistant with tool calling and project-aware indexing — runs on Apple Silicon GPU via MLX on macOS, llama-server (auto-downloaded) on Linux, or any OpenAI-compatible endpoint via `$ARO_LM_ENDPOINT`.

```bash
aro ask                       # interactive
aro ask "fix the broken test in Examples/Calculator"
aro ask "explain ARO scoping" # one-shot prompt
```

### Editor & Agent Integration

`aro lsp` ships a Language Server that loads plugins from `<workspace>/Plugins/` on `initialized` and surfaces plugin actions and qualifiers in completion, hover, and diagnostics. `aro mcp` ships the same project as an MCP server — `aro_actions` and `aro_qualifiers` accept a `directory:` argument so AI agents see workspace-local plugins too.

### Piped Source

```bash
echo '<Log> "Hi from a pipe" to the <console>.' | aro
```

### Plugin Qualifiers

Extend the language with custom value transformations. Plugins can register qualifiers that work on Lists, Strings, and other types.

```aro
Compute the <random-item: pick-random> from the <items>.
Compute the <sorted: sort> from the <numbers>.
Log <list: reverse> to the <console>.
```

Write plugins in Swift, Rust, C, or Python. Qualifiers work in both interpreter and compiled binary modes.

Plugin actions and qualifiers are also visible to editor tooling — the LSP loads plugins from `<workspace>/Plugins/` on `initialized`, and the MCP server's `aro_actions` / `aro_qualifiers` tools accept a `directory:` argument to surface workspace-specific plugins.

### Happy Path Philosophy

Write only the success case. Errors are reported automatically in business terms. When a user cannot be retrieved, the message says exactly that.

## Platform Support

ARO runs on macOS, Linux, and Windows. Most features work across all platforms.

| Feature | macOS | Linux | Windows |
|---------|:-----:|:-----:|:-------:|
| **Core Runtime** |
| Interpreter (`aro run`) | ✅ | ✅ | ✅ |
| Syntax checking (`aro check`) | ✅ | ✅ | ✅ |
| Native compilation (`aro build`) | ✅ | ✅ | ❌⁴ |
| AI coding assistant (`aro ask`) | ✅⁷ | ✅⁶ | ✅⁶ |
| MCP server (`aro mcp`) | ✅ | ✅ | ✅ |
| Native Git actions (libgit2) | ✅ | ✅ | ✅ |
| **Networking** |
| HTTP Server | ✅ | ✅ | ✅¹ |
| HTTP Client | ✅ | ✅ | ✅ |
| Socket Server | ✅ | ✅ | ✅¹ |
| Socket Client | ✅ | ✅ | ✅¹ |
| **File System** |
| File Operations | ✅ | ✅ | ✅ |
| File Monitoring | ✅ | ✅ | ✅² |
| Large File Streaming | ✅ | ✅ | ❌⁵ |
| **Data Processing** |
| HTML Parsing | ✅ | ✅ | ✅ |
| JSON/YAML Processing | ✅ | ✅ | ✅ |
| **Developer Tools** |
| Language Server (LSP) | ✅ | ✅ | ❌³ |
| Swift Plugins | ✅ | ✅ | ✅ |

¹ Uses FlyingFox with polling-based networking (no SwiftNIO)
² Uses polling-based monitoring instead of native events
³ LanguageServerProtocol library doesn't support Windows yet
⁴ LLVM not available in Windows CI environment
⁵ `URL.lines` not available on Windows; use `Read` + `Split` instead
⁶ Requires `llama-server`, `mlx_lm.server`, or `$ARO_LM_ENDPOINT` to be reachable
⁷ macOS Apple Silicon runs the model natively via MLX (no Python, no subprocess)

## Quick Start

```aro
(Application-Start: Hello World) {
    <Log> "Hello from ARO!" to the <console>.
    <Return> an <OK: status> for the <startup>.
}
```

Save as `main.aro` in a directory called `HelloWorld`, then:

```bash
aro run ./HelloWorld
```

## Documentation

The complete language guide is available as a PDF in the [Releases](https://github.com/arolang/aro/releases) page, or download the [latest version directly](https://github.com/arolang/aro/releases/latest/download/ARO-Language-Guide.pdf). It covers:

- The ARO mental model and philosophy
- Statement anatomy and feature sets
- Data flow and the event bus
- OpenAPI integration
- Built in services (HTTP, files, sockets)
- Custom actions and plugins
- Native compilation
- Patterns and practices

The **[ARO Debugging Guide](https://github.com/arolang/aro/releases/latest/download/ARO-Debugging-Guide.pdf)** is a separate, chapter-by-chapter walkthrough of `aro debug` — installation, the statement-boundary model, the five breakpoint flavors, watches, DAP integration with VS Code / IntelliJ / Neovim, recording and replay, and production attach. Source lives under [`Book/TheDebuggingGuide/`](./Book/TheDebuggingGuide).

For a detailed look at the implementation, see [OVERVIEW.md](./OVERVIEW.md).

## Installation

### macOS (Homebrew)

The easiest way to install ARO on macOS:

```bash
brew tap arolang/aro
brew install aro
```

Verify installation:

```bash
aro --version
```

### Binary Releases

Pre-built binaries are available for all platforms:

**macOS (ARM64)**:
```bash
curl -L https://github.com/arolang/aro/releases/latest/download/aro-macos-arm64.tar.gz | tar xz
sudo mv aro /usr/local/bin/
sudo mv libARORuntime.a /usr/local/lib/
```

**Linux (x86_64)**:
```bash
curl -L https://github.com/arolang/aro/releases/latest/download/aro-linux-amd64.tar.gz | tar xz
sudo mv aro /usr/local/bin/
sudo mv libARORuntime.a /usr/local/lib/
```

**Windows (x86_64)**:
Download the latest release from [GitHub Releases](https://github.com/arolang/aro/releases) and add to PATH.
Keep `aro.exe` and `libARORuntime.a` in the same directory.

### Build from Source

See the [Building from Source](#building-from-source) section below for detailed instructions.

## Building from Source

ARO is written in Swift 6.2 and uses Swift Package Manager.

### Dependencies

Building ARO from source requires:

| Dependency | Version | Required For |
|------------|---------|--------------|
| Swift | 6.2+ | Core compiler and runtime |
| LLVM | 20 | Native compilation (`aro build`) |
| Clang | 20 | Linking compiled binaries |

**Note:** LLVM and Clang are only required for the `aro build` command (native compilation). The interpreter (`aro run`) works without them.

### macOS

Xcode 16.3 or later includes Swift 6.2. Install LLVM 20 via Homebrew:

```bash
brew install llvm@20
```

Then build:

```bash
git clone https://github.com/arolang/aro.git
cd aro
swift build -c release
```

The binary is at `.build/release/aro`.

If LLVM is installed in a non-standard location, set the `LLVM_PATH` environment variable:

```bash
export LLVM_PATH=/opt/homebrew/opt/llvm@20  # Apple Silicon default
export LLVM_PATH=/usr/local/opt/llvm@20     # Intel Mac default
```

### Linux

Install Swift 6.2 from [swift.org](https://swift.org/download/). Install LLVM 20:

```bash
# Ubuntu/Debian
wget https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 20
sudo apt-get install -y llvm-20-dev clang-20
```

Then build:

```bash
git clone https://github.com/arolang/aro.git
cd aro
swift build -c release
```

The binary is at `.build/release/aro`.

### Windows

Install Swift 6.2 from [swift.org](https://swift.org/download/). Ensure the Swift toolchain is in your PATH.

```powershell
git clone https://github.com/arolang/aro.git
cd aro
swift build -c release
```

The binary is at `.build\release\aro.exe`.

**Note:** Native compilation (`aro build`) is not yet supported on Windows. Use `aro run` for interpreter mode. Windows networking uses FlyingFox (polling-based, no SwiftNIO dependency).

## Running Tests

### Unit Tests

Run Swift unit tests for the parser, runtime, and compiler:

```bash
swift test
```

### Integration Tests

Run integration tests for all examples (two-phase: interpreter + native binary):

```bash
# Run all examples
./Tests/IntegrationTestsRunner/run-tests.pl

# Run specific examples
./Tests/IntegrationTestsRunner/run-tests.pl HelloWorld Calculator HTTPServer

# Verbose output
./Tests/IntegrationTestsRunner/run-tests.pl --verbose

# Filter by pattern
./Tests/IntegrationTestsRunner/run-tests.pl --filter=HTTP

# Parallel execution (socket-port tests still serialise after the pool)
./Tests/IntegrationTestsRunner/run-tests.pl -j 4
```

The integration test framework is modular and located in `Tests/IntegrationTestsRunner/`:
- 18 modules under `lib/AROTest/` organized by responsibility
- Each example runs in both interpreter (`aro run`) and compiled (`aro build`) mode
- Automatic type detection (console, HTTP, socket, file, multi-context)
- Pattern matching with placeholders (`__TIMESTAMP__`, `__UUID__`, ...)
- Fork-based worker pool with flake-retry for parallel runs

## Examples

The `Examples/` directory contains 65+ working applications demonstrating various ARO features:

| Category | Examples |
|----------|----------|
| **Getting Started** | HelloWorld, HelloWorldAPI, Calculator |
| **Data & Computation** | Computations, Expressions, TypeConversion, HashTest |
| **Control Flow** | Conditionals, Iteration, Scoping, ErrorHandling |
| **Collections** | ListTest, SortExample, Split, CollectionMerge, SetOperations, DataPipeline |
| **HTTP & APIs** | HTTPServer, HTTPClient, ExternalService, UserService, OrderService |
| **Events & Observers** | EventExample, EventListener, NotifyExample, RepositoryObserver |
| **File System** | FileOperations, FileWatcher, FileChecks, FileMetadata, DirectoryLister, DirectoryReplicator, DirectoryReplicatorEvents, FormatAwareIO |
| **Networking** | EchoSocket, SocketClient, SimpleChat |
| **Date & Time** | DateTimeDemo, DateRangeDemo |
| **Advanced** | CustomPlugin, ModulesExample, ContextAware, ConfigurableTimeout, SinkSyntax, AssertDemo, ParallelForEach, UserDefinedActions |
| **Version Control** | GitDemo (status, log, stage, commit, push, pull, clone, checkout, tag) |
| **Plugin Qualifiers** | QualifierPlugin (Swift), QualifierPluginC (C), QualifierPluginPython (Python) |
| **Full Applications** | SystemMonitor, ZipService, SQLiteExample, ReceiveData |

Run any example with:

```bash
aro run ./Examples/HTTPServer
```

## Contributing

ARO is in active development. Contributions are welcome.

- [Open an issue](https://github.com/arolang/aro/issues) for bugs or feature requests
- [Join the discussion](https://github.com/arolang/aro/discussions) for questions and ideas
- [Follow on Mastodon](https://social.uitsmijter.io/@aro) for daily language tips and updates
- Read the [Evolution Proposals](./Proposals/) to understand the language design

AI-assisted coding, code reviews, and contributions are highly appreciated.

## Troubleshooting

### macOS Gatekeeper Warning

**Official releases** (from GitHub Releases) are code-signed and notarized by Apple, so you should not see any warnings.

If you build from source or use a development build and see a security warning:

> "Apple could not verify 'aro' is free of malware that may harm your Mac or compromise your privacy."

You have several options:

**Option 1: Use Homebrew** (Recommended)
```bash
brew tap arolang/aro
brew install aro
```
Homebrew automatically handles security attributes.

**Option 2: Remove quarantine attribute**
```bash
xattr -d com.apple.quarantine /usr/local/bin/aro
```

**Option 3: Right-click method**
1. Right-click the `aro` binary in Finder
2. Select "Open"
3. Click "Open" in the security dialog

## License

MIT License

---

<p align="center">
  <em>ARO: Making business features executable</em>
</p>

