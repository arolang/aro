# ARO-0063: Value Type AST Nodes

* Proposal: ARO-0063
* Author: ARO Language Team
* Status: **Already Implemented**
* Related Issues: GitLab #121

## Abstract

AST nodes use value types (structs) for performance benefits including reduced heap allocations, better cache locality, and elimination of reference counting overhead.

## Current Implementation

All AST nodes in ARO are already implemented as value types:

### Statement Types (Structs)
- `AROStatement`
- `PublishStatement`
- `RequireStatement`
- `MatchStatement`
- `ForEachLoop`

### Expression Types (Structs)
- `LiteralExpression`
- `ArrayLiteralExpression`
- `MapLiteralExpression`
- `VariableRefExpression`
- `BinaryExpression`
- `UnaryExpression`
- `MemberAccessExpression`
- `SubscriptExpression`
- `GroupedExpression`
- `ExistenceExpression`
- `TypeCheckExpression`
- `InterpolatedStringExpression`

### Other AST Types (Structs)
- `Program`
- `FeatureSet`
- `ImportDeclaration`
- `StatementGuard`
- `QualifiedNoun`
- `Action`
- `ObjectClause`

## Benefits Achieved

### 1. Performance
- **No heap allocations** for simple nodes
- **No reference counting** overhead
- **Better cache locality** during AST traversal
- **Copy-on-write semantics** for efficient copying

### 2. Safety
- **No reference cycles** possible
- **Simpler memory model**
- **Sendable conformance** for Swift 6.2 concurrency

### 3. Semantics
- **Value semantics** match the immutable nature of AST
- **Automatic copying** prevents accidental mutation
- **Thread-safe by design**

## Implementation Details

### Handling Recursive Types

For recursive structures like expressions, Swift allows `any Expression` without indirection:

```swift
public struct BinaryExpression: Expression {
    public let left: any Expression       // Existential, no indirection needed
    public let operator: BinaryOperator
    public let right: any Expression
    public let span: SourceSpan
}
```

The existential type (`any Expression`) provides the necessary indirection internally.

### Sendable Conformance

All AST nodes conform to `Sendable` for safe concurrent access:

```swift
public struct AROStatement: Statement {  // Statement: ASTNode: Sendable
    public let action: Action
    public let result: QualifiedNoun
    public let object: ObjectClause
    // All fields are Sendable value types
}
```

## Verification

All AST node types verified as structs:
```bash
$ grep "public struct.*Statement\|public struct.*Expression" AST.swift | wc -l
18
$ grep "public class.*Statement\|public class.*Expression" AST.swift | wc -l
0
```

## Conclusion

The ARO parser already uses value types throughout the AST, providing excellent performance characteristics and thread safety. No changes needed.

Fixes GitLab #121
