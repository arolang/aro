// ============================================================
// Exports.swift
// ARO Parser - Module Documentation
// ============================================================

/*
 AROParser Module - Public API Overview

 This module provides a complete parser for the ARO (Action Result Object)
 domain-specific language.
 
 ## Core Types
 
 ### Compilation Pipeline
 - `Compiler`: Main entry point for compilation
 - `CompilationResult`: Result of compilation with AST and diagnostics
 - `Lexer`: Tokenizes source code
 - `Parser`: Builds AST from tokens
 - `SemanticAnalyzer`: Performs semantic analysis
 
 ### AST Nodes
 - `Program`: Root node containing feature sets
 - `FeatureSet`: A named collection of related statements
 - `AROStatement`: Action-Result-Object statement
 - `PublishStatement`: Variable export statement
 - `Action`: Action verb with semantic classification
 - `QualifiedNoun`: Noun with optional specifiers
 - `ObjectClause`: Object part of ARO statement
 
 ### Symbol Management
 - `SymbolTable`: Scoped symbol storage
 - `SymbolTableBuilder`: Mutable builder for symbol tables
 - `Symbol`: Variable or binding information
 - `GlobalSymbolRegistry`: Cross-feature-set symbol registry
 
 ### Source Tracking
 - `SourceLocation`: Position in source (line, column, offset)
 - `SourceSpan`: Range in source (start to end)
 - `Token`: Lexical token with location
 
 ### Diagnostics
 - `Diagnostic`: Error, warning, or note with location
 - `DiagnosticCollector`: Collects diagnostics during compilation
 - `LexerError`: Errors during tokenization
 - `ParserError`: Errors during parsing
 - `SemanticError`: Errors during semantic analysis
 
 ## Usage Example
 
 ```swift
 import AROParser

 let source = """
 (Auth: Security) {
     <Extract> the <user: id> from the <request>.
 }
 """

 let result = Compiler.compile(source)
 if result.isSuccess {
     print(result.program)
 }
 ```
 */

// This file serves as module documentation.
// All public types are defined in their respective files.
