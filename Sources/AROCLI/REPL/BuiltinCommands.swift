// BuiltinCommands.swift
// ARO REPL Built-in Meta-Commands
//
// Implementation of all built-in REPL commands

import Foundation
import AROParser
import ARORuntime

// MARK: - Help Command

public struct HelpCommand: MetaCommand {
    public static let name = "help"
    public static let aliases = ["h", "?"]
    public static let help = "Show this help message"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        let helpText = """
        ARO REPL Commands:

        Session:
          :help, :h, :?           Show this help message
          :vars, :v               List all session variables
          :vars <name>            Show details of a specific variable
          :type <name>, :t        Show the type of a variable
          :clear, :c              Clear all session state
          :history, :hist         Show input history
          :history <n>            Show last n entries

        Feature Sets:
          :fs                     List defined feature sets
          :invoke <name>, :i      Invoke a feature set
          :invoke <name> <json>   Invoke with input data

        Data:
          :set <name> <value>     Set a variable to a value
          :load <file>            Load and execute a .aro file
          :export, :e             Print session as .aro code
          :export <file>          Save session to file
          :export --test <file>   Export as test file

        Control:
          :quit, :q, :exit        Exit the REPL

        Direct Mode:
          Type ARO statements directly, ending with .
          Example: <Set> the <x> to 42.

        Feature Set Definition:
          Start with (Name: Activity) {
          End with }
          Example:
            (Calculate Sum: Math) {
                <Compute> the <sum> from <a> + <b>.
                <Return> an <OK: status> with <sum>.
            }

        Keyboard Shortcuts:
          Up/Down                 Navigate history
          Ctrl+C                  Cancel current input
          Ctrl+D                  Exit REPL (on empty line)
        """
        return .output(helpText)
    }
}

// MARK: - Vars Command

public struct VarsCommand: MetaCommand {
    public static let name = "vars"
    public static let aliases = ["v", "variables"]
    public static let help = "List all variables in session"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        if let specificVar = args.first {
            // Show details of specific variable
            guard let value = session.getVariable(specificVar) else {
                return .output("Variable '\(specificVar)' not found")
            }
            let typeStr = typeName(of: value)
            let formatted = formatValue(value, indent: 2)
            return .output("""
            \(specificVar)
              Type:  \(typeStr)
              Value: \(formatted)
            """)
        }

        // List all variables
        let names = session.variableNames
        if names.isEmpty {
            return .output("No variables defined")
        }

        var table: [[String]] = [["Name", "Type", "Value"]]
        for name in names {
            if let value = session.getVariable(name) {
                let typeStr = typeName(of: value)
                let valueStr = truncate(formatValueShort(value), to: 40)
                table.append([name, typeStr, valueStr])
            }
        }
        return .table(table)
    }

    private func typeName(of value: any Sendable) -> String {
        switch value {
        case is String: return "String"
        case is Int: return "Integer"
        case is Double: return "Double"
        case is Bool: return "Boolean"
        case is [Any]: return "List"
        case is [String: Any]: return "Object"
        default: return String(describing: type(of: value))
        }
    }

    private func formatValue(_ value: any Sendable, indent: Int = 0) -> String {
        let indentStr = String(repeating: " ", count: indent)
        if let dict = value as? [String: any Sendable] {
            if dict.isEmpty { return "{}" }
            var lines = ["{"]
            for (key, val) in dict.sorted(by: { $0.key < $1.key }) {
                lines.append("\(indentStr)  \(key): \(formatValueShort(val))")
            }
            lines.append("\(indentStr)}")
            return lines.joined(separator: "\n")
        }
        if let array = value as? [any Sendable] {
            if array.isEmpty { return "[]" }
            let items = array.map { formatValueShort($0) }
            return "[\(items.joined(separator: ", "))]"
        }
        return formatValueShort(value)
    }

    private func formatValueShort(_ value: any Sendable) -> String {
        if let str = value as? String {
            return "\"\(str)\""
        }
        if let dict = value as? [String: any Sendable] {
            if dict.isEmpty { return "{}" }
            let preview = dict.keys.prefix(2).joined(separator: ", ")
            return "{ \(preview)\(dict.count > 2 ? ", ..." : "") }"
        }
        if let array = value as? [any Sendable] {
            return "[\(array.count) items]"
        }
        return String(describing: value)
    }

    private func truncate(_ s: String, to length: Int) -> String {
        if s.count <= length { return s }
        return String(s.prefix(length - 3)) + "..."
    }
}

