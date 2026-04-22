// ============================================================
// AROLogger.swift
// Structured logging system backed by swift-log
// ============================================================

import Foundation
import Logging

/// Centralized logging for the ARO runtime.
///
/// Usage:
///   AROLogger.debug("loaded plugin", subsystem: "plugins")
///   AROLogger.info("server started on port \(port)")
///   AROLogger.error("failed to parse: \(error)")
public enum AROLogger: Sendable {
    /// The shared logger instance. Bootstrap once at startup.
    public nonisolated(unsafe) static var logger = Logger(label: "aro")

    /// Configure the global log level (call from CLI before any logging).
    public static func setLevel(_ level: Logger.Level) {
        logger.logLevel = level
    }

    /// Log a debug message.
    public static func debug(
        _ message: @autoclosure () -> String,
        subsystem: String? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        let text = formatMessage(message(), subsystem: subsystem)
        logger.debug("\(text)", file: file, line: UInt(line))
    }

    /// Log an informational message.
    public static func info(
        _ message: @autoclosure () -> String,
        subsystem: String? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        let text = formatMessage(message(), subsystem: subsystem)
        logger.info("\(text)", file: file, line: UInt(line))
    }

    /// Log a warning message.
    public static func warning(
        _ message: @autoclosure () -> String,
        subsystem: String? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        let text = formatMessage(message(), subsystem: subsystem)
        logger.warning("\(text)", file: file, line: UInt(line))
    }

    /// Log an error message.
    public static func error(
        _ message: @autoclosure () -> String,
        subsystem: String? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        let text = formatMessage(message(), subsystem: subsystem)
        logger.error("\(text)", file: file, line: UInt(line))
    }

    /// Log a trace message (most verbose).
    public static func trace(
        _ message: @autoclosure () -> String,
        subsystem: String? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        let text = formatMessage(message(), subsystem: subsystem)
        logger.trace("\(text)", file: file, line: UInt(line))
    }

    /// Log a fatal error message (maps to critical in swift-log).
    public static func fatal(
        _ message: @autoclosure () -> String,
        subsystem: String? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        let text = formatMessage(message(), subsystem: subsystem)
        logger.critical("\(text)", file: file, line: UInt(line))
    }

    // MARK: - Internal

    private static func formatMessage(_ message: String, subsystem: String?) -> String {
        if let sub = subsystem {
            return "[\(sub)] \(message)"
        }
        return message
    }
}
