// ============================================================
// LogActionTests.swift
// ARO Runtime - Log Action Comprehensive Tests
// Tests for stderr support via qualifiers
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Log Action Unit Tests

@Suite("Log Action Unit Tests")
struct LogActionUnitTests {

    @Test("Log action role is response")
    func testLogActionRole() {
        #expect(LogAction.role == .response)
    }

    @Test("Log action verbs")
    func testLogActionVerbs() {
        #expect(LogAction.verbs.contains("log"))
        #expect(LogAction.verbs.contains("print"))
        #expect(LogAction.verbs.contains("output"))
        #expect(LogAction.verbs.contains("debug"))
    }

    @Test("Log action valid prepositions")
    func testLogActionPrepositions() {
        #expect(LogAction.validPrepositions.contains(.for))
        #expect(LogAction.validPrepositions.contains(.to))
        #expect(LogAction.validPrepositions.contains(.with))
    }
}

// MARK: - Log Action Integration Tests

@Suite("Log Action Stream Routing", .serialized, .disabled("Slow integration tests - each spawns swift run"))
struct LogActionStreamTests {

    /// Helper to create a temporary ARO file and run it, capturing stdout/stderr
    private func runAROCode(
        _ aroCode: String,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        // Create temporary directory for test ARO file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ARO-LogActionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Write ARO code to temporary file
        let aroFile = tempDir.appendingPathComponent("main.aro")
        try aroCode.write(to: aroFile, atomically: true, encoding: .utf8)

        // Find aro executable
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["run", "aro", "run", tempDir.path]

        // Find project root (look for Package.swift)
        var projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while !FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent("Package.swift").path) {
            let parent = projectRoot.deletingLastPathComponent()
            if parent == projectRoot {
                // Reached root without finding Package.swift
                throw NSError(domain: "LogActionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find project root"])
            }
            projectRoot = parent
        }
        process.currentDirectoryURL = projectRoot

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
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    @Test("Log to console (default - stdout)")
    func testLogToConsoleDefault() async throws {
        let aroCode = """
        (Application-Start: Test Default Stdout) {
            Log "Default stdout message" to the <console>.
            Return an <OK: status> for the <test>.
        }
        """

        let result = try await runAROCode(aroCode)

        // Verify stdout contains the message (prefixed with feature set name in interpreted mode)
        #expect(result.stdout.contains("[Application-Start] Default stdout message"))

        // Verify stderr does NOT contain the message
        #expect(!result.stderr.contains("Default stdout message"))

        // Verify successful execution
        #expect(result.exitCode == 0)
    }

    @Test("Log to console with output qualifier (explicit stdout)")
    func testLogToConsoleOutputQualifier() async throws {
        let aroCode = """
        (Application-Start: Test Explicit Stdout) {
            Log "Explicit stdout message" to the <console: output>.
            Return an <OK: status> for the <test>.
        }
        """

        let result = try await runAROCode(aroCode)

        // Verify stdout contains the message (prefixed with feature set name in interpreted mode)
        #expect(result.stdout.contains("[Application-Start] Explicit stdout message"))

        // Verify stderr does NOT contain the message
        #expect(!result.stderr.contains("Explicit stdout message"))

        // Verify successful execution
        #expect(result.exitCode == 0)
    }

    @Test("Log to console with error qualifier (stderr)")
    func testLogToConsoleErrorQualifier() async throws {
        let aroCode = """
        (Application-Start: Test Stderr) {
            Log "Error message to stderr" to the <console: error>.
            Return an <OK: status> for the <test>.
        }
        """

        let result = try await runAROCode(aroCode)

        // Verify stderr contains the error message (prefixed with feature set name in interpreted mode)
        #expect(result.stderr.contains("[Application-Start] Error message to stderr"))

        // Verify stdout does NOT contain the error message
        #expect(!result.stdout.contains("Error message to stderr"))

        // Verify successful execution
        #expect(result.exitCode == 0)
    }

    @Test("Log to console with invalid qualifier (defaults to stdout)")
    func testLogToConsoleInvalidQualifier() async throws {
        let aroCode = """
        (Application-Start: Test Invalid Qualifier) {
            Log "Message with invalid qualifier" to the <console: unknown>.
            Return an <OK: status> for the <test>.
        }
        """

        let result = try await runAROCode(aroCode)

        // Verify stdout contains the message (prefixed with feature set name in interpreted mode)
        #expect(result.stdout.contains("[Application-Start] Message with invalid qualifier"))

        // Verify stderr does NOT contain the message
        #expect(!result.stderr.contains("Message with invalid qualifier"))

        // Verify successful execution
        #expect(result.exitCode == 0)
    }

    @Test("Log to stderr object (backward compatibility)")
    func testLogToStderrObject() async throws {
        let aroCode = """
        (Application-Start: Test Stderr Object) {
            Log "Direct stderr message" to the <stderr>.
            Return an <OK: status> for the <test>.
        }
        """

        let result = try await runAROCode(aroCode)

        // Verify stderr contains the message (prefixed with feature set name in interpreted mode)
        #expect(result.stderr.contains("[Application-Start] Direct stderr message"))

        // Verify stdout does NOT contain the message
        #expect(!result.stdout.contains("Direct stderr message"))

        // Verify successful execution
        #expect(result.exitCode == 0)
    }

    @Test("Mixed stdout and stderr logging")
    func testMixedStdoutStderrLogging() async throws {
        let aroCode = """
        (Application-Start: Test Mixed Streams) {
            Log "Stdout message 1" to the <console>.
            Log "Stderr message 1" to the <console: error>.
            Log "Stdout message 2" to the <console: output>.
            Log "Stderr message 2" to the <console: error>.
            Return an <OK: status> for the <test>.
        }
        """

        let result = try await runAROCode(aroCode)

        // Verify stdout contains stdout messages only (prefixed with feature set name in interpreted mode)
        #expect(result.stdout.contains("[Application-Start] Stdout message 1"))
        #expect(result.stdout.contains("[Application-Start] Stdout message 2"))
        #expect(!result.stdout.contains("Stderr message"))

        // Verify stderr contains stderr messages only (prefixed with feature set name in interpreted mode)
        #expect(result.stderr.contains("[Application-Start] Stderr message 1"))
        #expect(result.stderr.contains("[Application-Start] Stderr message 2"))
        #expect(!result.stderr.contains("Stdout message"))

        // Verify successful execution
        #expect(result.exitCode == 0)
    }
}
