// ============================================================
// CompileCommand.swift
// ARO CLI - Compile Command
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROVersion

struct CompileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compile",
        abstract: "Compile ARO source files"
    )

    @Argument(help: "Path to source file or directory")
    var path: String

    @Option(name: .shortAndLong, help: "Output format (report, json, ast)")
    var format: OutputFormat = .report

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    func run() throws {
        let resolvedPath = URL(fileURLWithPath: path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath.path, isDirectory: &isDirectory) else {
            print("Error: Path not found: \(path)")
            throw ExitCode.failure
        }

        let sourceFiles: [URL]

        if isDirectory.boolValue {
            sourceFiles = try findSourceFiles(in: resolvedPath)
        } else {
            sourceFiles = [resolvedPath]
        }

        if sourceFiles.isEmpty {
            print("Error: No .aro files found")
            throw ExitCode.failure
        }

        if verbose {
            print("ARO Compiler v\(AROVersion.shortVersion)")
            print("Build: \(AROVersion.buildDate)")
            print("========================")
            print("Compiling \(sourceFiles.count) file(s)...")
            print()
        }

        let compiler = Compiler()
        var allDiagnostics: [Diagnostic] = []
        var compiledPrograms: [CompilationResult] = []

        for sourceFile in sourceFiles {
            if verbose {
                print("Compiling: \(sourceFile.lastPathComponent)")
            }

            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let result = compiler.compile(source)

            allDiagnostics.append(contentsOf: result.diagnostics)
            compiledPrograms.append(result)
        }

        // Output based on format
        switch format {
        case .report:
            outputReport(programs: compiledPrograms, diagnostics: allDiagnostics)

        case .json:
            try outputJSON(programs: compiledPrograms, diagnostics: allDiagnostics)

        case .ast:
            outputAST(programs: compiledPrograms)
        }

        // Exit with error if there were compilation errors
        let errors = allDiagnostics.filter { $0.severity == .error }
        if !errors.isEmpty {
            throw ExitCode.failure
        }
    }

    private func findSourceFiles(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sourceFiles: [URL] = []

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "aro" {
                sourceFiles.append(fileURL)
            }
        }

        return sourceFiles.sorted { $0.path < $1.path }
    }

    private func outputReport(programs: [CompilationResult], diagnostics: [Diagnostic]) {
        print("═══════════════════════════════════════════════════════════════")
        print("ARO Compilation Report")
        print("═══════════════════════════════════════════════════════════════")
        print()

        let errors = diagnostics.filter { $0.severity == .error }
        let warnings = diagnostics.filter { $0.severity == .warning }

        if errors.isEmpty {
            print("✅ Compilation successful")
        } else {
            print("❌ Compilation failed with \(errors.count) error(s)")
        }

        if !warnings.isEmpty {
            print("⚠️  \(warnings.count) warning(s)")
        }

        print()

        // Diagnostics
        if !diagnostics.isEmpty {
            print("───────────────────────────────────────────────────────────────")
            print("Diagnostics")
            print("───────────────────────────────────────────────────────────────")

            for diagnostic in diagnostics {
                let icon = diagnostic.severity == .error ? "🔴" :
                           diagnostic.severity == .warning ? "🟡" : "🔵"
                print("\(icon) \(diagnostic)")
            }
            print()
        }

        // Feature sets
        let successfulPrograms = programs.filter { $0.isSuccess }
        if !successfulPrograms.isEmpty {
            print("───────────────────────────────────────────────────────────────")
            print("Feature Sets")
            print("───────────────────────────────────────────────────────────────")

            for result in successfulPrograms {
                for fs in result.analyzedProgram.featureSets {
                    print("  [\(fs.featureSet.name)]")
                    print("    Business Activity: \(fs.featureSet.businessActivity)")
                    print("    Statements: \(fs.featureSet.statements.count)")
                    print("    Symbols: \(fs.symbolTable.symbols.count)")

                    if !fs.dependencies.isEmpty {
                        print("    Dependencies: \(fs.dependencies.sorted().joined(separator: ", "))")
                    }
                    if !fs.exports.isEmpty {
                        print("    Exports: \(fs.exports.sorted().joined(separator: ", "))")
                    }
                    print()
                }
            }
        }

        print("═══════════════════════════════════════════════════════════════")
    }

    private func outputJSON(programs: [CompilationResult], diagnostics: [Diagnostic]) throws {
        var output: [String: Any] = [:]

        output["success"] = diagnostics.filter { $0.severity == .error }.isEmpty
        output["diagnostics"] = diagnostics.map { diag -> [String: Any] in
            [
                "severity": diag.severity.rawValue,
                "message": diag.message,
                "line": diag.location?.line ?? 0,
                "column": diag.location?.column ?? 0
            ]
        }

        var featureSets: [[String: Any]] = []
        for result in programs where result.isSuccess {
            for fs in result.analyzedProgram.featureSets {
                featureSets.append([
                    "name": fs.featureSet.name,
                    "businessActivity": fs.featureSet.businessActivity,
                    "statements": fs.featureSet.statements.count,
                    "symbols": fs.symbolTable.symbols.count,
                    "dependencies": Array(fs.dependencies),
                    "exports": Array(fs.exports)
                ])
            }
        }
        output["featureSets"] = featureSets

        let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    }

    private func outputAST(programs: [CompilationResult]) {
        let printer = ASTPrinter()

        for result in programs where result.isSuccess {
            let ast = try! result.program.accept(printer)
            print(ast)
        }
    }
}

// MARK: - Output Format

enum OutputFormat: String, ExpressibleByArgument {
    case report
    case json
    case ast
}
