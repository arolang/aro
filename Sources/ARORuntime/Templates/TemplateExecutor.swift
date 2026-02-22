// ============================================================
// TemplateExecutor.swift
// ARO Runtime - Template Executor (ARO-0050)
// ============================================================

import Foundation
import AROParser

/// Executes parsed templates to produce rendered output
public final class TemplateExecutor: @unchecked Sendable {
    // MARK: - Properties

    private let actionRegistry: ActionRegistry
    private let eventBus: EventBus
    private let globalSymbols: GlobalSymbolStorage
    private let compiler = Compiler()

    // MARK: - Initialization

    public init(
        actionRegistry: ActionRegistry,
        eventBus: EventBus
    ) {
        self.actionRegistry = actionRegistry
        self.eventBus = eventBus
        // Templates use their own isolated GlobalSymbolStorage since they don't publish variables
        self.globalSymbols = GlobalSymbolStorage()
    }

    // MARK: - Rendering

    /// Render a parsed template with the given context
    /// - Parameters:
    ///   - template: The parsed template
    ///   - context: The parent execution context
    ///   - templateService: The template service for nested includes
    /// - Returns: The rendered template content
    public func render(
        template: ParsedTemplate,
        context: ExecutionContext,
        templateService: TemplateService
    ) async throws -> String {
        // Create isolated template context
        guard let runtimeContext = context as? RuntimeContext else {
            throw TemplateError.renderError(path: template.path, message: "Invalid context type")
        }

        let templateContext = runtimeContext.createTemplateContext()

        // Register the template service for nested includes
        templateContext.register(templateService)

        // Inject terminal object (ARO-0052)
        if let terminalService = context.service(TerminalService.self) {
            let capabilities = await terminalService.detectCapabilities()
            let terminalObject: [String: any Sendable] = [
                "rows": capabilities.rows,
                "columns": capabilities.columns,
                "width": capabilities.columns,  // alias
                "height": capabilities.rows,    // alias
                "supports_color": capabilities.supportsColor,
                "supports_true_color": capabilities.supportsTrueColor,
                "is_tty": capabilities.isTTY,
                "encoding": capabilities.encoding
            ]
            templateContext.bind("terminal", value: terminalObject)
        }

        // Process segments
        var output = ""

        var index = 0
        while index < template.segments.count {
            let segment = template.segments[index]

            switch segment {
            case .staticText(let text):
                output += text
                index += 1

            case .expressionShorthand(let expression):
                let (value, filters) = try await evaluateExpressionWithFilters(expression, context: templateContext)
                output += await applyFilters(formatValue(value), filters: filters, context: templateContext)
                index += 1

            case .statements(let statementsSource):
                try await executeStatements(statementsSource, context: templateContext, templatePath: template.path)
                output += templateContext.flushTemplateBuffer()
                index += 1

            case .forEachOpen(let config):
                // Find the matching close
                let (loopBody, closeIndex) = try extractForEachBody(
                    segments: template.segments,
                    startIndex: index + 1
                )

                // Execute the loop
                let loopOutput = try await executeForEachLoop(
                    config: config,
                    body: loopBody,
                    context: templateContext,
                    templateService: templateService,
                    templatePath: template.path
                )
                output += loopOutput
                index = closeIndex + 1

            case .forEachClose:
                // This should not be reached directly; it's handled by forEachOpen
                throw TemplateError.renderError(path: template.path, message: "Unexpected for-each close")
            }
        }

        return output
    }

    // MARK: - Expression Evaluation

    /// Evaluate an expression with optional filters: <expr | filter: "arg">
    private func evaluateExpressionWithFilters(
        _ expression: String,
        context: ExecutionContext
    ) async throws -> (Any, [(name: String, arg: String?)]) {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)

