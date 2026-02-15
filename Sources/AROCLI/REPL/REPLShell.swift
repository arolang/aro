// REPLShell.swift
// ARO REPL Main Shell
//
// The main Read-Eval-Print Loop implementation

import Foundation
import AROVersion
import LineNoise

/// The main REPL shell
public final class REPLShell: @unchecked Sendable {
    private let session: REPLSession
    private let commandRegistry: MetaCommandRegistry
    private let lineNoise: LineNoise?

    private var multilineBuffer: String = ""
    private var isRunning = true

    /// Whether to use colors in output
    public var useColors: Bool = true

    /// History file path
    private let historyPath: String

    /// Whether we're running in interactive mode (TTY)
    private let isInteractive: Bool

    public init() {
        self.session = REPLSession()
        self.commandRegistry = MetaCommandRegistry.shared

        // Check if we're in an interactive terminal
        self.isInteractive = isatty(STDIN_FILENO) != 0

        // Set up history file
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let aroDir = "\(homeDir)/.aro"
        self.historyPath = "\(aroDir)/repl_history"

        // Only use LineNoise in interactive mode
        if isInteractive {
            let ln = LineNoise()

            // Create .aro directory if needed
            try? FileManager.default.createDirectory(atPath: aroDir, withIntermediateDirectories: true)

            // Load history
            try? ln.loadHistory(fromFile: historyPath)

            // Set history limit
            ln.setHistoryMaxLength(1000)

            self.lineNoise = ln
        } else {
            self.lineNoise = nil
        }
    }

