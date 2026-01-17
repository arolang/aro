# The Construction Studies

## How ARO Was Built: A Technical Examination

---

### For Whom This Book Is Written

This book is for compiler developers, language designers, and students of compiler construction who want to understand the internal architecture of a real, working language implementation.

We assume familiarity with:
- Parsing theory (context-free grammars, recursive descent, operator precedence)
- Abstract syntax trees and visitor patterns
- Basic compiler pipeline concepts (lexing, parsing, semantic analysis, code generation)
- LLVM IR fundamentals
- Swift programming language basics

### What This Book Is Not

This is not a user guide. We do not explain ARO's syntax or teach you how to write ARO programs. For that, see *The Language Guide* or the project wiki.

This is not marketing material. We do not argue that ARO is better than other languages. We document what we built, why we built it that way, and where the design falls short.

### What You Will Learn

- How a constrained domain-specific language differs architecturally from general-purpose languages
- Practical trade-offs in lexer and parser design
- Event-driven runtime architecture with pub-sub semantics
- LLVM IR generation without the LLVM C++ API
- Swift-C interoperability patterns for language runtimes
- Honest assessment of design decisions that didn't work out

### Reading Order

Chapters are designed to be read sequentially, following the compilation pipeline from source text to executable binary. However, each chapter is self-contained enough for reference use.

---

*ARO Language Project*
*January 2026*
