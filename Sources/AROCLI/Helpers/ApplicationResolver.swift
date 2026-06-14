// ============================================================
// ApplicationResolver.swift
// ARO CLI - Shared `ApplicationDiscovery` invocation helper
// ============================================================
//
// Each command (run, debug, build, test) used to spell out the
// same four-line discovery dance: instantiate
// \`ApplicationDiscovery\`, call \`discoverWithImports\`, format
// the error to stderr / stdout, and throw \`ExitCode.failure\`.
// Discovery changes had to land in four places (#361).
//
// This helper consolidates the call. Each command supplies the
// path, optional entry point + plugin flag, and an error-line
// prefix matching its previous wording; the helper handles the
// rest.

import Foundation
import ArgumentParser
import ARORuntime

/// Helper consolidating the four CLI commands'
/// \`ApplicationDiscovery\` boilerplate.
enum ApplicationResolver {
    /// Run \`ApplicationDiscovery.discoverWithImports\` with
    /// unified error handling. On failure the helper prints
    /// \`<errorPrefix>: <error>\` to stdout (matching the
    /// previous per-command behaviour, including the optional
    /// red ANSI marker for stderr-bound TTYs) and throws
    /// \`ExitCode.failure\`.
    static func resolve(
        at path: URL,
        entryPoint: String = "Application-Start",
        includePlugins: Bool = false,
        errorPrefix: String = "Error",
        colorizeOnTTY: Bool = false
    ) async throws -> DiscoveredApplication {
        let discovery = ApplicationDiscovery()
        do {
            return try await discovery.discoverWithImports(
                at: path,
                entryPoint: entryPoint,
                includePlugins: includePlugins
            )
        } catch {
            if colorizeOnTTY, TTYDetector.stderrIsTTY {
                print("\u{001B}[31m\(errorPrefix):\u{001B}[0m \(error)")
            } else {
                print("\(errorPrefix): \(error)")
            }
            throw ExitCode.failure
        }
    }
}