    /// Run the REPL
    public func run() async {
        printWelcome()
        setupSignalHandlers()
        setupCompletion()

        while isRunning {
            let prompt = getPrompt()

            guard let line = readLine(prompt: prompt) else {
                // EOF (Ctrl+D)
                if multilineBuffer.isEmpty && !isInFeatureSetMode() {
                    print("\nGoodbye!")
                    break
                } else {
                    // Cancel multiline input or feature set mode
                    multilineBuffer = ""
                    if case .featureSetDefinition = session.mode {
                        session.mode = .direct
                        print("\nFeature set definition cancelled")
                    } else {
                        print()
                    }
                    continue
                }
            }

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // In feature set mode, handle specially
            if case .featureSetDefinition(let name, let activity, var statements) = session.mode {
                if trimmedLine == "}" {
                    // End of feature set
                    session.mode = .direct
                    do {
                        let result = try await session.defineFeatureSet(name: name, activity: activity, statements: statements)
                        printResult(result)
                    } catch {
                        printError(String(describing: error))
                    }
                } else if !trimmedLine.isEmpty {
                    // Add statement to feature set
                    statements.append(trimmedLine)
                    session.mode = .featureSetDefinition(name: name, activity: activity, statements: statements)
                    print(colorize("  +", .dim))
                }
                continue
            }

            // Check if this line starts a feature set
            if MultilineDetector.isFeatureSetStart(trimmedLine) {
                if let (name, activity) = MultilineDetector.parseFeatureSetHeader(trimmedLine) {
                    session.mode = .featureSetDefinition(name: name, activity: activity, statements: [])
                    print(colorize("Defining feature set: \(name)", .yellow))
                    continue
                }
            }

            // Handle multiline input for regular statements
            if !multilineBuffer.isEmpty {
                multilineBuffer += "\n" + line
            } else {
                multilineBuffer = line
            }

            // Check if input is complete
            let completionStatus = MultilineDetector.check(multilineBuffer)
            switch completionStatus {
            case .needsMore:
                continue
            case .error(let msg):
                printError(msg)
                multilineBuffer = ""
                continue
            case .complete:
                break
            }

            // Process complete input
            let input = multilineBuffer
            multilineBuffer = ""

            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }

            await processInput(trimmed)
        }
    }

    /// Check if we're in feature set definition mode
    private func isInFeatureSetMode() -> Bool {
        if case .featureSetDefinition = session.mode {
            return true
        }
        return false
    }

    /// Process a complete input line or block
    private func processInput(_ input: String) async {
        do {
            let result = try await evaluate(input)
            printResult(result)

            if case .exit = result {
                isRunning = false
            }
        } catch {
            printError(String(describing: error))
        }
    }

    /// Evaluate input and return result
    private func evaluate(_ input: String) async throws -> REPLResult {
        // Meta-command
        if input.hasPrefix(":") {
            let cmdResult = try await commandRegistry.execute(input: input, session: session)
            return convertCommandResult(cmdResult)
        }

        // Check if this looks like an expression (no angle brackets at start)
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if !trimmed.hasPrefix("<") && !trimmed.hasPrefix("(") {
            // Try as expression
            if isSimpleExpression(trimmed) {
                return try await session.evaluateExpression(trimmed)
            }
        }

        // Direct statement execution
        return try await session.executeStatement(input)
    }

    /// Check if input looks like a simple expression
    private func isSimpleExpression(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // Must not start with < (that's a statement)
        if trimmed.hasPrefix("<") { return false }

        // Must not start with ( followed by name: (that's a feature set)
        if trimmed.hasPrefix("(") && trimmed.contains(":") { return false }

        // Simple numeric expression
        if trimmed.first?.isNumber == true { return true }

        // String literal
        if trimmed.hasPrefix("\"") { return true }

        // Variable reference without angle brackets
        // This is tricky - we'll be conservative
        return false
    }

    /// Convert MetaCommandResult to REPLResult
    private func convertCommandResult(_ result: MetaCommandResult) -> REPLResult {
        switch result {
        case .output(let text):
            return .commandOutput(text)
        case .table(let rows):
            return .table(rows)
        case .clear:
            return .ok
        case .exit:
            return .exit
        case .none:
            return .ok
        case .error(let msg):
            return .error(msg)
        }
    }

    /// Get the current prompt
    private func getPrompt() -> String {
        switch session.mode {
        case .direct:
            if multilineBuffer.isEmpty {
                return colorize("aro> ", .cyan)
            } else {
                return colorize("...> ", .cyan)
            }
        case .featureSetDefinition(let name, _, _):
            let shortName = name.prefix(20)
            return colorize("(\(shortName))> ", .yellow)
        }
    }

    /// Print welcome message
    private func printWelcome() {
        print(colorize("ARO REPL", .bold) + " v\(AROVersion.shortVersion)")
        print("Type " + colorize(":help", .cyan) + " for commands, " + colorize(":quit", .cyan) + " to exit")
        print()
    }

    /// Print a result
    private func printResult(_ result: REPLResult) {
        switch result {
        case .value(let v):
            print(colorize("=> ", .green) + formatValue(v))
        case .ok:
            print(colorize("=> OK", .green))
        case .featureSetStarted(let name):
            print(colorize("Defining feature set: \(name)", .yellow))
        case .featureSetDefined(let name):
            print(colorize("Feature set '\(name)' defined", .green))
        case .statementAdded:
            print(colorize("  +", .dim))
        case .commandOutput(let text):
            print(text)
        case .table(let rows):
            printTable(rows)
        case .exit:
            print("Goodbye!")
        case .error(let msg):
            printError(msg)
        }
    }

    /// Print an error
    private func printError(_ message: String) {
        print(colorize("Error: ", .red) + message)
    }

    /// Print a table
    private func printTable(_ rows: [[String]]) {
        guard !rows.isEmpty else { return }

        // Calculate column widths
        let colCount = rows.map { $0.count }.max() ?? 0
        var widths = Array(repeating: 0, count: colCount)

        for row in rows {
            for (i, cell) in row.enumerated() where i < colCount {
                widths[i] = max(widths[i], cell.count)
            }
        }

        // Print header
        if let header = rows.first {
            let headerLine = formatTableRow(header, widths: widths)
            print(colorize(headerLine, .bold))

            // Print separator
            let separator = widths.map { String(repeating: "-", count: $0) }.joined(separator: " | ")
            print(separator)
        }

        // Print data rows
        for row in rows.dropFirst() {
            print(formatTableRow(row, widths: widths))
        }
    }

    /// Format a table row
    private func formatTableRow(_ row: [String], widths: [Int]) -> String {
        var cells: [String] = []
        for (i, cell) in row.enumerated() {
            let width = i < widths.count ? widths[i] : cell.count
            cells.append(cell.padding(toLength: width, withPad: " ", startingAt: 0))
        }
        return cells.joined(separator: " | ")
    }

    /// Format a value for display
    private func formatValue(_ value: any Sendable) -> String {
        if let str = value as? String {
            return colorize("\"\(str)\"", .green)
        }
        if let num = value as? Int {
            return colorize(String(num), .cyan)
        }
        if let num = value as? Double {
            return colorize(String(num), .cyan)
        }
        if let bool = value as? Bool {
            return colorize(String(bool), .magenta)
        }
        if let dict = value as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
        }
        if let array = value as? [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted]),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
        }
        return String(describing: value)
    }

    /// Read a line with prompt
    private func readLine(prompt: String) -> String? {
        // Use LineNoise for interactive mode, simple readLine for piped input
        if let ln = lineNoise {
            do {
                let line = try ln.getLine(prompt: prompt)
                // Add non-empty lines to history
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    ln.addHistory(line)
                    // Save history periodically
                    try? ln.saveHistory(toFile: historyPath)
                }
                return line
            } catch LinenoiseError.CTRL_C {
                // User pressed Ctrl+C
                print("^C")
                return ""
            } catch LinenoiseError.EOF {
                // User pressed Ctrl+D
                return nil
            } catch {
                return nil
            }
        } else {
            // Non-interactive mode: use simple readLine
            print(prompt, terminator: "")
            fflush(stdout)
            return Swift.readLine()
        }
    }

    /// Setup signal handlers
    private func setupSignalHandlers() {
        // LineNoise handles Ctrl+C internally
        // We just need to handle SIGINT for graceful shutdown
        signal(SIGINT, SIG_IGN)
    }

    /// Setup tab completion
    private func setupCompletion() {
        guard let ln = lineNoise else { return }

        ln.setCompletionCallback { currentBuffer in
            var completions: [String] = []
            let trimmed = currentBuffer.trimmingCharacters(in: .whitespaces)

            // Complete meta-commands
            if trimmed.hasPrefix(":") {
                let partial = String(trimmed.dropFirst()).lowercased()
                for name in self.commandRegistry.commandNames {
                    if name.lowercased().hasPrefix(partial) {
                        completions.append(":\(name)")
                    }
                }
            }

            return completions
        }
    }

    // MARK: - Color Support

    private enum ANSIColor {
        case red, green, yellow, blue, magenta, cyan, white
        case bold, dim, reset

        var code: String {
            switch self {
            case .red: return "\u{001B}[31m"
            case .green: return "\u{001B}[32m"
            case .yellow: return "\u{001B}[33m"
            case .blue: return "\u{001B}[34m"
            case .magenta: return "\u{001B}[35m"
            case .cyan: return "\u{001B}[36m"
            case .white: return "\u{001B}[37m"
            case .bold: return "\u{001B}[1m"
            case .dim: return "\u{001B}[2m"
            case .reset: return "\u{001B}[0m"
            }
        }
    }

    private func colorize(_ text: String, _ color: ANSIColor) -> String {
        guard useColors && isatty(STDOUT_FILENO) != 0 else {
            return text
        }
        return "\(color.code)\(text)\(ANSIColor.reset.code)"
    }
}