        // Check for filter syntax: <expr> | filter: "arg"
        // Need to find pipe outside of angle brackets
        if let pipeIndex = findPipeOutsideBrackets(trimmed) {
            let exprPart = String(trimmed[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
            let filterPart = String(trimmed[trimmed.index(after: pipeIndex)...]).trimmingCharacters(in: .whitespaces)

            let value = try await evaluateExpression(exprPart, context: context)
            let filters = parseFilters(filterPart)
            return (value, filters)
        }

        // No filters
        let value = try await evaluateExpression(trimmed, context: context)
        return (value, [])
    }

    /// Find pipe character outside of angle brackets
    private func findPipeOutsideBrackets(_ str: String) -> String.Index? {
        var depth = 0
        for (index, char) in zip(str.indices, str) {
            if char == "<" { depth += 1 }
            else if char == ">" { depth -= 1 }
            else if char == "|" && depth == 0 { return index }
        }
        return nil
    }

    /// Parse filter chain: filter1: "arg1" | filter2
    private func parseFilters(_ filterStr: String) -> [(name: String, arg: String?)] {
        var filters: [(name: String, arg: String?)] = []

        // Split by pipe for chained filters
        let parts = filterStr.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts where !part.isEmpty {
            // Parse: filterName: "arg" or filterName
            if let colonIndex = part.firstIndex(of: ":") {
                let name = String(part[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                var arg = String(part[part.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                // Remove quotes from argument
                if arg.hasPrefix("\"") && arg.hasSuffix("\"") {
                    arg = String(arg.dropFirst().dropLast())
                }

                filters.append((name: name, arg: arg))
            } else {
                filters.append((name: part, arg: nil))
            }
        }

        return filters
    }

    /// Apply filters to a formatted value
    private func applyFilters(_ value: String, filters: [(name: String, arg: String?)], context: ExecutionContext) async -> String {
        var result = value

        for filter in filters {
            switch filter.name {
            case "date":
                result = formatDate(result, format: filter.arg ?? "dd.MM.yyyy HH:mm")
            case "uppercase":
                result = result.uppercased()
            case "lowercase":
                result = result.lowercased()

            // Terminal color filters (ARO-0052)
            case "color":
                if let colorName = filter.arg {
                    let caps = await getTerminalCapabilities(from: context)
                    result = ANSIRenderer.color(colorName, capabilities: caps) + result + ANSIRenderer.reset()
                }
            case "bg":
                if let colorName = filter.arg {
                    let caps = await getTerminalCapabilities(from: context)
                    result = ANSIRenderer.backgroundColor(colorName, capabilities: caps) + result + ANSIRenderer.reset()
                }

            // Terminal style filters (ARO-0052)
            case "bold":
                result = ANSIRenderer.bold() + result + ANSIRenderer.reset()
            case "dim":
                result = ANSIRenderer.dim() + result + ANSIRenderer.reset()
            case "italic":
                result = ANSIRenderer.italic() + result + ANSIRenderer.reset()
            case "underline":
                result = ANSIRenderer.underline() + result + ANSIRenderer.reset()
            case "strikethrough":
                result = ANSIRenderer.strikethrough() + result + ANSIRenderer.reset()

            default:
                break
            }
        }

        return result
    }

    /// Get terminal capabilities from execution context (ARO-0052)
    private func getTerminalCapabilities(from context: ExecutionContext) async -> Capabilities {
        if let terminalService = context.service(TerminalService.self) {
            return await terminalService.detectCapabilities()
        }

        // Safe defaults for non-TTY environments
        return Capabilities(
            rows: 24,
            columns: 80,
            supportsColor: false,
            supportsTrueColor: false,
            supportsUnicode: true,
            isTTY: false,
            encoding: "UTF-8"
        )
    }

    /// Format an ISO date string to a custom format
    private func formatDate(_ isoString: String, format: String) -> String {
        // Parse ISO 8601 date
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var date = isoFormatter.date(from: isoString)
        if date == nil {
            // Try without fractional seconds
            isoFormatter.formatOptions = [.withInternetDateTime]
            date = isoFormatter.date(from: isoString)
        }

        guard let parsedDate = date else {
            return isoString // Return original if parsing fails
        }

        // Format to desired output
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = convertToDateFormat(format)
        outputFormatter.timeZone = TimeZone(identifier: "UTC")

        return outputFormatter.string(from: parsedDate)
    }

    /// Convert user-friendly format to DateFormatter format
    private func convertToDateFormat(_ format: String) -> String {
        // The format string uses standard DateFormatter patterns
        // dd = day, MM = month, yyyy = year, HH = hour, mm = minute, ss = second
        return format
    }

    /// Evaluate an expression shorthand and return its value
    private func evaluateExpression(_ expression: String, context: ExecutionContext) async throws -> Any {
        // Parse the expression: <variable> or <variable: property> or <a> ++ <b>
        let trimmed = expression.trimmingCharacters(in: .whitespaces)

        // Check for operators (concatenation, arithmetic)
        if trimmed.contains(" ++ ") {
            return try await evaluateConcatenation(trimmed, context: context)
        }

        if trimmed.contains(" * ") || trimmed.contains(" + ") ||
           trimmed.contains(" - ") || trimmed.contains(" / ") {
            return try await evaluateArithmetic(trimmed, context: context)
        }

        // Simple variable reference: <variable> or <variable: property>
        return try resolveVariableExpression(trimmed, context: context)
    }

    /// Evaluate concatenation expression: <a> ++ <b> ++ "literal"
    private func evaluateConcatenation(_ expression: String, context: ExecutionContext) async throws -> String {
        let parts = expression.components(separatedBy: " ++ ")
        var result = ""

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
                // String literal
                result += String(trimmed.dropFirst().dropLast())
            } else if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
                // Variable reference
                let value = try resolveVariableExpression(trimmed, context: context)
                result += formatValue(value)
            } else {
                // Literal text
                result += trimmed
            }
        }

        return result
    }

    /// Evaluate arithmetic expression
    private func evaluateArithmetic(_ expression: String, context: ExecutionContext) async throws -> Any {
        // This is a simplified implementation - for full arithmetic, we'd use ExpressionEvaluator
        // For now, handle simple binary operations

        let operators = [" * ", " + ", " - ", " / "]

        for op in operators {
            if let range = expression.range(of: op) {
                let leftStr = String(expression[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rightStr = String(expression[range.upperBound...]).trimmingCharacters(in: .whitespaces)

                let left = try resolveNumericValue(leftStr, context: context)
                let right = try resolveNumericValue(rightStr, context: context)

                switch op.trimmingCharacters(in: .whitespaces) {
                case "*": return left * right
                case "+": return left + right
                case "-": return left - right
                case "/": return right != 0 ? left / right : 0
                default: break
                }
            }
        }

        // Fallback to variable resolution
        return try resolveVariableExpression(expression, context: context)
    }

    /// Resolve a numeric value from expression or literal
    private func resolveNumericValue(_ expression: String, context: ExecutionContext) throws -> Double {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)

        // Try parsing as number literal
        if let number = Double(trimmed) {
            return number
        }

        // Try resolving as variable
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            let value = try resolveVariableExpression(trimmed, context: context)
            if let num = value as? Double { return num }
            if let num = value as? Int { return Double(num) }
            if let str = value as? String, let num = Double(str) { return num }
        }

        throw TemplateError.renderError(path: "", message: "Cannot convert '\(trimmed)' to number")
    }

    /// Resolve a variable expression: <variable> or <variable: property>
    private func resolveVariableExpression(_ expression: String, context: ExecutionContext) throws -> Any {
        var trimmed = expression.trimmingCharacters(in: .whitespaces)

        // Remove angle brackets if present
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }

        // Check for qualified name: variable: property
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                let baseName = parts[0]
                let propertyPath = parts[1]

                // Resolve the base variable
                guard let baseValue = context.resolveAny(baseName) else {
                    throw TemplateError.renderError(path: "", message: "Variable '\(baseName)' is not defined")
                }

                // Navigate the property path
                return try resolvePropertyPath(baseValue, path: propertyPath)
            }
        }

