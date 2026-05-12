// ============================================================
// ProcessRunner.swift
// AROLM - helpers for spawning and supervising child processes
// ============================================================

import Foundation

enum ProcessRunner {
    /// Locate a binary on PATH, returning its absolute path if found.
    static func which(_ name: String) -> String? {
        #if os(Windows)
        return nil
        #else
        let env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
        #endif
    }

    /// Pick a free TCP port for the runner to bind to. Uses the dynamic range.
    static func randomPort() -> Int {
        Int.random(in: 49152...65535)
    }

    /// Run a process to completion, returning stdout. Used by short-lived
    /// helpers like `parse_aro` or `aro_check`.
    @discardableResult
    static func runAndCapture(
        executable: String,
        arguments: [String],
        cwd: URL? = nil,
        timeout: TimeInterval = 60
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd = cwd {
            process.currentDirectoryURL = cwd
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()

        // Crude timeout — good enough for tool calls.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { process.interrupt() }
        }

        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