// MARK: - Type Command

public struct TypeCommand: MetaCommand {
    public static let name = "type"
    public static let aliases = ["t"]
    public static let help = "Show the type of a variable"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        guard let name = args.first else {
            return .error("Usage: :type <variable-name>")
        }

        guard let value = session.getVariable(name) else {
            return .output("Variable '\(name)' not found")
        }

        let typeStr = detailedTypeName(of: value)
        return .output(typeStr)
    }

    private func detailedTypeName(of value: any Sendable) -> String {
        switch value {
        case is String: return "String"
        case is Int: return "Integer"
        case is Double: return "Double"
        case is Bool: return "Boolean"
        case let array as [any Sendable]:
            if array.isEmpty { return "List" }
            let elementType = detailedTypeName(of: array[0])
            return "List<\(elementType)>"
        case let dict as [String: any Sendable]:
            if dict.isEmpty { return "Object" }
            let fields = dict.map { "\($0.key): \(detailedTypeName(of: $0.value))" }
            return "Object { \(fields.joined(separator: ", ")) }"
        default:
            return String(describing: type(of: value))
        }
    }
}

// MARK: - Clear Command

public struct ClearCommand: MetaCommand {
    public static let name = "clear"
    public static let aliases = ["c", "reset"]
    public static let help = "Clear all session state"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        session.clear()
        return .output("Session cleared")
    }
}

// MARK: - History Command

public struct HistoryCommand: MetaCommand {
    public static let name = "history"
    public static let aliases = ["hist"]
    public static let help = "Show input history"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        let count = args.first.flatMap { Int($0) } ?? session.history.count
        let entries = session.history.suffix(count)

        if entries.isEmpty {
            return .output("No history")
        }

        var output = ""
        for (index, entry) in entries.enumerated() {
            let status: String
            if let result = entry.result {
                switch result {
                case .error: status = "[err]"
                case .ok, .value: status = "[ok] "
                default: status = "     "
                }
            } else {
                status = "[?]  "
            }

            let duration = entry.duration.map { String(format: "%.1fms", $0 * 1000) } ?? ""
            let input = truncate(entry.input, to: 50)
            output += "\(index + 1). \(status) \(input) \(duration)\n"
        }
        return .output(output.trimmingCharacters(in: .newlines))
    }

    private func truncate(_ s: String, to length: Int) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= length { return oneLine }
        return String(oneLine.prefix(length - 3)) + "..."
    }
}

// MARK: - FS Command

public struct FSCommand: MetaCommand {
    public static let name = "fs"
    public static let aliases = ["featuresets"]
    public static let help = "List defined feature sets"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        let names = session.featureSetNames

        if names.isEmpty {
            return .output("No feature sets defined")
        }

        var output = "Feature Sets:\n"
        for name in names {
            if let fs = session.featureSets[name] {
                output += "  - \(name) (\(fs.featureSet.businessActivity))\n"
            }
        }
        return .output(output.trimmingCharacters(in: .newlines))
    }
}

// MARK: - Invoke Command

public struct InvokeCommand: MetaCommand {
    public static let name = "invoke"
    public static let aliases = ["i", "run"]
    public static let help = "Invoke a feature set"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        guard !args.isEmpty else {
            return .error("Usage: :invoke <feature-set-name> [json-input]")
        }

        // Parse feature set name (may contain spaces)
        var name = ""
        var jsonStart = -1

        for (i, arg) in args.enumerated() {
            if arg.hasPrefix("{") || arg.hasPrefix("[") {
                jsonStart = i
                break
            }
            if !name.isEmpty { name += " " }
            name += arg
        }

