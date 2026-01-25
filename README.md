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
aro build ./MyApp
./MyApp
```

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

When the 48 built in actions are not enough, write custom actions in Swift or distribute them as plugins through Swift Package Manager.

### Happy Path Philosophy

Write only the success case. Errors are reported automatically in business terms. When a user cannot be retrieved, the message says exactly that.

## Platform Support

ARO runs on macOS, Linux, and Windows. Most features work across all platforms.

| Feature | macOS | Linux | Windows |
|---------|:-----:|:-----:|:-------:|
| **Core Runtime** |
| Interpreter (`aro run`) | ✅ | ✅ | ✅ |
| Syntax checking (`aro check`) | ✅ | ✅ | ✅ |
| Native compilation (`aro build`) | ✅ | ✅ | ✅ |
| **Networking** |
| HTTP Server | ✅ | ✅ | ✅¹ |
| HTTP Client | ✅ | ✅ | ✅ |
| Socket Server | ✅ | ✅ | ✅¹ |
| Socket Client | ✅ | ✅ | ✅¹ |
| **File System** |
| File Operations | ✅ | ✅ | ✅ |
| File Monitoring | ✅ | ✅ | ✅² |
| **Data Processing** |
| HTML Parsing | ✅ | ✅ | ✅ |
| JSON/YAML Processing | ✅ | ✅ | ✅ |
| **Developer Tools** |
| Language Server (LSP) | ✅ | ✅ | ❌³ |
| Swift Plugins | ✅ | ✅ | ✅ |

¹ Uses Joannis's SwiftNIO fork with WSAPoll support (experimental)
² Uses polling-based monitoring instead of native events
³ LanguageServerProtocol library doesn't support Windows yet

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
```

**Linux (x86_64)**:
```bash
curl -L https://github.com/arolang/aro/releases/latest/download/aro-linux-amd64.tar.gz | tar xz
sudo mv aro /usr/local/bin/
```

**Windows (x86_64)**:
Download the latest release from [GitHub Releases](https://github.com/arolang/aro/releases) and add to PATH.

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

Install Swift 6.2 from [swift.org](https://swift.org/download/) and LLVM 20 from [releases.llvm.org](https://releases.llvm.org/). Ensure both are in your PATH.

```powershell
git clone https://github.com/arolang/aro.git
cd aro
swift build -c release
```

The binary is at `.build\release\aro.exe`.

**Note:** Windows support uses Joannis's SwiftNIO fork with experimental WSAPoll support for networking.

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
./test-examples.pl

# Run specific examples
./test-examples.pl HelloWorld Calculator HTTPServer

# Verbose output
./test-examples.pl --verbose

# Filter by pattern
./test-examples.pl --filter=HTTP
```

The integration test framework is modular and located in `Tests/AROIntegrationTests/`:
- 17 modules organized by responsibility
- Two-phase testing (run + build)
- Automatic type detection (console, HTTP, socket, file)
- Pattern matching with placeholders
- 109 unit tests validating framework behavior

See `Tests/AROIntegrationTests/README.md` for complete documentation.

## Examples

The `Examples/` directory contains 50+ working applications demonstrating various ARO features:

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
| **Advanced** | CustomPlugin, ModulesExample, ContextAware, ConfigurableTimeout, SinkSyntax, AssertDemo, ParallelForEach |
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

