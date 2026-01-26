// ============================================================
// ApplicationEndTests.swift
// ARO Runtime - Application-End Handler Integration Tests
// Tests for Application-End: Success and Application-End: Error
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Application-End Integration Tests

@Suite("Application-End Handler Tests", .serialized)
struct ApplicationEndTests {

    /// Find the pre-built aro binary in the build directory.
    private func findAroBinary() throws -> URL {
        var projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while !FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Package.swift").path) {
            let parent = projectRoot.deletingLastPathComponent()
            if parent == projectRoot {
                throw NSError(domain: "ApplicationEndTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find project root"])
            }
            projectRoot = parent
        }

        let binaryPath = projectRoot.appendingPathComponent(".build/debug/aro")
        guard FileManager.default.fileExists(atPath: binaryPath.path) else {
            throw NSError(domain: "ApplicationEndTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "aro binary not found at \(binaryPath.path). Run 'swift build' first."])
        }
        return binaryPath
    }

    /// Helper to create a temporary ARO file and run it with --keep-alive,
    /// optionally sending SIGINT after a delay to trigger graceful shutdown.
    private func runAROCodeKeepAlive(
        _ aroCode: String,
        sendSIGINTAfter signalDelay: TimeInterval? = nil
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let aroBinary = try findAroBinary()

        // Create temporary directory for test ARO file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ARO-ApplicationEndTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Write ARO code to temporary file
        let aroFile = tempDir.appendingPathComponent("main.aro")
        try aroCode.write(to: aroFile, atomically: true, encoding: .utf8)

        // Set up process using pre-built binary directly
        let process = Process()
        process.executableURL = aroBinary
        process.arguments = ["run", "--keep-alive", tempDir.path]

        // Clear test environment variables to prevent TestWatchdog from initializing in subprocess
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "XCTestConfigurationFilePath")
        environment.removeValue(forKey: "XCTestSessionIdentifier")
        environment.removeValue(forKey: "XCTestBundlePath")
        process.environment = environment

        // Capture stdout and stderr
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // If requested, send SIGINT after a delay to trigger graceful shutdown
        if let delay = signalDelay {
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                kill(pid, SIGINT)
            }
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    // MARK: - Application-End: Success

    @Test("Application-End: Success handler executes on graceful shutdown")
    func testApplicationEndSuccess() async throws {
        let aroCode = """
        (Application-Start: Test Graceful Shutdown) {
            <Log> "Application started" to the <console>.
            <Return> an <OK: status> for the <startup>.
        }

        (Application-End: Success) {
            <Log> "SUCCESS_SHUTDOWN_HANDLER_EXECUTED" to the <console>.
            <Return> an <OK: status> for the <shutdown>.
        }
        """

        // Run with --keep-alive; send SIGINT after 1 second to trigger graceful shutdown
        let result = try await runAROCodeKeepAlive(aroCode, sendSIGINTAfter: 1.0)

        let output = result.stdout + result.stderr

        // Verify Application-Start ran
        #expect(output.contains("Application started"))

        // Verify Application-End: Success handler executed
        #expect(output.contains("SUCCESS_SHUTDOWN_HANDLER_EXECUTED"))
    }

    // MARK: - Application-End: Error

    @Test("Application-End: Error handler executes on runtime error")
    func testApplicationEndError() async throws {
        let aroCode = """
        (Application-Start: Test Error Shutdown) {
            <Log> "Application starting" to the <console>.
            <Throw> the <FatalError> for the <test-crash>.
        }

        (Application-End: Error) {
            <Log> "ERROR_SHUTDOWN_HANDLER_EXECUTED" to the <console>.
            <Return> an <OK: status> for the <error-handling>.
        }
        """

        // Run with --keep-alive; the Throw action triggers Application-End: Error automatically
        let result = try await runAROCodeKeepAlive(aroCode)

        let output = result.stdout + result.stderr

        // Verify Application-Start began
        #expect(output.contains("Application starting"))

        // Verify Application-End: Error handler executed
        #expect(output.contains("ERROR_SHUTDOWN_HANDLER_EXECUTED"))

        // Verify the process exited with an error (non-zero)
        #expect(result.exitCode != 0)
    }
}
