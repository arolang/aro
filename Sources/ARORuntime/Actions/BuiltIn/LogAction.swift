// ============================================================
// LogAction.swift
// ARO Runtime - Log: writing a message to a target
// ============================================================

import Foundation
import AROParser

/// Logs a message
public struct LogAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["log", "print", "output", "debug"]
    public static let validPrepositions: Set<Preposition> = [.for, .to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // ARO-0051: Streaming support - only drain lazy streams
        if let runtimeContext = context as? RuntimeContext,
           runtimeContext.isLazy(result.base),
           let stream = runtimeContext.resolveAsRowStream(result.base) {
            // Drain stream by logging each element as it arrives
            let count = try await drainStream(stream) { item in
                try write(line(for: item, context: context))
            }
            return LogResult(message: "Logged \(count) items", target: object.base)
        }

        // ARO-0051: Fallback - check for AnyStreamingValue directly
        if let anyStreaming = context.resolveAny(result.base) as? AnyStreamingValue {
            let count = try await drainStream(anyStreaming.asStream()) { item in
                try write(line(for: item, context: context))
            }
            return LogResult(message: "Logged \(count) items", target: object.base)
        }

        // Get message to log
        // Priority:
        //   1. Metrics with format qualifier (ARO-0044)
        //   2. Result expression (ARO-0043 sink syntax: <Log> "message" to the <console>)
        //   3. With clause literal
        //   4. With clause expression
        //   5. Result variable
        //   6. Fallback to result fullName
        let message: String

        // ARO-0044: Check for metrics magic variable with format qualifier
        // <Log> the <metrics: plain/short/table/prometheus> to the <console>
        if result.base == "metrics" {
            if let metricsSnapshot = context.resolveAny("metrics") as? MetricsSnapshot {
                let format = result.specifiers.first ?? "plain"
                message = MetricsFormatter.format(metricsSnapshot, as: format, context: context.outputContext)
            } else {
                message = "No metrics available"
            }
        } else if let resultExpr = context.resolveAny("_result_expression_") {
            // ARO-0051: If the result expression resolved to a streaming value,
            // materialize it so Log formats it identically to the eager path.
            if let anyStreaming = resultExpr as? AnyStreamingValue, !anyStreaming.isMaterialized {
                let materialized = try await anyStreaming.materialize()
                message = ResponseFormatter.formatValue(materialized, for: context.outputContext)
            } else {
                // ARO-0043: Message from sink syntax result expression
                message = ResponseFormatter.formatValue(resultExpr, for: context.outputContext)
            }
        } else if let literal = context.resolveAny("_literal_") {
            // Message from "with" clause (string literal)
            message = ResponseFormatter.formatValue(literal, for: context.outputContext)
        } else if let expr = context.resolveAny("_expression_") {
            // Message from "with" clause (expression)
            message = ResponseFormatter.formatValue(expr, for: context.outputContext)
        } else if let anyStreaming = context.resolveAny(result.base) as? AnyStreamingValue, !anyStreaming.isMaterialized {
            // ARO-0051: Materialize lazy streaming value for consistent formatting
            let materialized = try await anyStreaming.materialize()
            message = ResponseFormatter.formatValue(materialized, for: context.outputContext)
        } else if var value = context.resolveAny(result.base) {
            // Apply specifiers (qualifiers) to the value
            // e.g., Log <numbers: reverse> applies the "reverse" qualifier
            for specifier in result.specifiers {
                // `raw` is an escaping directive for template output (#476), not a
                // value transform — applying it would warn about an unknown qualifier.
                if TemplateEscaping.isRawQualifier(specifier) { continue }
                // Apply qualifier; skip on failure (qualifier may not apply to this type)
                do {
                    value = try context.container.qualifierRegistry.resolve(specifier, value: value)
                } catch {
                    FileHandle.standardError.write(Data("[LogAction] Warning: qualifier '\(specifier)' failed: \(error.localizedDescription)\n".utf8))
                }
            }
            // Message from any variable type
            message = ResponseFormatter.formatValue(value, for: context.outputContext)
        } else if let value: String = context.resolve(result.base) {
            // Message from string variable (no specifiers)
            message = value
        } else {
            // Fallback to result name
            message = result.fullName
        }

        // Get log target (e.g., console, file, template)
        let target = object.base

        // ARO-0050: Check for template target
        // Syntax: <Print> "message" to the <template>.
        if target.lowercased() == "template" {
            // GitLab #476: escape by default for the template's format, so the safe
            // path is the short path. `<value: raw>` opts a single value out for
            // deliberate markup injection.
            // The opt-out is a qualifier on the *target*, not the value:
            // `Print <trusted> to the <template: raw>.` A qualifier on the value
            // (`<trusted: raw>`) cannot work — the expression evaluator resolves
            // result specifiers as qualifiers or property access, so `raw` would
            // fail as an undefined member before Log ever sees it. Target
            // qualifiers are also the established pattern here, matching
            // `<console: error>` for stream selection.
            let isRaw = object.specifiers.contains(where: { TemplateEscaping.isRawQualifier($0) })
            let escaped = isRaw ? message : context.templateEscaping.apply(to: message)

            // Append to template buffer instead of stdout/stderr
            context.appendToTemplateBuffer(escaped)
            return LogResult(message: escaped, target: target)
        }

        // Extract output stream qualifier (for console: stdout vs stderr)
        // Default to "output" (stdout) if no qualifier specified
        let outputStream: String
        if let qualifier = object.specifiers.first {
            outputStream = qualifier.lowercased()
        } else {
            outputStream = "output"  // default to stdout
        }

        // Try logging service
        if let loggingService = context.service(LoggingService.self) {
            await loggingService.log(message: message, target: target, level: .info)
            return LogResult(message: message, target: target)
        }

        // Fallback to print with context-aware formatting
        let formattedMessage: String
        switch context.outputContext {
        case .machine:
            // JSON format for machine consumption
            formattedMessage = "{\"level\":\"info\",\"source\":\"\(context.featureSetName)\",\"message\":\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
        case .human:
            // Readable format for CLI/console
            // Compiled binaries and stdin-pipe scripts get clean output
            // without the feature set prefix.
            if context.isCompiled || context.suppressLogPrefix {
                formattedMessage = message
            } else {
                formattedMessage = "[\(context.featureSetName)] \(message)"
            }
        case .developer:
            // Diagnostic format for testing/debugging
            formattedMessage = "LOG[\(target)] \(context.featureSetName): \(message)"
        }

        // Route output to appropriate stream based on target and qualifier.
        // Check if target is "stderr" (backward compatibility) OR qualifier is "error".
        let isError = target.lowercased() == "stderr" || outputStream == "error"
        if isError {
            // stderr path stays direct — it's only used by the CLI
            // and the user's terminal. An embedded host that wants
            // to capture stderr can install a `LoggingService` (the
            // branch above), which is the supported override seam.
            if let data = (formattedMessage + "\n").data(using: .utf8) {
                try FileHandle.standardError.write(contentsOf: data)
            }
        } else if let sink = ConsoleObject.sink {
            // SOLARO's embedded runtime installs a TaskLocal sink so
            // every `<Log "x" to <console>>` lands in the IDE console
            // panel instead of SOLARO's invisible process stdout.
            // Without this branch the user only saw the embedded
            // host's own start/end markers — no application output.
            sink(formattedMessage)
        } else {
            // Default CLI path: write to stdout using FileHandle for
            // immediate flush (`print()` uses full buffering when
            // piped, which loses output on Linux CI).
            if let data = (formattedMessage + "\n").data(using: .utf8) {
                try FileHandle.standardOutput.write(contentsOf: data)
            }
        }

        return LogResult(message: message, target: target)
    }

    // MARK: - Streaming

    /// Consume a stream element by element, handing each to `emit` as it
    /// arrives, and answer how many there were.
    ///
    /// A stream is logged rather than materialized precisely so a long one
    /// need not fit in memory. The two call sites differ only in where the
    /// stream came from, and each used to carry its own copy of this loop.
    private func drainStream<Element: Sendable>(
        _ stream: AROStream<Element>,
        emit: (Element) throws -> Void
    ) async throws -> Int {
        var count = 0
        for try await item in stream.stream {
            try emit(item)
            count += 1
        }
        return count
    }

    /// One line of streamed log output: the formatted value, prefixed with the
    /// feature set's name unless the caller owns the line already (compiled
    /// binaries and piped stdin).
    private func line(for value: any Sendable, context: ExecutionContext) -> String {
        let formatted = ResponseFormatter.formatValue(value, for: context.outputContext)
        if context.isCompiled || context.suppressLogPrefix {
            return formatted
        }
        return "[\(context.featureSetName)] \(formatted)"
    }

    /// Write one line to standard output.
    private func write(_ message: String) throws {
        if let data = (message + "\n").data(using: .utf8) {
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}

/// Logging service protocol
public protocol LoggingService: Sendable {
    func log(message: String, target: String, level: LogLevel) async
}

/// Log levels
public enum LogLevel: String, Sendable {
    case debug, info, warning, error
}

/// Result of a log operation
public struct LogResult: Sendable, Equatable {
    public let message: String
    public let target: String
}
