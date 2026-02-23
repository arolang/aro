// AROLogger.swift
// Structured logging system - ARO-0059

import Foundation

/// Log levels in order of severity
public enum AROLogLevel: Int, Comparable, Sendable {
    case trace = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case fatal = 5

    public static func < (lhs: AROLogLevel, rhs: AROLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var prefix: String {
        switch self {
        case .trace: return "[TRACE]"
        case .debug: return "[DEBUG]"
        case .info: return "[INFO]"
        case .warning: return "[WARN]"
        case .error: return "[ERROR]"
        case .fatal: return "[FATAL]"
        }
    }
}

/// Structured logger for ARO runtime
public enum AROLogger: Sendable {
    /// Current log level (controlled by ARO_LOG_LEVEL environment variable)
    public static let level: AROLogLevel = {
        guard let levelStr = ProcessInfo.processInfo.environment["ARO_LOG_LEVEL"]?.lowercased() else {
            return .info
        }
        switch levelStr {
        case "trace": return .trace
        case "debug": return .debug
        case "info": return .info
        case "warning", "warn": return .warning
        case "error": return .error
        case "fatal": return .fatal
        default: return .info
        }
    }()

    /// Log a trace message (most verbose)
    public static func trace(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(level: .trace, message: message(), file: file, line: line)
    }

    /// Log a debug message
    public static func debug(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(level: .debug, message: message(), file: file, line: line)
    }

    /// Log an informational message
    public static func info(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(level: .info, message: message(), file: file, line: line)
    }

    /// Log a warning message
    public static func warning(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(level: .warning, message: message(), file: file, line: line)
    }

    /// Log an error message
    public static func error(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(level: .error, message: message(), file: file, line: line)
    }

    /// Log a fatal error message
    public static func fatal(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
        log(level: .fatal, message: message(), file: file, line: line)
    }

    // MARK: - Internal

    private static func log(level: AROLogLevel, message: String, file: String, line: Int) {
        guard level >= Self.level else { return }

        let filename = (file as NSString).lastPathComponent
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let output = "[\(timestamp)] \(level.prefix) [\(filename):\(line)] \(message)\n"

        FileHandle.standardError.write(Data(output.utf8))
    }
}
