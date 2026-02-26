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

    @Argument(parsing: .captureForPassthrough, help: "Arguments to pass to the application")
    var applicationArguments: [String] = []

    @Option(name: .shortAndLong, help: "Override the entry point feature set")
    var entryPoint: String = "Application-Start"

    @Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose: Bool = false

    @Flag(name: .long, help: "Keep the application running (for servers)")
    var keepAlive: Bool = false

    @Flag(name: .long, help: "Enable developer/debug output formatting")
    var debug: Bool = false

    @Option(name: .long, help: "Record events to JSON file")
    var record: String?

    @Option(name: .long, help: "Replay events from JSON file")
    var replay: String?

    /// Extract run command flags from captured application arguments
    /// This handles cases where flags are placed after the path argument
    mutating func extractRunCommandFlags() {
        var remainingArgs: [String] = []
        var i = 0

        while i < applicationArguments.count {
            let arg = applicationArguments[i]

            switch arg {
            case "--debug":
                debug = true
                i += 1
            case "--verbose", "-v":
                verbose = true
                i += 1
            case "--keep-alive":
                keepAlive = true
                i += 1
            case "--entry-point", "-e":
                // Check if there's a value following
                if i + 1 < applicationArguments.count {
                    entryPoint = applicationArguments[i + 1]
                    i += 2
                } else {
                    // Invalid usage, but pass it through to avoid silent failure
                    remainingArgs.append(arg)
                    i += 1
                }
            case "--record":
                // Check if there's a value following
                if i + 1 < applicationArguments.count {
                    record = applicationArguments[i + 1]
                    i += 2
                } else {
                    remainingArgs.append(arg)
                    i += 1
                }
            case "--replay":
                // Check if there's a value following
                if i + 1 < applicationArguments.count {
                    replay = applicationArguments[i + 1]
                    i += 2
                } else {
                    remainingArgs.append(arg)
                    i += 1
                }
            default:
                // Not a run command flag, keep it for the application
                remainingArgs.append(arg)
                i += 1
            }
        }

        applicationArguments = remainingArgs
    }

    func run() async throws {
        var mutableSelf = self
        mutableSelf.extractRunCommandFlags()

        let resolvedPath = URL(fileURLWithPath: mutableSelf.path)

        // ARO-0047: Parse application arguments into ParameterStorage
        if !mutableSelf.applicationArguments.isEmpty {
            ParameterStorage.shared.parseArguments(mutableSelf.applicationArguments)
        }

        let verbose = mutableSelf.verbose
        let debug = mutableSelf.debug
        let keepAlive = mutableSelf.keepAlive
        let entryPoint = mutableSelf.entryPoint
        let applicationArguments = mutableSelf.applicationArguments
        let recordPath = mutableSelf.record
        let replayPath = mutableSelf.replay

        if verbose {
            print("ARO Runtime v\(AROVersion.shortVersion)")
            print("Build: \(AROVersion.buildDate)")
            print("=======================")
            print("Path: \(resolvedPath.path)")
            print("Entry point: \(entryPoint)")
            if !applicationArguments.isEmpty {
                print("Application arguments: \(applicationArguments.joined(separator: " "))")
            }
            if let recordPath {
                print("Recording events to: \(recordPath)")
            }
            if let replayPath {
                print("Replaying events from: \(replayPath)")
            }
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

        // Load plugins from plugins/ directory (local plugins)
        do {
            try PluginLoader.shared.loadPlugins(from: appConfig.rootPath)
        } catch {
            print("Warning: Failed to load local plugins: \(error)")
        }

        // Load managed plugins from Plugins/ directory (installed via aro add)
        // Use UnifiedPluginLoader to handle all plugin types (native, Python, ARO files)
        do {
            try UnifiedPluginLoader.shared.loadPlugins(from: appConfig.rootPath)
        } catch {
            print("Warning: Failed to load managed plugins: \(error)")
        }

        if verbose {
            let services = ExternalServiceRegistry.shared.registeredServices
            if services.count > 1 { // More than just built-in http
                print("Registered services: \(services.joined(separator: ", "))")
                print()
            }
        }

        // Create and run application
        let application = Application(
            programs: compiledPrograms,
            entryPoint: entryPoint,
            config: ApplicationConfig(verbose: verbose, workingDirectory: appConfig.rootPath.path),
            openAPISpec: appConfig.openAPISpec,
            recordPath: recordPath,
            replayPath: replayPath
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
                // Don't print lifecycle exit response (e.g., "Return ... for the <application>")
                if response.reason != "application" {
                    print(response.format(for: outputContext))
                }
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
