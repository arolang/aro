// ============================================================
// Compiler.swift
// ARO Parser - Main Compiler Pipeline
// ============================================================

import Foundation

// MARK: - Compilation Result

/// The result of a compilation
public struct CompilationResult: Sendable {
    public let program: Program
    public let analyzedProgram: AnalyzedProgram
    public let diagnostics: [Diagnostic]
    
    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
    
    public var isSuccess: Bool {
        !hasErrors
    }
}

// MARK: - Compiler

/// Main compiler that orchestrates the compilation pipeline
public final class Compiler {
    
    // MARK: - Properties
    
    private let diagnostics: DiagnosticCollector
    
    // MARK: - Initialization
    
    public init() {
        self.diagnostics = DiagnosticCollector()
    }
    
    // MARK: - Public Interface
    
    /// Compiles ARO source code
    public func compile(_ source: String) -> CompilationResult {
        // Clear diagnostics from previous compilations
        diagnostics.clear()

        do {
            // Phase 1: Lexical Analysis
            let tokens = try Lexer.tokenize(source)
            
            // Phase 2: Parsing
            let parser = Parser(tokens: tokens, diagnostics: diagnostics)
            let program = try parser.parse()
            
            // Phase 3: Semantic Analysis
            let analyzer = SemanticAnalyzer(diagnostics: diagnostics)
            let analyzedProgram = analyzer.analyze(program)
            
            return CompilationResult(
                program: program,
                analyzedProgram: analyzedProgram,
                diagnostics: diagnostics.diagnostics
            )
            
        } catch let error as LexerError {
            diagnostics.report(error)
            return makeFailedResult()
        } catch let error as ParserError {
            diagnostics.report(error)
            return makeFailedResult()
        } catch {
            diagnostics.error("Unexpected error: \(error)")
            return makeFailedResult()
        }
    }
    
    private func makeFailedResult() -> CompilationResult {
        let emptyProgram = Program(featureSets: [], span: SourceSpan(at: SourceLocation()))
        let emptyAnalyzed = AnalyzedProgram(
            program: emptyProgram,
            featureSets: [],
            globalRegistry: GlobalSymbolRegistry()
        )
        return CompilationResult(
            program: emptyProgram,
            analyzedProgram: emptyAnalyzed,
            diagnostics: diagnostics.diagnostics
        )
    }
}

// MARK: - Compiler Extensions

extension Compiler {
    
    /// Compiles and returns a formatted report
    public func compileWithReport(_ source: String) -> String {
        let result = compile(source)
        var report = ""
        
        report += "═══════════════════════════════════════════════════════════════\n"
        report += "ARO Compilation Report\n"
        report += "═══════════════════════════════════════════════════════════════\n\n"
        
        // Status
        if result.isSuccess {
            report += "✅ Compilation successful\n\n"
        } else {
            report += "❌ Compilation failed\n\n"
        }
        
        // Diagnostics
        if !result.diagnostics.isEmpty {
            report += "───────────────────────────────────────────────────────────────\n"
            report += "Diagnostics\n"
            report += "───────────────────────────────────────────────────────────────\n"
            for diagnostic in result.diagnostics {
                let icon = diagnostic.severity == .error ? "🔴" : 
                           diagnostic.severity == .warning ? "🟡" : "🔵"
                report += "\(icon) \(diagnostic)\n"
            }
            report += "\n"
        }
        
        // AST Summary
        if result.isSuccess {
            report += "───────────────────────────────────────────────────────────────\n"
            report += "AST Summary\n"
            report += "───────────────────────────────────────────────────────────────\n"
            report += "Feature Sets: \(result.program.featureSets.count)\n"
            
            for (index, fs) in result.program.featureSets.enumerated() {
                report += "\n[\(index + 1)] \(fs.name)\n"
                report += "    Business Activity: \(fs.businessActivity)\n"
                report += "    Statements: \(fs.statements.count)\n"
            }
            report += "\n"
            
            // Symbol Tables
            report += "───────────────────────────────────────────────────────────────\n"
            report += "Symbol Tables\n"
            report += "───────────────────────────────────────────────────────────────\n"
            
            for analyzed in result.analyzedProgram.featureSets {
                report += "\n\(analyzed.featureSet.name):\n"
                for (name, symbol) in analyzed.symbolTable.symbols.sorted(by: { $0.key < $1.key }) {
                    let visibility = symbol.visibility == .published ? "📤" : "🔒"
                    report += "  \(visibility) \(name): \(symbol.source)\n"
                }
                
                if !analyzed.dependencies.isEmpty {
                    report += "  Dependencies: \(analyzed.dependencies.sorted().joined(separator: ", "))\n"
                }
                if !analyzed.exports.isEmpty {
                    report += "  Exports: \(analyzed.exports.sorted().joined(separator: ", "))\n"
                }
            }
            report += "\n"
            
            // Data Flow
            report += "───────────────────────────────────────────────────────────────\n"
            report += "Data Flow Analysis\n"
            report += "───────────────────────────────────────────────────────────────\n"
            
            for analyzed in result.analyzedProgram.featureSets {
                report += "\n\(analyzed.featureSet.name):\n"
                for (index, flow) in analyzed.dataFlows.enumerated() {
                    let stmt = analyzed.featureSet.statements[index]
                    if let aro = stmt as? AROStatement {
                        report += "  [\(index + 1)] <\(aro.action.verb)>\n"
                        report += "      Inputs:  \(flow.inputs.sorted().joined(separator: ", "))\n"
                        report += "      Outputs: \(flow.outputs.sorted().joined(separator: ", "))\n"
                        if !flow.sideEffects.isEmpty {
                            report += "      Effects: \(flow.sideEffects.joined(separator: ", "))\n"
                        }
                    }
                }
            }
        }
        
        report += "\n═══════════════════════════════════════════════════════════════\n"
        
        return report
    }
}

// MARK: - Static Convenience

extension Compiler {
    /// Compiles source code in one step
    public static func compile(_ source: String) -> CompilationResult {
        Compiler().compile(source)
    }
    
    /// Compiles source code and returns a report
    public static func compileWithReport(_ source: String) -> String {
        Compiler().compileWithReport(source)
    }
}
