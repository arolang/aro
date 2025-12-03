// ============================================================
// TestCommand.swift
// ARO CLI - Test Command
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run tests in an ARO application"
    )

    @Argument(help: "Path to the application directory")
    var path: String

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    @Option(name: .long, help: "Run only tests matching this pattern")
    var filter: String?

    @Flag(name: .long, help: "Disable colored output")
    var noColor: Bool = false

    func run() async throws {
        let resolvedPath = URL(fileURLWithPath: path)

        if verbose {
            print("ARO Test Runner v1.0.0")
            print("=======================")
            print("Path: \(resolvedPath.path)")
            if let filter = filter {
                print("Filter: \(filter)")
            }
            print()
        }

        // Discover application
        let discovery = ApplicationDiscovery()
        let appConfig: DiscoveredApplication

        do {
            // Use a dummy entry point since we're running tests, not the app
            appConfig = try await discovery.discover(
                at: resolvedPath,
                entryPoint: "Application-Start"
            )
        } catch {
            print("Error discovering application: \(error)")
            throw ExitCode.failure
        }

        if verbose {
            print("Discovered application:")
            print("  Root: \(appConfig.rootPath.path)")
            print("  Source files: \(appConfig.sourceFiles.count)")
            for file in appConfig.sourceFiles {
                print("    - \(file.lastPathComponent)")
            }
            print()
        }

        // Compile all source files
        let compiler = Compiler()
        var allDiagnostics: [Diagnostic] = []
        var compiledPrograms: [AnalyzedProgram] = []

        for sourceFile in appConfig.sourceFiles {
            if verbose {
                print("Compiling: \(sourceFile.lastPathComponent)")
            }

            let source: String
            do {
                source = try String(contentsOf: sourceFile, encoding: .utf8)
            } catch {
                print("Error reading \(sourceFile.lastPathComponent): \(error)")
                throw ExitCode.failure
            }

            let result = compiler.compile(source)
            allDiagnostics.append(contentsOf: result.diagnostics)

            if result.isSuccess {
                compiledPrograms.append(result.analyzedProgram)
            }
        }

        // Report compilation errors
        let errors = allDiagnostics.filter { $0.severity == .error }
        let warnings = allDiagnostics.filter { $0.severity == .warning }

        if !warnings.isEmpty && verbose {
            print("\nWarnings:")
            for warning in warnings {
                print("  \(warning)")
            }
        }

        if !errors.isEmpty {
            print("\nCompilation errors:")
            for error in errors {
                print("  \(error)")
            }
            throw ExitCode.failure
        }

        // Collect all feature sets
        let allFeatureSets = compiledPrograms.flatMap { $0.featureSets }

        // Filter test feature sets
        let testFeatureSets = TestRunner.filterTests(allFeatureSets)

        if verbose {
            print("\nFound \(testFeatureSets.count) test(s):")
            for fs in testFeatureSets {
                print("  - \(fs.featureSet.name)")
            }
            print()
        }

        if testFeatureSets.isEmpty {
            print("No tests found.")
            print("Tests are feature sets with business activity ending in 'Test' or 'Tests'.")
            print("Example: (Add Numbers: Calculator Test) { ... }")
            throw ExitCode.failure
        }

        // Run tests
        let runner = TestRunner(verbose: verbose)
        let results = await runner.run(
            tests: testFeatureSets,
            allFeatureSets: allFeatureSets,
            filter: filter
        )

        // Report results
        let reporter = TestReporter(verbose: verbose, useColors: !noColor)
        reporter.report(results)

        // Exit with failure if any tests failed
        if results.hasFailures {
            throw ExitCode.failure
        }
    }
}
