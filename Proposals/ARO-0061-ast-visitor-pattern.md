# ARO-0061: AST Visitor Pattern

* Proposal: ARO-0061
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #114

## Abstract

Add a visitor pattern for AST traversal to eliminate scattered switch/case logic and provide extensible, type-safe traversal for code analysis, generation, and transformation.

## Problem

Code that traverses the AST (semantic analyzer, code generator, formatters) must implement manual switch/case logic for each node type. When new AST nodes are added, all these locations must be updated:

```swift
// In SemanticAnalyzer.swift
func analyze(_ statement: Statement) {
    switch statement {
    case let aroStmt as AROStatement:
        analyzeAROStatement(aroStmt)
    case let matchStmt as MatchStatement:
        analyzeMatchStatement(matchStmt)
    // ...every traversal point needs updating
    }
}
```

## Solution

Implement the visitor pattern with two protocols:

### ASTVisitor Protocol

```swift
public protocol ASTVisitor {
    associatedtype Result

    // Statements
    func visit(_ node: AROStatement) throws -> Result
    func visit(_ node: MatchStatement) throws -> Result
    func visit(_ node: ForEachLoop) throws -> Result
    func visit(_ node: PublishStatement) throws -> Result
    func visit(_ node: RequireStatement) throws -> Result
    func visit(_ node: WhenGuard) throws -> Result

    // Expressions
    func visit(_ node: BinaryExpression) throws -> Result
    func visit(_ node: UnaryExpression) throws -> Result
    func visit(_ node: LiteralExpression) throws -> Result
    func visit(_ node: VariableRefExpression) throws -> Result
    func visit(_ node: ArrayExpression) throws -> Result
    func visit(_ node: ObjectExpression) throws -> Result
}
```

### ASTNode Protocol

```swift
public protocol ASTNode: Sendable {
    func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result
}
```

### Accept Implementation

Each AST node implements `accept`:

```swift
extension AROStatement: ASTNode {
    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}

extension BinaryExpression: ASTNode {
    public func accept<V: ASTVisitor>(_ visitor: V) throws -> V.Result {
        try visitor.visit(self)
    }
}
```

## Benefits

1. **Single point of change**: New node types require one `visit` method
2. **Compiler-enforced**: Protocol requires handling all node types
3. **Reusable traversal**: Different visitors for different purposes
4. **Cleaner code**: No scattered switch/case statements

## Example Usage

### Metrics Visitor

```swift
struct MetricsVisitor: ASTVisitor {
    typealias Result = Int

    func visit(_ node: AROStatement) throws -> Int {
        1 + node.object.accept(self) + node.result.accept(self)
    }

    func visit(_ node: BinaryExpression) throws -> Int {
        1 + node.left.accept(self) + node.right.accept(self)
    }
}

// Count nodes in feature set
let visitor = MetricsVisitor()
let nodeCount = try featureSet.accept(visitor)
```

### Symbol Collector

```swift
struct SymbolCollectorVisitor: ASTVisitor {
    typealias Result = Set<String>

    func visit(_ node: VariableRefExpression) throws -> Set<String> {
        [node.identifier]
    }

    func visit(_ node: AROStatement) throws -> Set<String> {
        var symbols: Set<String> = []
        symbols.formUnion(try node.object.accept(self))
        symbols.formUnion(try node.result.accept(self))
        return symbols
    }
}
```

Fixes GitLab #114
