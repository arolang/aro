# ARO-0030: IDE and Editor Integration

* Proposal: ARO-0030
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001

## Abstract

This proposal defines the IDE and editor integration strategy for ARO, including syntax highlighting, autocomplete, and Language Server Protocol (LSP) support for Visual Studio Code and IntelliJ-based IDEs.

## Motivation

A programming language is only as usable as its tooling. Developers expect:

1. **Syntax Highlighting** - Visual distinction of keywords, actions, results, objects
2. **Autocomplete** - Intelligent suggestions for actions, prepositions, and variables
3. **Error Highlighting** - Real-time syntax error detection
4. **Go to Definition** - Navigate between feature sets
5. **Hover Information** - Documentation on hover

ARO's unique syntax with angle brackets (`<Action>`, `<Result>`, `<Object>`) and parenthetical feature sets requires custom language support.

---

## Scope

### Supported Editors

| Editor | Extension Type | Status |
|--------|---------------|--------|
| Visual Studio Code | VS Code Extension | Implemented |
| IntelliJ IDEA | JetBrains Plugin | Implemented |
| Other JetBrains IDEs | Same Plugin | Implemented |

### Feature Matrix

| Feature | VSCode | IntelliJ |
|---------|--------|----------|
| Syntax Highlighting | Yes | Yes |
| Bracket Matching | Yes | Yes |
| Comment Toggling | Yes | Yes |
| Code Folding | Yes | Yes |
| Autocomplete (basic) | Yes | Yes |
| Snippets | Yes | Yes |
| LSP Support | Future | Future |

---

## Syntax Highlighting

### Token Categories

ARO syntax is highlighted using these semantic categories:

| Category | Example | Color Suggestion |
|----------|---------|------------------|
| Comment | `(* comment *)` | Gray/Italic |
| Feature Set Name | `(Application-Start: ...)` | Blue/Bold |
| Business Activity | `(... : User API)` | Purple |
| Action | `<Extract>`, `<Return>` | Orange/Bold |
| Result | `<user>`, `<status>` | Green |
| Object | `<request>`, `<repository>` | Cyan |
| Preposition | `from`, `to`, `with`, `for` | Yellow |
| Article | `the`, `a`, `an` | Gray |
| Literal String | `"Hello"` | Brown/Red |
| Literal Number | `42`, `3.14` | Magenta |
| Keyword | `match`, `when`, `for` | Purple |

### TextMate Grammar

Both VSCode and IntelliJ support TextMate grammars. The ARO grammar uses these scopes:

```
comment.block.aro
entity.name.function.featureset.aro
entity.name.type.business-activity.aro
keyword.control.action.aro
variable.other.result.aro
variable.other.object.aro
keyword.other.preposition.aro
keyword.other.article.aro
string.quoted.double.aro
constant.numeric.aro
keyword.control.aro
```

---

## Autocomplete

### Action Suggestions

When typing `<`, suggest all valid actions:

**REQUEST Actions:**
- Extract, Parse, Retrieve, Fetch, Accept

**OWN Actions:**
- Create, Compute, Validate, Compare, Transform, Set, Merge

**RESPONSE Actions:**
- Return, Throw, Send, Log, Store, Write, Emit

**TEST Actions:**
- Given, When, Then, Assert

### Preposition Suggestions

After an action and result, suggest valid prepositions:
- `from` - For extraction/retrieval
- `to` - For destination
- `with` - For data/values
- `for` - For purpose/target
- `into` - For storage
- `on` - For location/event

### Snippet Templates

```
Feature Set:
(${1:feature-name}: ${2:Business Activity}) {
    $0
}

ARO Statement:
<${1:Action}> the <${2:result}> ${3|from,to,with,for|} the <${4:object}>.

Test:
(${1:test-name}: ${2:Component} Test) {
    <Given> the <${3:setup}> with ${4:value}.
    <When> the <${5:result}> from the <${6:action}>.
    <Then> the <${7:result}> with ${8:expected}.
}
```

---

## Installation

### Visual Studio Code

```bash
# From VS Code Marketplace
code --install-extension krissimon.aro-language

# Or search "ARO Language" in Extensions panel
```

### IntelliJ IDEA

```
1. Open Settings > Plugins
2. Search for "ARO Language"
3. Click Install
4. Restart IDE
```

---

## Language Server Protocol (Future)

A future ARO Language Server will provide:

1. **Real-time Diagnostics** - Syntax and semantic errors
2. **Go to Definition** - Jump to feature set definitions
3. **Find References** - Find all usages of a feature set
4. **Rename Symbol** - Rename feature sets across files
5. **Code Actions** - Quick fixes for common issues
6. **Workspace Symbols** - Search all feature sets

The LSP server will be implemented in Swift and distributed as part of the `aro` CLI:

```bash
aro lsp  # Start language server
```

---

## File Association

| Pattern | Language ID |
|---------|------------|
| `*.aro` | `aro` |
| `*.arospec` | `aro` (future) |

---

## Related Proposals

- **ARO-0001**: Core Syntax (defines the grammar)
- **ARO-0015**: Testing Framework (test syntax highlighting)
- **ARO-0027**: OpenAPI Integration (schema references)

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial implementation |
