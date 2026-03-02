# ARO-0062: Dead Code Detection

* Proposal: ARO-0062
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #103

## Abstract

Add dead code detection to the semantic analyzer to warn about unreachable statements after terminal actions like `Return` and `Throw`.

## Problem

The semantic analyzer does not detect unreachable code. Statements after a `Return` or `Throw` action are silently ignored at runtime, which can hide bugs:

```aro
(Get User: User API) {
    Return an <OK: status> with <user>.
    Log "This will never execute" to <console>.  (* Silent bug! *)
    Compute the <orphan> from <data>.             (* Also dead *)
}
```

No warning or error is produced.

## Solution

### Terminal Statements

Track "terminal" statements that end execution:
- `Return` action (unconditional)
- `Throw` action (unconditional)
- `Return` with `when` guard (conditional - NOT terminal)
- `Throw` with `when` guard (conditional - NOT terminal)

### Detection Algorithm

```swift
func analyzeStatements(_ statements: [Statement]) -> [Warning] {
    var warnings: [Warning] = []
    var terminated = false

    for (index, stmt) in statements.enumerated() {
        // Check if current statement is unreachable
        if terminated {
            warnings.append(.deadCode(stmt.span,
                message: "Unreachable code after terminal statement"))
        }

        // Check if current statement is terminal
        if isTerminal(stmt) {
            terminated = true
        }
    }

    return warnings
}

func isTerminal(_ stmt: Statement) -> Bool {
    guard let aroStmt = stmt as? AROStatement else {
        return false
    }

    // Only terminal if NO when guard
    guard aroStmt.statementGuard == .none else {
        return false
    }

    return aroStmt.action.verb.lowercased() == "return" ||
           aroStmt.action.verb.lowercased() == "throw"
}
```

### Warning Format

```
warning: unreachable code after Return statement
   --> main.aro:5:5
    |
4   |     Return an <OK: status> with <user>.
5   |     Log "This will never execute" to <console>.
    |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ unreachable
```

## Edge Cases

### When Guards
Conditional statements are NOT terminal:

```aro
(Process: Validation) {
    Return an <OK: status> when <validated>.
    Log "Still reachable if validation fails" to <console>.
}
```

### Match Statements
Only terminal if ALL branches return (not implemented in this proposal):

```aro
match <value> {
    case "a": Return an <OK: status>.
    case "b": Log "continue" to <console>.
}
Log "This IS reachable" to <console>.
```

### For-Each Loops
Loop bodies with returns are NOT terminal for statements after the loop:

```aro
for each <item> in <items> {
    Return an <OK: status> when <item> == "stop".
}
Log "Reachable after loop" to <console>.
```

## Examples

### Simple Dead Code

```aro
(Test: Dead Code) {
    Return an <OK: status> for the <result>.
    Log "unreachable" to <console>.  (* warning: unreachable code *)
}
```

### Valid Code with When Guard

```aro
(Test: Conditional) {
    Return an <Error: status> when <invalid>.
    Log "reachable" to <console>.  (* no warning *)
}
```

Fixes GitLab #103
