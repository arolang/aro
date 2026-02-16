// ============================================================
// StdioTransport.swift
// ARO MCP - Standard I/O Transport
// ============================================================

import Foundation

/// Transport protocol for MCP communication
public protocol MCPTransport: Sendable {
    func start() async throws
    func stop() async
    func send(_ message: String) async throws
    func receive() async throws -> String?
}

/// Standard I/O transport for MCP
/// Reads JSON-RPC messages from stdin, writes to stdout
/// Messages are newline-delimited
public actor StdioTransport: MCPTransport {
    private var isRunning = false
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let errorHandle: FileHandle

    public init() {
        self.inputHandle = FileHandle.standardInput
        self.outputHandle = FileHandle.standardOutput
        self.errorHandle = FileHandle.standardError
    }

    public func start() async throws {
        isRunning = true
    }

    public func stop() async {
        isRunning = false
    }

    /// Send a message to stdout (newline-delimited)
    public func send(_ message: String) async throws {
        guard isRunning else { return }

        let output = message + "\n"
        guard let data = output.data(using: .utf8) else {
            throw MCPTransportError.encodingError
        }

        outputHandle.write(data)
    }

    /// Read a message from stdin
    /// Returns nil if no more input is available
    public func receive() async throws -> String? {
        guard isRunning else { return nil }

        // Read line from stdin
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                if let line = readLine(strippingNewline: true) {
                    if !line.isEmpty {
                        continuation.resume(returning: line)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Log a message to stderr (for debugging)
    public func log(_ message: String) {
        let output = "[ARO MCP] \(message)\n"
        if let data = output.data(using: .utf8) {
            errorHandle.write(data)
        }
    }
}

/// Transport errors
public enum MCPTransportError: Error, Sendable {
    case encodingError
    case connectionClosed
    case timeout
}
