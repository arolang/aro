// StdinScriptRunner.swift
// ARO CLI - Pipe-to-stdin evaluation
//
// When `aro` is invoked with no arguments and stdin is not a TTY, the source
// piped on stdin is evaluated through the REPL's session so that semantics
// match `aro repl` exactly (issue #200).

import Foundation

/// Result of running a piped stdin script.
public enum StdinScriptResult: Sendable {
    case success
    case empty
    case failure(message: String)
}

/// Evaluates an ARO source string by delegating to a single REPL session.
///
/// The full source is wrapped in one feature set by `REPLSession.executeStatement`,
/// so multi-line input shares a single evaluation context — identical to pasting
/// the same lines into an interactive `aro repl`.
public enum StdinScriptRunner {
    public static func run(source: String) async -> StdinScriptResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }

        let session = REPLSession(suppressLogPrefix: true)
        do {
            let result = try await session.executeStatement(source)
            switch result {
            case .error(let msg):
                return .failure(message: msg)
            default:
                return .success
            }
        } catch {
            return .failure(message: String(describing: error))
        }
    }

    /// Read all of stdin as UTF-8. Blocks until EOF.
    public static func readStdin() -> String? {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