        // Parse JSON input if provided
        var input: [String: any Sendable]? = nil
        if jsonStart >= 0 {
            let jsonStr = args[jsonStart...].joined(separator: " ")
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                input = json.mapValues { $0 as! any Sendable }
            } else {
                return .error("Invalid JSON input")
            }
        }

        let result = try await session.invokeFeatureSet(named: name, input: input)
        return convertResult(result)
    }

    private func convertResult(_ result: REPLResult) -> MetaCommandResult {
        switch result {
        case .value(let v):
            return .output("=> \(formatValue(v))")
        case .ok:
            return .output("=> OK")
        case .error(let msg):
            return .error(msg)
        default:
            return .none
        }
    }

    private func formatValue(_ value: any Sendable) -> String {
        if let str = value as? String {
            return "\"\(str)\""
        }
        if let dict = value as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
        }
        return String(describing: value)
    }
}

// MARK: - Set Command

public struct SetCommand: MetaCommand {
    public static let name = "set"
    public static let aliases: [String] = []
    public static let help = "Set a variable to a value"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        guard args.count >= 2 else {
            return .error("Usage: :set <name> <value>")
        }

        let name = args[0]
        let valueStr = args[1...].joined(separator: " ")

        // Try to parse as JSON
        if let data = valueStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            session.setVariable(name, value: json as! any Sendable)
            return .output("=> OK")
        }

        // Try to parse as number
        if let intVal = Int(valueStr) {
            session.setVariable(name, value: intVal)
            return .output("=> OK")
        }
        if let doubleVal = Double(valueStr) {
            session.setVariable(name, value: doubleVal)
            return .output("=> OK")
        }

        // Try to parse as boolean
        if valueStr.lowercased() == "true" {
            session.setVariable(name, value: true)
            return .output("=> OK")
        }
        if valueStr.lowercased() == "false" {
            session.setVariable(name, value: false)
            return .output("=> OK")
        }

        // Treat as string (remove quotes if present)
        var str = valueStr
        if str.hasPrefix("\"") && str.hasSuffix("\"") && str.count >= 2 {
            str = String(str.dropFirst().dropLast())
        }
        session.setVariable(name, value: str)
        return .output("=> OK")
    }
}

// MARK: - Export Command

public struct ExportCommand: MetaCommand {
    public static let name = "export"
    public static let aliases = ["e"]
    public static let help = "Export session as .aro file"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        let exporter = SessionExporter()

        var asTest = false
        var filename: String? = nil

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--test" {
                asTest = true
            } else if !arg.hasPrefix("-") {
                filename = arg
            }
            i += 1
        }

        let code: String
        if asTest {
            code = exporter.exportAsTest(session: session)
        } else {
            code = exporter.export(session: session)
        }

        if let filename = filename {
            do {
                try code.write(toFile: filename, atomically: true, encoding: .utf8)
                return .output("Exported to \(filename)")
            } catch {
                return .error("Failed to write file: \(error.localizedDescription)")
            }
        }

        return .output(code)
    }
}

// MARK: - Load Command

public struct LoadCommand: MetaCommand {
    public static let name = "load"
    public static let aliases: [String] = []
    public static let help = "Load and execute a .aro file"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        guard let filename = args.first else {
            return .error("Usage: :load <filename>")
        }

        let path = (filename as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: path) else {
            return .error("File not found: \(filename)")
        }

        do {
            let source = try String(contentsOfFile: path, encoding: .utf8)

            // Compile and load feature sets
            let compiler = Compiler()
            let result = compiler.compile(source)

            if !result.isSuccess {
                let errors = result.diagnostics.map { $0.message }.joined(separator: "\n")
                return .error("Compilation failed:\n\(errors)")
            }

            var loadedCount = 0
            for analyzedFS in result.analyzedProgram.featureSets {
                let name = analyzedFS.featureSet.name
                // Skip Application-Start/End handlers
                if name.hasPrefix("Application-") {
                    continue
                }
                session.addFeatureSet(name: name, featureSet: analyzedFS)
                loadedCount += 1
            }

            return .output("Loaded \(loadedCount) feature set(s) from \(filename)")
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }
    }
}

// MARK: - Quit Command

public struct QuitCommand: MetaCommand {
    public static let name = "quit"
    public static let aliases = ["q", "exit"]
    public static let help = "Exit the REPL"

    public init() {}

    public func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult {
        return .exit
    }
}
