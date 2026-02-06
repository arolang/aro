// ============================================================
// BuiltInRegistration.swift
// ARO Runtime - Built-in System Objects Registration
// ============================================================

import Foundation

// MARK: - Built-in System Objects Registration

public extension SystemObjectRegistry {
    /// Register all built-in system objects
    ///
    /// This registers:
    /// - Console objects (console, stderr, stdin)
    /// - Environment objects (env)
    /// - Parameter objects (parameter) - ARO-0047
    /// - File objects (file)
    /// - HTTP context objects (request, pathParameters, queryParameters, headers, body)
    /// - Event objects (event, shutdown)
    /// - Socket objects (connection, packet)
    func registerBuiltInObjects() {
        // I/O streams
        registerConsoleObjects()

        // Environment
        registerEnvironmentObjects()

        // Command-line parameters
        registerParameterObjects()

        // File system
        registerFileObjects()

        // HTTP context
        registerHTTPContextObjects()

        // Events
        registerEventObjects()

        // Sockets
        registerSocketObjects()
    }
}

// MARK: - Documentation

/// System Objects Reference
///
/// ARO provides the following built-in system objects:
///
/// ## Static Objects (Always Available)
///
/// | Identifier | Capabilities | Description |
/// |------------|--------------|-------------|
/// | `console` | Sink | Standard output stream |
/// | `stderr` | Sink | Standard error stream |
/// | `stdin` | Source | Standard input stream |
/// | `env` | Source | Environment variables |
/// | `parameter` | Source | Command-line parameters |
///
/// ## Dynamic Objects (Path/Key Required)
///
/// | Identifier | Capabilities | Description |
/// |------------|--------------|-------------|
/// | `file` | Bidirectional | File I/O with format detection |
///
/// ## Context Objects (Available in Specific Handlers)
///
/// ### HTTP Handlers
///
/// | Identifier | Capabilities | Description |
/// |------------|--------------|-------------|
/// | `request` | Source | Full HTTP request |
/// | `pathParameters` | Source | URL path parameters |
/// | `queryParameters` | Source | URL query parameters |
/// | `headers` | Source | HTTP headers |
/// | `body` | Source | Request body |
///
/// ### Event Handlers
///
/// | Identifier | Capabilities | Description |
/// |------------|--------------|-------------|
/// | `event` | Source | Event payload |
/// | `shutdown` | Source | Shutdown context |
///
/// ### Socket Handlers
///
/// | Identifier | Capabilities | Description |
/// |------------|--------------|-------------|
/// | `connection` | Bidirectional | Socket connection |
/// | `packet` | Source | Socket data packet |
public enum SystemObjectsDocumentation {}
