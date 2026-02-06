# The Construction Studies — Table of Contents

## Front Matter
- [Cover](Cover.md)

## Part I: Foundations

### [Chapter 1: Design Philosophy](Chapter01-DesignPhilosophy.md)
The constraint hypothesis. Data flow as organizing principle. Immutability by default. The "code is the error message" philosophy. Trade-off analysis.

### [Chapter 2: Lexical Analysis](Chapter02-LexicalAnalysis.md)
Character classification. Articles and prepositions as first-class tokens. String interpolation challenges. Regex vs division ambiguity. Source location tracking.

### [Chapter 3: Syntactic Analysis](Chapter03-SyntacticAnalysis.md)
Hybrid parser design: recursive descent + Pratt parsing. Statement structure. Error recovery strategy. Single lookahead limitations.

### [Chapter 4: Abstract Syntax](Chapter04-AbstractSyntax.md)
AST node hierarchy. Statement vs expression dichotomy. The QualifiedNoun pattern. Visitor pattern implementation. Sendable conformance.

### [Chapter 5: Semantic Analysis](Chapter05-SemanticAnalysis.md)
Symbol table design. Visibility levels. Business activity isolation. Type system simplicity. Data flow classification. Immutability enforcement.

## Part II: Execution

### [Chapter 6: Interpreted Execution](Chapter06-InterpretedExecution.md)
Execution engine architecture. ExecutionContext protocol. FeatureSetExecutor. ActionRegistry design. Descriptor-based invocation. Response short-circuit.

### [Chapter 7: Event Architecture](Chapter07-EventArchitecture.md)
EventBus design. Handler registration. Five handler types. State guards. In-flight tracking. Race condition prevention. AsyncStream integration.

## Part III: Native Compilation

### [Chapter 8: Native Compilation](Chapter08-NativeCompilation.md)
LLVM textual IR strategy. Module structure. String constant collection. Feature set to function mapping. Descriptor allocation. Control flow generation.

### [Chapter 9: Runtime Bridge](Chapter09-RuntimeBridge.md)
Swift-C-LLVM interoperability. @_cdecl functions. Handle management. Descriptor conversion. Platform-specific linking. The swiftrt.o requirement.

## Part IV: Assessment

### [Chapter 10: Critical Assessment](Chapter10-CriticalAssessment.md)
What works well. What doesn't work. Design decisions we'd reconsider. Lessons for language implementers.

## Appendices

### [Appendix A: Source Map](Appendix-SourceMap.md)
Key file locations and their responsibilities.

### [Appendix B: Grammar Specification](AppendixB-Grammar.md)
Complete formal grammar specification for ARO in EBNF notation.

---

**Total**: ~75 pages
**Figures**: 27 SVG diagrams
**Code References**: Inline with line numbers
