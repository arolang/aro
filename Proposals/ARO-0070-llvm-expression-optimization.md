# ARO-0070: LLVM Expression Optimization

* Proposal: ARO-0070
* Author: ARO Language Team
* Status: **Partially Implemented**
* Related Issues: GitLab #100, GitLab #102

## Abstract

Optimize expression handling in the LLVM code generator to reduce compile-time overhead and improve runtime performance by eliminating JSON serialization for expressions.

## Current Status

**Implemented** (GitLab #102): Constant folding optimization
- Constant expressions are evaluated at compile time
- No runtime evaluation needed for `5 * 10 + 2` → emits `52` directly
- Handles arithmetic, comparisons, logical operations

**Remaining**: Runtime expression optimization for non-constant expressions

## Problem

For non-constant expressions (involving variables), the current implementation:

1. **Compile-time**: Serializes expressions to JSON strings
2. **Runtime**: Parses JSON and evaluates via C runtime bridge

```swift
// Current approach:
private func serializeExpression(_ expr: Expression) -> String {
    if let binary = expr as? BinaryExpression {
        return """
        {"$binary":{"op":"\(binary.op.rawValue)","left":\(serialize(binary.left)),"right":\(serialize(binary.right))}}
        """
    }
}
```

Creates many intermediate strings and requires runtime JSON parsing.

## Solutions

### Phase 1: Constant Folding (✓ Implemented)

Evaluate constant expressions at compile time:

```swift
// GitLab #102 implementation:
if ConstantFolder.isConstant(expr), let value = ConstantFolder.evaluate(expr) {
    return serializeLiteralValue(value)  // Emits 52 for 5 * 10 + 2
}
```

**Impact**: Eliminates runtime evaluation for all constant expressions.

### Phase 2: Efficient String Building (Proposed)

For non-constant expressions, use efficient string building:

```swift
private func serializeExpression(_ expr: Expression, into builder: inout ContiguousArray<UInt8>) {
    switch expr {
    case let binary as BinaryExpression:
        builder.append(contentsOf: #"{"$binary":{"op":"#.utf8)
        builder.append(contentsOf: binary.op.rawValue.utf8)
        builder.append(contentsOf: #","left":#.utf8)
        serializeExpression(binary.left, into: &builder)
        builder.append(contentsOf: #","right":#.utf8)
        serializeExpression(binary.right, into: &builder)
        builder.append(contentsOf: #"}}"#.utf8)
    }
}
```

**Benefits**:
- Reduces string allocations by ~80%
- Faster compile times
- Lower memory usage

### Phase 3: Direct LLVM IR Generation (Future)

Generate LLVM IR that directly evaluates expressions without JSON:

```swift
private func generateExpression(_ expr: Expression) -> IRValue {
    switch expr {
    case let binary as BinaryExpression:
        let left = generateExpression(binary.left)
        let right = generateExpression(binary.right)

        switch binary.op {
        case .add:
            return ctx.module.insertAdd(left, right, at: ip)
        case .subtract:
            return ctx.module.insertSub(left, right, at: ip)
        // ... other operators
        }
    }
}
```

**Benefits**:
- 10-50x faster expression evaluation
- Smaller binaries (no embedded JSON)
- Enables LLVM optimizations

**Challenges**:
- Requires type information for proper IR generation
- Need to handle mixed types (int + float)
- More complex implementation

## Implementation Priority

1. **Phase 1** (✓ Done): Constant folding - handles the common case
2. **Phase 2** (Low priority): String building - marginal improvement
3. **Phase 3** (Future): Direct IR - significant redesign

## Current Performance

With Phase 1 implemented:
- Constant expressions: **Zero runtime cost** (evaluated at compile time)
- Variable expressions: Still use JSON (acceptable for now)

## Recommendation

Phase 1 (constant folding) provides the most significant performance improvement for the least complexity. Phases 2 and 3 can be implemented later if profiling shows expression evaluation is a bottleneck.

Partially fixes GitLab #100 (via GitLab #102)
