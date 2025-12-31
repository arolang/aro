# ARO-0034: Language Server Protocol Implementation

* Proposal: ARO-0034
* Author: ARO Language Team
* Status: **Proposed**
* Requires: ARO-0030

## Abstract

This proposal defines the implementation of a Language Server Protocol (LSP) server for ARO, enabling advanced IDE features like real-time diagnostics, code navigation, and intelligent completions in Visual Studio Code and IntelliJ-based IDEs.

## Motivation

While ARO-0030 established basic IDE integration with syntax highlighting and snippets, developers need deeper integration for productivity:

1. **Real-time Error Detection** - See syntax and semantic errors as you type
2. **Code Navigation** - Jump to symbol definitions, find all references
3. **Intelligent Completions** - Context-aware suggestions for actions, variables, and types
4. **Hover Information** - Type information and documentation on hover
5. **Document Outline** - Navigate feature sets and statements

The Language Server Protocol provides a standardized way to implement these features once and support all LSP-compatible editors.

---

## Architecture

### AROLSP Module

A new Swift module `AROLSP` provides the language server implementation:

```
Sources/AROLSP/
├── AROLanguageServer.swift      # Main server, capability negotiation
├── DocumentManager.swift        # Track open documents, trigger recompilation
├── PositionConverter.swift      # SourceLocation <-> LSP Position conversion
├── Handlers/
│   ├── DiagnosticsHandler.swift # Publish diagnostics on document change
│   ├── HoverHandler.swift       # Show symbol info on hover
│   ├── DefinitionHandler.swift  # Go to symbol definition
│   ├── CompletionHandler.swift  # Smart completions
│   ├── ReferencesHandler.swift  # Find all references
│   └── DocumentSymbolHandler.swift # Outline view
└── Transport/
    └── StdioTransport.swift     # JSON-RPC over stdio
```

### CLI Integration

The LSP server is started via the `aro` CLI:

```bash
aro lsp              # Start LSP server (stdio mode)
aro lsp --debug      # Enable debug logging
```

### Leveraging Existing Infrastructure

The LSP server reuses existing AROParser components:

| Component | Usage |
|-----------|-------|
| `Compiler.compile()` | Parse and analyze documents |
| `Diagnostic` | Convert to LSP diagnostics |
| `SymbolTable` | Symbol lookup for hover/definition |
| `SourceSpan` | Position information (all AST nodes) |
| `ASTVisitor` | Walking AST for references |

---

## LSP Capabilities

### Priority 0: MVP Features

#### Diagnostics (textDocument/publishDiagnostics)

Real-time error and warning reporting:

```swift
// ARO Diagnostic → LSP Diagnostic
func convert(_ diagnostic: Diagnostic) -> LSPDiagnostic {
    LSPDiagnostic(
        range: toLSPRange(diagnostic.location),
        severity: mapSeverity(diagnostic.severity),
        source: "aro",
        message: diagnostic.message
    )
}
```

#### Hover (textDocument/hover)

Display information about symbols under cursor:

- **Variables**: Name, type, source (extracted/computed/published)
- **Actions**: Verb, semantic role (REQUEST/OWN/RESPONSE)
- **Feature Sets**: Name, business activity, statement count

#### Go to Definition (textDocument/definition)

Navigate to where a symbol is defined:

1. Find token/node at cursor position
2. Look up symbol in `SymbolTable`
3. Return `symbol.definedAt` location

### Priority 1: Enhanced Features

#### Completion (textDocument/completion)

Context-aware suggestions triggered by `<`, `:`, `.`:

| Trigger | Suggestions |
|---------|-------------|
| `<` | Actions (Extract, Create, Return...) and variables |
| `:` | Qualifiers and types |
| `.` | Member properties |

#### References (textDocument/references)

Find all usages of a symbol by walking the AST and collecting matching `VariableRefExpression` nodes.

#### Document Symbols (textDocument/documentSymbol)

Provide outline view:

- `FeatureSet` → Function symbol
- `AROStatement` → Method symbol (children)

### Priority 2: Advanced Features

| Feature | Description |
|---------|-------------|
| `workspace/symbol` | Search symbols across workspace |
| `textDocument/formatting` | Format ARO code |
| `textDocument/rename` | Rename symbols across files |

---

## Position Conversion

LSP uses 0-based line/column; ARO uses 1-based:

```swift
struct PositionConverter {
    static func toLSP(_ location: SourceLocation) -> Position {
        Position(line: location.line - 1, character: location.column - 1)
    }

    static func fromLSP(_ position: Position) -> SourceLocation {
        SourceLocation(line: position.line + 1, column: position.character + 1, offset: 0)
    }
}
```

---

## IDE Integration

### Visual Studio Code

Update `Editor/vscode-aro/`:

1. Add dependency: `vscode-languageclient`
2. Update `extension.ts` to spawn `aro lsp` and connect

```typescript
const serverOptions: ServerOptions = {
    command: 'aro',
    args: ['lsp']
};

const client = new LanguageClient('aro', 'ARO', serverOptions, clientOptions);
client.start();
```

### IntelliJ

Update `Editor/intellij-aro/`:

1. Add LSP descriptor using JetBrains native LSP API (2024.2+)
2. Register in `plugin.xml`

```java
public class AROLspServerDescriptor extends ProjectWideLspServerDescriptor {
    @Override
    public List<String> createCommandLine() {
        return Arrays.asList("aro", "lsp");
    }
}
```

---

## Dependencies

| Dependency | Purpose |
|------------|---------|
| [ChimeHQ/LanguageServerProtocol](https://github.com/ChimeHQ/LanguageServerProtocol) | Swift LSP types and JSON-RPC |
| [vscode-languageclient](https://www.npmjs.com/package/vscode-languageclient) | VSCode LSP client |
| JetBrains LSP API | IntelliJ native LSP support |

---

## Related Proposals

- **ARO-0030**: IDE and Editor Integration (syntax highlighting, snippets)
- **ARO-0001**: Core Syntax (grammar definition)

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial proposal |