        // Simple variable resolution
        guard let value = context.resolveAny(trimmed) else {
            throw TemplateError.renderError(path: "", message: "Variable '\(trimmed)' is not defined")
        }

        return value
    }

    /// Resolve a property path on an object
    private func resolvePropertyPath(_ value: Any, path: String) throws -> Any {
        // Unwrap AnySendableWrapper if present
        var unwrapped = value
        if let wrapper = value as? AnySendableWrapper {
            unwrapped = wrapper.value
        }

        // Handle dictionary-like objects
        if let dict = unwrapped as? [String: Any] {
            // Split path by ":" for nested access
            let parts = path.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
            var current: Any = dict

            for part in parts {
                if let currentDict = current as? [String: Any], let next = currentDict[part] {
                    current = next
                } else if let currentDict = current as? [String: any Sendable], let next = currentDict[part] {
                    current = next
                } else {
                    throw TemplateError.renderError(path: "", message: "Property '\(part)' not found")
                }
            }

            return current
        }

        // Handle other types by trying to access as dictionary
        if let sendableDict = value as? [String: any Sendable], let result = sendableDict[path] {
            return result
        }

        throw TemplateError.renderError(path: "", message: "Cannot access property '\(path)' on value")
    }

    // MARK: - Statement Execution

    /// Execute ARO statements from template
    private func executeStatements(
        _ source: String,
        context: ExecutionContext,
        templatePath: String
    ) async throws {
        // Wrap statements in a temporary feature set for parsing
        let wrappedSource = """
        (Template Execution: Template) {
            \(source)
        }
        """

        // Compile the statements
        let result = compiler.compile(wrappedSource)

        if result.hasErrors {
            let errorMessages = result.diagnostics.filter { $0.severity == .error }.map { $0.message }
            throw TemplateError.renderError(
                path: templatePath,
                message: "Statement compilation error: \(errorMessages.joined(separator: "; "))"
            )
        }

        guard let featureSet = result.analyzedProgram.featureSets.first else {
            throw TemplateError.renderError(path: templatePath, message: "No statements to execute")
        }

        // Create executor for the statements
        let executor = FeatureSetExecutor(
            actionRegistry: actionRegistry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        // Execute the feature set
        _ = try await executor.execute(featureSet, context: context)
    }

    // MARK: - For-Each Loop

    /// Extract the body segments of a for-each loop
    private func extractForEachBody(
        segments: [TemplateSegment],
        startIndex: Int
    ) throws -> (body: [TemplateSegment], closeIndex: Int) {
        var depth = 1
        var index = startIndex
        var body: [TemplateSegment] = []

        while index < segments.count {
            let segment = segments[index]

            switch segment {
            case .forEachOpen:
                depth += 1
                body.append(segment)
            case .forEachClose:
                depth -= 1
                if depth == 0 {
                    return (body, index)
                }
                body.append(segment)
            default:
                body.append(segment)
            }

            index += 1
        }

        throw TemplateError.renderError(path: "", message: "Unclosed for-each loop")
    }

    /// Execute a for-each loop over a collection
    private func executeForEachLoop(
        config: ForEachConfig,
        body: [TemplateSegment],
        context: ExecutionContext,
        templateService: TemplateService,
        templatePath: String
    ) async throws -> String {
        // Resolve the collection
        let collection = try resolveVariableExpression("<\(config.collection)>", context: context)

        // Convert to array
        guard let items = collection as? [Any] else {
            if let sendableItems = collection as? [any Sendable] {
                return try await executeForEachOverItems(
                    items: sendableItems,
                    config: config,
                    body: body,
                    context: context,
                    templateService: templateService,
                    templatePath: templatePath
                )
            }
            throw TemplateError.renderError(
                path: templatePath,
                message: "For-each collection '\(config.collection)' is not iterable"
            )
        }

        return try await executeForEachOverItems(
            items: items,
            config: config,
            body: body,
            context: context,
            templateService: templateService,
            templatePath: templatePath
        )
    }

    private func executeForEachOverItems(
        items: [Any],
        config: ForEachConfig,
        body: [TemplateSegment],
        context: ExecutionContext,
        templateService: TemplateService,
        templatePath: String
    ) async throws -> String {
        var output = ""

        for (index, item) in items.enumerated() {
            // Create child context for this iteration
            guard let runtimeContext = context as? RuntimeContext else {
                throw TemplateError.renderError(path: templatePath, message: "Invalid context type")
            }

            let iterationContext = runtimeContext.createTemplateContext()

            // Bind the item variable
            // Note: item is already Any, we wrap it for Sendable compatibility
            iterationContext.bind(config.itemVariable, value: AnySendableWrapper(item), allowRebind: true)

            // Bind the index variable if specified
            if let indexVar = config.indexVariable {
                iterationContext.bind(indexVar, value: index, allowRebind: true)
            }

            // Register template service for nested includes
            iterationContext.register(templateService)

            // Create a sub-template with the body segments
            let bodyTemplate = ParsedTemplate(path: templatePath, segments: body)

            // Render the body
            output += try await render(template: bodyTemplate, context: iterationContext, templateService: templateService)
        }

        return output
    }

    // MARK: - Formatting

    /// Format a value for output
    private func formatValue(_ value: Any) -> String {
        // Unwrap AnySendableWrapper if present
        let unwrapped: Any
        if let wrapper = value as? AnySendableWrapper {
            unwrapped = wrapper.value
        } else {
            unwrapped = value
        }

        if let string = unwrapped as? String {
            return string
        }
        if let number = unwrapped as? Int {
            return String(number)
        }
        if let number = unwrapped as? Double {
            // Format nicely (remove trailing .0)
            if number == Double(Int(number)) {
                return String(Int(number))
            }
            return String(number)
        }
        if let bool = unwrapped as? Bool {
            return bool ? "true" : "false"
        }
        return String(describing: unwrapped)
    }
}

// MARK: - Sendable Wrapper

/// Wrapper to make Any values Sendable for template context binding
/// This is needed because template loop items come from Any arrays
/// but ExecutionContext.bind requires Sendable values.
public struct AnySendableWrapper: @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }
}
