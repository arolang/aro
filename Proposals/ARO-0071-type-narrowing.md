# ARO-0071: Type Narrowing in Conditional Branches

* Proposal: ARO-0071
* Author: ARO Language Team
* Status: **Proposed**
* Related Issues: GitLab #122

## Abstract

Add flow-sensitive type analysis to the ARO semantic analyzer, allowing the type system to narrow types based on conditional checks (`when`, `match`, `exists`).

## Motivation

Currently, the semantic analyzer treats variables as having a single type throughout their scope, even when conditional checks provide additional type information:

```aro
(Process Data: Data Handler) {
    Extract the <value> from the <input: data>.

    when <value> is String {
        (* We know value is String here, but analyzer doesn't *)
        Compute the <length> from <value: length>.
    }
}
```

## Proposed Solution

### Type Narrowing in When Blocks

When a `when` condition performs a type check, narrow the variable's type in the then-branch:

```aro
when <value> is String {
    (* value: String (narrowed) *)
    Compute the <upper: uppercase> from <value>.  ✓ Valid
} otherwise {
    (* value: unknown type *)
    Compute the <upper: uppercase> from <value>.  ⚠ Warning: may not be String
}
```

### Null Checks with Exists

The `exists` operator narrows nullability:

```aro
when <user> exists {
    (* user is non-null *)
    Log <user: name> to <console>.  ✓ Safe access
} otherwise {
    (* user is null *)
    Log "No user" to <console>.
}
```

### Match Exhaustiveness

Match expressions should check for exhaustive coverage:

```aro
match <status> {
    case 200..299: Log "Success" to <console>.
    case 400..499: Log "Client error" to <console>.
    case 500..599: Log "Server error" to <console>.
    (* All HTTP status codes covered - exhaustive *)
}

match <color> {
    case "red": Log "Red" to <console>.
    case "blue": Log "Blue" to <console>.
    (* Non-exhaustive - compiler warns *)
}
```

## Implementation Design

### Flow Context

Track type information through control flow:

```swift
public struct FlowContext {
    /// Variables with narrowed types
    private var typeNarrowing: [String: NarrowedType] = [:]

    /// Variables with known nullability
    private var nullability: [String: NullState] = [:]

    public mutating func narrow(_ variable: String, to type: Type) {
        typeNarrowing[variable] = .narrowed(from: currentType, to: type)
    }

    public mutating func markNonNull(_ variable: String) {
        nullability[variable] = .definitelyNotNull
    }

    public func getType(_ variable: String) -> Type {
        return typeNarrowing[variable]?.narrowedType ?? baseType(variable)
    }
}
```

### Condition Analysis

Extract type assertions from conditions:

```swift
private func extractAssertions(from condition: Expression) -> [TypeAssertion] {
    var assertions: [TypeAssertion] = []

    switch condition {
    case let typeCheck as TypeCheckExpression:
        // <value> is String
        assertions.append(.typeNarrowing(
            variable: typeCheck.variable,
            type: typeCheck.assertedType
        ))

    case let existence as ExistenceExpression:
        // <value> exists
        assertions.append(.nullability(
            variable: existence.variable,
            isNull: false
        ))

    case let binary as BinaryExpression where binary.op == .notEqual:
        // <value> != null
        if binary.right.isNull {
            assertions.append(.nullability(
                variable: binary.left,
                isNull: false
            ))
        }
    }

    return assertions
}
```

### When Statement Analysis

Apply narrowing in branches:

```swift
func analyzeWhenStatement(_ stmt: WhenStatement) throws {
    // Analyze condition
    let conditionType = try analyzeExpression(stmt.condition)

    // Extract type assertions from condition
    let assertions = extractAssertions(from: stmt.condition)

    // Then branch: apply narrowing
    var thenContext = currentFlowContext
    for assertion in assertions {
        thenContext.apply(assertion)
    }

    try withFlowContext(thenContext) {
        for statement in stmt.thenStatements {
            try analyzeStatement(statement)
        }
    }

    // Else branch: use original context (or inverse narrowing)
    if let elseStatements = stmt.elseStatements {
        var elseContext = currentFlowContext
        for assertion in assertions {
            elseContext.apply(assertion.inverse())
        }

        try withFlowContext(elseContext) {
            for statement in elseStatements {
                try analyzeStatement(statement)
            }
        }
    }
}
```

### Match Exhaustiveness

Check if match covers all cases:

```swift
func checkMatchExhaustiveness(_ match: MatchExpression) throws {
    let casePatterns = match.cases.map { $0.pattern }

    let coverage = analyzeCoverage(
        matchValue: match.value,
        patterns: casePatterns
    )

    if !coverage.isExhaustive {
        diagnostics.warning(
            "Non-exhaustive match - missing cases: \(coverage.missingCases)",
            at: match.span
        )
    }
}
```

## Examples

### Type Check Narrowing

```aro
when <value> is Number {
    (* value: Number *)
    Compute the <doubled> from <value> * 2.  ✓
}

when <value> is String {
    (* value: String *)
    Compute the <upper: uppercase> from <value>.  ✓
}
```

### Null Safety

```aro
when <user> exists {
    (* user: non-null *)
    Extract the <name> from <user: name>.  ✓
    Log <name> to <console>.
} otherwise {
    (* user: null *)
    Log "Anonymous user" to <console>.
}
```

### Match with Narrowing

```aro
match <vehicle: type> {
    case "car" {
        (* vehicle is known to have car properties *)
        Extract the <wheels> from <vehicle: wheels>.
    }
    case "boat" {
        (* vehicle is known to have boat properties *)
        Extract the <hull> from <vehicle: hull>.
    }
}
```

## Benefits

1. **Safer code**: Catch type errors at compile time
2. **Better error messages**: Context-aware errors
3. **IDE support**: Autocomplete knows types in branches
4. **Documentation**: Types document expected values
5. **Fewer runtime errors**: More validation upfront

## Implementation Phases

1. **Phase 1**: Basic type narrowing for `is` checks
2. **Phase 2**: Null safety with `exists`
3. **Phase 3**: Match exhaustiveness checking
4. **Phase 4**: Union type narrowing

## Compatibility

This is a purely additive feature - existing code continues to work. The analyzer simply provides additional warnings/errors in cases that were previously unchecked.

Fixes GitLab #122
