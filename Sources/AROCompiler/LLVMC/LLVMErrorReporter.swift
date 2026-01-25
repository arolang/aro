// ============================================================
// LLVMErrorReporter.swift
// ARO Compiler - Source-Aware Error Reporting
// ============================================================

import Foundation
import AROParser

/// Formats code generation errors with source context
public final class LLVMErrorReporter {
    private let source: String
    private let fileName: String
    private let lines: [String]

    // MARK: - Initialization

    public init(source: String, fileName: String) {
        self.source = source
        self.fileName = fileName
        self.lines = source.components(separatedBy: "\n")
    }

    // MARK: - Error Formatting

    /// Formats an error with source context
    public func format(_ error: LLVMCodeGenError) -> String {
        var output = ""

        // Get span if available
        if let span = error.span {
            // File:line:column format
            output += "\(fileName):\(span.start.line):\(span.start.column): "
        }

        // Error type
        output += "error: "

        // Error message
        output += coreMessage(for: error)
        output += "\n"

        // Show source context if we have a span
        if let span = error.span {
            output += formatSourceContext(span)
        }

        return output
    }

    /// Formats multiple errors
    public func formatAll(_ errors: [LLVMCodeGenError]) -> String {
        var output = ""
        for error in errors {
            output += format(error)
            output += "\n"
        }

        if errors.count > 1 {
            output += "\(errors.count) errors generated.\n"
        }

        return output
    }

    // MARK: - Private Helpers

    private func coreMessage(for error: LLVMCodeGenError) -> String {
        switch error {
        case .typeMismatch(let expected, let actual, let context, _):
            return "Type mismatch in \(context): expected '\(expected)', got '\(actual)'"
        case .undefinedSymbol(let name, _):
            return "Undefined symbol '\(name)'"
        case .invalidAction(let verb, _):
            return "Unknown or unsupported action '\(verb)'"
        case .invalidExpression(let desc, _):
            return "Invalid expression: \(desc)"
        case .moduleVerificationFailed(let msg):
            return "Module verification failed: \(msg)"
        case .llvmInternalError(let msg):
            return "LLVM internal error: \(msg)"
        case .noEntryPoint:
            return "No Application-Start feature set found"
        case .multipleEntryPoints:
            return "Multiple Application-Start feature sets found"
        }
    }

    private func formatSourceContext(_ span: SourceSpan) -> String {
        var output = ""

        // Get the source line (1-indexed)
        let lineIndex = span.start.line - 1
        guard lineIndex >= 0 && lineIndex < lines.count else {
            return output
        }

        let line = lines[lineIndex]

        // Line number gutter
        let lineNumStr = String(span.start.line)
        let gutterWidth = max(lineNumStr.count, 4)
        let gutter = String(repeating: " ", count: gutterWidth - lineNumStr.count) + lineNumStr

        // Show the source line
        output += "  \(gutter) | \(line)\n"

        // Show the caret pointing to the error
        let caretPadding = String(repeating: " ", count: gutterWidth + 3 + span.start.column - 1)
        let underlineLength = max(1, span.end.column - span.start.column)
        let underline = String(repeating: "^", count: underlineLength)

        output += "\(caretPadding)\(underline)\n"

        return output
    }
}

// MARK: - Console Formatting

extension LLVMErrorReporter {
    /// Formats for terminal output with ANSI colors (if supported)
    public func formatForConsole(_ error: LLVMCodeGenError, useColors: Bool = true) -> String {
        guard useColors else {
            return format(error)
        }

        var output = ""

        // File:line:column in bold
        if let span = error.span {
            output += "\u{001B}[1m\(fileName):\(span.start.line):\(span.start.column):\u{001B}[0m "
        }

        // "error:" in red bold
        output += "\u{001B}[1;31merror:\u{001B}[0m "

        // Message in bold
        output += "\u{001B}[1m\(coreMessage(for: error))\u{001B}[0m\n"

        // Source context (no special formatting)
        if let span = error.span {
            output += formatSourceContext(span)
        }

        return output
    }
}
