# The Construction Studies — Table of Contents

## Front Matter
- [Cover](Cover.md)

## Part I: Foundations

### [Chapter 1: Design Philosophy](Chapter01-DesignPhilosophy.md)
The constraint hypothesis. Data flow as organizing principle. Immutability by default. The "code is the error message" philosophy. Plugin system escape hatches. Trade-off analysis.

### [Chapter 2: Lexical Analysis](Chapter02-LexicalAnalysis.md)
Character classification. Articles and prepositions as first-class tokens. String interpolation challenges. Regex vs division ambiguity. Source location tracking. Extended literal support (triple-quoted, raw, hex, binary).

### [Chapter 3: Syntactic Analysis](Chapter03-SyntacticAnalysis.md)
Hybrid parser design: recursive descent + Pratt parsing. Eight statement types. Error recovery strategy. Single lookahead limitations.

### [Chapter 4: Abstract Syntax](Chapter04-AbstractSyntax.md)
AST node hierarchy (8 statement types). Statement vs expression dichotomy. The QualifiedNoun pattern. Visitor pattern implementation. Sendable conformance.

### [Chapter 5: Semantic Analysis](Chapter05-SemanticAnalysis.md)
Symbol table design. Visibility levels. Business activity isolation. Type system simplicity. Data flow classification. Immutability enforcement. VerbSets shared module. Plugin compatibility checking.

## Part II: Execution

### [Chapter 6: Interpreted Execution](Chapter06-InterpretedExecution.md)
Execution engine architecture. ExecutionContext protocol. FeatureSetExecutor. ActionRegistry design. Descriptor-based invocation. Response short-circuit.

### [Chapter 7: Event Architecture](Chapter07-EventArchitecture.md)
EventBus design. Handler registration. Five handler types. State guards. In-flight tracking. Race condition prevention. AsyncStream integration.

## Part III: Native Compilation

### [Chapter 8: Native Compilation](Chapter08-NativeCompilation.md)
Swifty-LLVM C API strategy. Module structure. String constant collection. Feature set to function mapping with error_exit blocks. Descriptor allocation. Control flow generation (when, match, for-each, range-loop, while-loop, break).

### [Chapter 9: Runtime Bridge](Chapter09-RuntimeBridge.md)
Swift-C-LLVM interoperability. @_cdecl functions (61 actions). Handle management. Descriptor conversion. Platform-specific linking. The swiftrt.o requirement.

## Part IV: Assessment

### [Chapter 10: Critical Assessment](Chapter10-CriticalAssessment.md)
What works well. What doesn't work. Resolved issues (LLVM type checking now fixed via Swifty-LLVM). Design decisions we'd reconsider. Plugin system additions. Lessons for language implementers.

### [Chapter 11: Dual-Mode Execution Parity](Chapter11-DualModeExecutionParity.md)
Sources of interpreter/binary divergence. VerbSets shared module. Integer division parity. DomainEvent co-publishing pattern. Handler registration template. Payload schema contracts. The `mode: both` test directive.

### [Chapter 12: The Evolution of ARO](Chapter12-Evolution.md)
The back-and-forth that shaped the specification. Statement count growth (5→8), the verb classification problem, dual-mode parity bugs, the Swifty-LLVM migration, plugin naming evolution, HTTP in binary mode, and what we'd design differently.

## Appendices

### [Appendix A: Source Map](Appendix-SourceMap.md)
Key file locations and their responsibilities.

### [Appendix B: Grammar Specification](AppendixB-Grammar.md)
Complete formal grammar specification for ARO in EBNF notation.

---

**Total**: ~90 pages
**Figures**: 27 SVG diagrams
