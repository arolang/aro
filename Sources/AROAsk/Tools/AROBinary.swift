// AROAsk - resolve the `aro` CLI binary for tool subprocesses

import Foundation

/// Resolves the `aro` CLI binary used by tool subprocesses (aro_check,
/// aro_run, the MCP bridge, the repair loop's validation, ...).
///
/// Priority:
///   1. `$ARO_BIN` — explicit override. Set by embedders (SOLARO) whose
///      own executable is NOT the CLI; without it, the fallback below
///      would pick the embedding app's binary and `aro check` would
///      relaunch the app instead of checking syntax.
///   2. The current executable, when it *is* the CLI (`aro ask ...`).
///   3. `aro` found on PATH.
///   4. Bare `"aro"` as a last resort (resolved by the spawner).
public enum AROBinary {
    public static func resolve() -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["ARO_BIN"], !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        // The running executable, by its real absolute path. This used to
        // trust CommandLine.arguments[0] and fall back to PATH when it was
        // relative — so `../../ARO-Lang/.build/release/aro ask` silently
        // checked code with a DIFFERENT aro (the installed one), and /fix
        // argued with a report its own binary would never have produced:
        // the session's checker said 4 warnings, the running build said 1.
        if let executable = Bundle.main.executablePath,
           executable.hasSuffix("/aro"),
           FileManager.default.isExecutableFile(atPath: executable) {
            return executable
        }
        if let first = CommandLine.arguments.first,
           first.hasSuffix("/aro") || first == "aro" {
            return first.hasPrefix("/") ? first : (ProcessRunner.which("aro") ?? first)
        }
        return ProcessRunner.which("aro") ?? "aro"
    }
}
