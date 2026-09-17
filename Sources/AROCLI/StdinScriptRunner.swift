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
/// Piped input arrives whole and may mix kinds — a feature-set definition,
/// then statements that use it — so it is split into units the way a notebook
/// cell is and each is run in source order. Consecutive statements stay
/// together as one unit, which is what lets them overlap their I/O
/// (ARO-0088); splitting them would serialise work the language is allowed to
/// run concurrently.
///
/// Before GitLab #576 the whole source was handed to
/// `REPLSession.executeStatement`, which wraps its input in a single feature
/// set — so a definition in piped source was a feature set nested inside one,
/// and failed to parse. The doc comment here claimed parity with the
/// interactive prompt, which is what that promise actually requires.
public enum StdinScriptRunner {
    public static func run(source: String) async -> StdinScriptResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }

        let units = REPLCellSplitter.split(source)
        guard !units.isEmpty else { return .empty }

        let session = REPLSession(suppressLogPrefix: true)
        do {
            for unit in units {
                let result: REPLResult
                switch unit {
                case .featureSet(let name, let activity, let unitSource, _):
                    result = try await session.defineFeatureSet(
                        name: name, activity: activity, source: unitSource
                    )
                case .statements(let unitSource, _):
                    result = try await session.executeStatement(unitSource)
                case .meta:
                    // Meta-commands (`:vars`, `:fs`) are a prompt affordance;
                    // piped source is a program, so they are skipped rather
                    // than failing the run.
                    continue
                }
                if case .error(let msg) = result {
                    return .failure(message: msg)
                }
            }
            return .success
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
