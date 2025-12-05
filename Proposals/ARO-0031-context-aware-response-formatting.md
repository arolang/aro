# ARO-0031: Context-Aware Response Formatting

* Proposal: ARO-0031
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0020

## Abstract

This proposal introduces context-aware response formatting to ARO. The same Return action produces different output based on execution context: structured data for machine consumers (APIs, events), readable text for humans (CLI, console), and detailed diagnostics for developers (tests, debug mode).

## Motivation

ARO code should work consistently across all contexts without requiring explicit formatting logic:

1. **API Responses**: Machine consumers expect JSON/structured data
2. **Console Output**: Humans reading logs want clear, formatted text
3. **Test Assertions**: Developers need detailed diagnostic information
4. **Event Payloads**: Event handlers require typed data structures

## Design Principles

1. **Write Once**: Same ARO code works everywhere
2. **Context Detection**: Runtime automatically detects execution context
3. **Appropriate Formatting**: Each context gets optimal representation
4. **No Source Changes**: Existing code benefits without modification

## Execution Contexts

### Machine Context

Triggered by API calls and event handlers. Output is JSON-serializable structured data.

### Human Context

Triggered by CLI execution and console output. Output is formatted text for readability.

### Developer Context

Triggered by testing and debug modes. Output includes detailed diagnostic information.

## Context Detection

| Entry Point | Detected Context |
|-------------|------------------|
| HTTP route handler | Machine |
| Event dispatch target | Machine |
| `aro run` (interactive) | Human |
| `aro test` | Developer |
| `--debug` flag | Developer |

## Implementation

### OutputContext Enum

```swift
public enum OutputContext: String, Sendable, Equatable, CaseIterable {
    case machine    // API, events - JSON output
    case human      // CLI, console - formatted text
    case developer  // Tests, debug - diagnostic output
}
```

### ResponseFormatter

Formats responses differently based on context:
- `formatForMachine()` - JSON
- `formatForHuman()` - readable text
- `formatForDeveloper()` - diagnostic with types

## Compatibility

This proposal:
- Does not change ARO syntax
- Does not break existing code
- Enhances existing Return and Log actions
- Requires no migration

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12 | Initial specification and implementation |
