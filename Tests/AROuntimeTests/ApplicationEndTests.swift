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

    /// Accumulates a subprocess's output off the reader thread and lets the test
    /// wait for a marker to appear.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()
        private var marker: String?
        private let markerSeen = DispatchSemaphore(value: 0)
        private var signalled = false

        init(waitingFor marker: String?) { self.marker = marker }

        func appendStdout(_ data: Data) { append(data, to: \.stdoutData) }
        func appendStderr(_ data: Data) { append(data, to: \.stderrData) }

        private func append(_ data: Data, to keyPath: ReferenceWritableKeyPath<OutputCollector, Data>) {
            lock.lock(); defer { lock.unlock() }
            self[keyPath: keyPath].append(data)
            guard let marker, !signalled else { return }
            let combined = String(decoding: stdoutData, as: UTF8.self)
                + String(decoding: stderrData, as: UTF8.self)
            if combined.contains(marker) {
                signalled = true
                markerSeen.signal()
            }
        }

        /// Wait for the marker, returning false on timeout.
        func waitForMarker(timeout: TimeInterval) -> Bool {
            markerSeen.wait(timeout: .now() + timeout) == .success
        }

        var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stdoutData, as: UTF8.self) }
        var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: stderrData, as: UTF8.self) }
    }

    /// Helper to create a temporary ARO file and run it with --keep-alive.
    ///
    /// `signalOnceOutputContains` names a marker the program prints when it is
    /// actually up; SIGINT is sent once it appears. The previous version slept a
    /// fixed second and signalled regardless, which is fine on an idle machine
    /// and wrong on a loaded one: the signal arrived before the program had
    /// started, so no handler ran and the test saw empty output. That is exactly
    /// how it failed — intermittently, only when the example suite was running
    /// alongside it.
    private func runAROCodeKeepAlive(
        _ aroCode: String,
        signalOnceOutputContains readyMarker: String? = nil,
        readyTimeout: TimeInterval = 30
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

        // Drain both pipes continuously. Reading only after exit can deadlock a
        // program that fills a pipe buffer while we wait for it.
        let collector = OutputCollector(waitingFor: readyMarker)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            collector.appendStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            collector.appendStderr(data)
        }

        try process.run()

        if readyMarker != nil {
            // Signal only once the program says it is up. On timeout, signal
            // anyway so the test fails on its own assertions rather than hanging.
            _ = collector.waitForMarker(timeout: readyTimeout)
            kill(process.processIdentifier, SIGINT)
        }

        process.waitUntilExit()

        // Give the readers a moment to drain what was written just before exit.
        try? await Task.sleep(nanoseconds: 200_000_000)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        return (stdout: collector.stdout, stderr: collector.stderr, exitCode: process.terminationStatus)
    }

    // MARK: - Application-End: Success

    @Test("Application-End: Success handler executes on graceful shutdown")
    func testApplicationEndSuccess() async throws {
        let aroCode = """
        (Application-Start: Test Graceful Shutdown) {
            Log "Application started" to the <console>.
            Return an <OK: status> for the <startup>.
        }

        (Application-End: Success) {
            Log "SUCCESS_SHUTDOWN_HANDLER_EXECUTED" to the <console>.
            Return an <OK: status> for the <shutdown>.
        }
        """

        // Signal once the program has actually started, not after a fixed delay.
        let result = try await runAROCodeKeepAlive(aroCode, signalOnceOutputContains: "Application started")

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
            Log "Application starting" to the <console>.
            Throw the <FatalError> for the <test-crash>.
        }

        (Application-End: Error) {
            Log "ERROR_SHUTDOWN_HANDLER_EXECUTED" to the <console>.
            Return an <OK: status> for the <error-handling>.
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
