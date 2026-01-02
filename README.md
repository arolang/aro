<p align="center">
  <img src="./Graphics/logo.png" alt="ARO Logo" width="400">
</p>

<p align="center">
  <strong>Business Logic as Language</strong><br>
  A declarative language where code reads like documentation
</p>

<p align="center">
  <a href="https://krissimon.github.io/aro/">Website</a> ·
  <a href="https://github.com/KrisSimon/aro/wiki">Documentation</a> ·
  <a href="https://github.com/KrisSimon/ARO-Lang/releases">Language Guide (PDF)</a> ·
  <a href="https://github.com/KrisSimon/ARO-Lang/discussions">Discussions</a> ·
  <a href="https://github.com/KrisSimon/ARO-Lang/issues">Issues</a>
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

When the 51 built in actions are not enough, write custom actions in Swift or distribute them as plugins through Swift Package Manager.

### Happy Path Philosophy

Write only the success case. Errors are reported automatically in business terms. When a user cannot be retrieved, the message says exactly that.

## Quick Start

```aro
(Application-Start: Hello World) {
    <Log> the <message> for the <console> with "Hello from ARO!".
    <Return> an <OK: status> for the <startup>.
}
```

Save as `main.aro` in a directory called `HelloWorld`, then:

```bash
aro run ./HelloWorld
```

## Documentation

The complete language guide is available as a PDF in the [Releases](https://github.com/KrisSimon/ARO-Lang/releases) page. It covers:

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
brew tap krissimon/aro
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
curl -L https://github.com/KrisSimon/aro/releases/latest/download/aro-macos-arm64.tar.gz | tar xz
sudo mv aro /usr/local/bin/
```

**Linux (x86_64)**:
```bash
curl -L https://github.com/KrisSimon/aro/releases/latest/download/aro-linux-amd64.tar.gz | tar xz
sudo mv aro /usr/local/bin/
```

**Windows (x86_64)**:
Download the latest release from [GitHub Releases](https://github.com/KrisSimon/aro/releases) and add to PATH.

### Build from Source

See the [Building from Source](#building-from-source) section below for detailed instructions.

## Building from Source

ARO is written in Swift 6.2 and uses Swift Package Manager.

### macOS

Xcode 16.3 or later includes Swift 6.2.

```bash
git clone https://github.com/KrisSimon/ARO-Lang.git
cd ARO-Lang
swift build -c release
```

The binary is at `.build/release/aro`.

### Linux

Install Swift 6.2 from [swift.org](https://swift.org/download/).

```bash
git clone https://github.com/KrisSimon/ARO-Lang.git
cd ARO-Lang
swift build -c release
```

The binary is at `.build/release/aro`.

### Windows

Install Swift 6.2 from [swift.org](https://swift.org/download/). Ensure the Swift toolchain is in your PATH.

```powershell
git clone https://github.com/KrisSimon/ARO-Lang.git
cd ARO-Lang
swift build -c release
```

The binary is at `.build\release\aro.exe`.

## Running Tests

```bash
swift test
```

## Examples

The `Examples/` directory contains working applications:

| Example | Description |
|---------|-------------|
| Calculator | Test framework demonstration |
| Computations | Arithmetic and data transformations |
| Conditionals | Conditional logic and branching |
| ContextAware | Context-aware feature sets |
| CustomPlugin | Custom action plugin example |
| DataPipeline | Data pipeline processing |
| DirectoryLister | Directory listing operations |
| EchoSocket | TCP server echoing messages |
| Expressions | Expression evaluation |
| ExternalService | External service integration |
| FileOperations | File system operations |
| FileWatcher | Directory monitoring with event handlers |
| HTTPClient | HTTP client requests |
| HTTPServer | Web server with OpenAPI routing |
| HelloWorld | Minimal single file application |
| HelloWorldAPI | Simple HTTP API example |
| Iteration | Loop and iteration patterns |
| ModulesExample | Application composition with imports |
| OrderService | Order management service |
| RepositoryObserver | Repository change observers |
| Scoping | Variable scoping demonstration |
| SimpleChat | Simple chat application |
| Split | String splitting operations |
| SystemMonitor | System monitoring example |
| UserService | Multi file application with events |
| ZipService | ZIP file operations |

Run any example with:

```bash
aro run ./Examples/HTTPServer
```

## Contributing

ARO is in active development. Contributions are welcome.

- [Open an issue](https://github.com/KrisSimon/ARO-Lang/issues) for bugs or feature requests
- [Join the discussion](https://github.com/KrisSimon/ARO-Lang/discussions) for questions and ideas
- Read the [Evolution Proposals](./Proposals/) to understand the language design

### Code Reviews

You can request an AI-powered code review on any pull request by commenting:

```
@claude review
```

Claude will analyze the PR for bugs, security issues, performance problems, and code quality. It will create suggested fixes as actual code changes in a new branch and submit them as a review PR.

The review will:
- ✅ Check for bugs and logical errors
- ✅ Identify security vulnerabilities
- ✅ Suggest performance improvements
- ✅ Ensure code follows project guidelines (CLAUDE.md)
- ✅ Verify test coverage

## Troubleshooting

### macOS Gatekeeper Warning

**Official releases** (from GitHub Releases) are code-signed and notarized by Apple, so you should not see any warnings.

If you build from source or use a development build and see a security warning:

> "Apple could not verify 'aro' is free of malware that may harm your Mac or compromise your privacy."

You have several options:

**Option 1: Use Homebrew** (Recommended)
```bash
brew tap krissimon/aro
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
