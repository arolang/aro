// ============================================================
// RunCommand.swift
// ARO CLI - Run Command
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime
import AROVersion

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run an ARO application"
    )

    @Argument(help: "Path to the application directory or .aro file")
    var path: String

    @Option(name: .shortAndLong, help: "Override the entry point feature set")
    var entryPoint: String = "Application-Start"

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long, help: "Keep the application running (for servers)")
    var keepAlive: Bool = false

    @Flag(name: .long, help: "Enable developer/debug output formatting")
    var debug: Bool = false

    func run() async throws {
        let resolvedPath = URL(fileURLWithPath: path)

        if verbose {
            print("ARO Runtime v\(AROVersion.shortVersion)")
            print("Build: \(AROVersion.buildDate)")
            print("=======================")
            print("Path: \(resolvedPath.path)")
            print("Entry point: \(entryPoint)")
            print()
        }

        // Discover application with import resolution
        let discovery = ApplicationDiscovery()
        let appConfig: DiscoveredApplication

        do {
            appConfig = try await discovery.discoverWithImports(at: resolvedPath, entryPoint: entryPoint)
        } catch {
            if TTYDetector.stderrIsTTY {
                print("\u{001B}[31mError:\u{001B}[0m \(error)")
            } else {
                print("Error: \(error)")
            }
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
                if TTYDetector.stderrIsTTY {
                    print("\u{001B}[31mError reading \(sourceFile.lastPathComponent):\u{001B}[0m \(error)")
                } else {
                    print("Error reading \(sourceFile.lastPathComponent): \(error)")
                }
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

        if verbose {
            print("\nCompilation successful!")
            print("Feature sets found:")
            for program in compiledPrograms {
                for fs in program.featureSets {
                    print("  - \(fs.featureSet.name): \(fs.featureSet.businessActivity)")
                }
            }
            print()
        }

        // Load plugins from plugins/ directory
        do {
            try PluginLoader.shared.loadPlugins(from: appConfig.rootPath)
            if verbose {
                let services = ExternalServiceRegistry.shared.registeredServices
                if services.count > 1 { // More than just built-in http
                    print("Registered services: \(services.joined(separator: ", "))")
                    print()
                }
            }
        } catch {
            print("Warning: Failed to load plugins: \(error)")
        }

        // Create and run application
        let application = Application(
            programs: compiledPrograms,
            entryPoint: entryPoint,
            config: ApplicationConfig(verbose: verbose),
            openAPISpec: appConfig.openAPISpec
        )

        if verbose {
            print("Starting application...")
            print()
        }

        do {
            if keepAlive {
                try await application.runForever()
            } else {
                let response = try await application.run()

                if verbose {
                    print("\nExecution completed:")
                }
                // Use context-aware formatting for response output
                let outputContext: OutputContext = debug ? .developer : .human
                print(response.format(for: outputContext))
            }
        } catch let error as ActionError {
            if TTYDetector.stderrIsTTY {
                print("\u{001B}[31mRuntime error:\u{001B}[0m \(error)")
            } else {
                print("Runtime error: \(error)")
            }
            throw ExitCode.failure
        } catch {
            if TTYDetector.stderrIsTTY {
                print("\u{001B}[31mError:\u{001B}[0m \(error)")
            } else {
                print("Error: \(error)")
            }
            throw ExitCode.failure
        }
    }
}
