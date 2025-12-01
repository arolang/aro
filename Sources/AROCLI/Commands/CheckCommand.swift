// ============================================================
// CheckCommand.swift
// ARO CLI - Check Command
// ============================================================

import ArgumentParser
import Foundation
import AROParser
import ARORuntime

struct CheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check ARO source files for errors"
    )

    @Argument(help: "Path to source file or directory")
    var path: String

    @Flag(name: .long, inversion: .prefixedNo, help: "Show warnings")
    var warnings: Bool = true

    @Flag(name: .long, help: "Show verbose diagnostic information")
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

        var totalErrors = 0
        var totalWarnings = 0

        for sourceFile in sourceFiles {
            let (errors, warnings) = try checkFile(sourceFile)
            totalErrors += errors
            totalWarnings += warnings
        }

        // Summary
        print()
        if totalErrors == 0 && totalWarnings == 0 {
            print("✅ No issues found in \(sourceFiles.count) file(s)")
        } else {
            if totalErrors > 0 {
                print("❌ \(totalErrors) error(s) found")
            }
            if totalWarnings > 0 && warnings {
                print("⚠️  \(totalWarnings) warning(s) found")
            }
        }

        if totalErrors > 0 {
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

    private func checkFile(_ file: URL) throws -> (errors: Int, warnings: Int) {
        let source = try String(contentsOf: file, encoding: .utf8)
        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        let warningDiags = result.diagnostics.filter { $0.severity == .warning }

        if !errors.isEmpty || (!warningDiags.isEmpty && warnings) {
            print("\(file.lastPathComponent):")

            for error in errors {
                let location = formatLocation(error.location)
                print("  \(location) error: \(error.message)")

                if verbose, !error.hints.isEmpty {
                    for hint in error.hints {
                        print("    hint: \(hint)")
                    }
                }
            }

            if warnings {
                for warning in warningDiags {
                    let location = formatLocation(warning.location)
                    print("  \(location) warning: \(warning.message)")

                    if verbose, !warning.hints.isEmpty {
                        for hint in warning.hints {
                            print("    hint: \(hint)")
                        }
                    }
                }
            }
        } else if verbose {
            print("\(file.lastPathComponent): OK")
        }

        return (errors.count, warningDiags.count)
    }

    private func formatLocation(_ location: SourceLocation?) -> String {
        guard let loc = location else {
            return ""
        }
        return "\(loc.line):\(loc.column):"
    }
}
