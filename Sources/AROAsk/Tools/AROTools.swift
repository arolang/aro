// AROAsk - tools for invoking the aro toolchain and parser

import Foundation
import AROParser
import ARORuntime

/// Tools that let the coding assistant invoke the ARO compiler and runtime.
public enum AROTools {

    // MARK: - Binary resolution

    private static func aroBinary() -> String {
        let args = CommandLine.arguments
        if let first = args.first, first.hasSuffix("/aro") || first == "aro" {
            return first.hasPrefix("/") ? first : (ProcessRunner.which("aro") ?? first)
        }
        return ProcessRunner.which("aro") ?? "aro"
    }

    // MARK: - aro_check

    public static func aroCheck(guard pathGuard: PathGuard) -> AskToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to a .aro file or application directory to check")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        return AskToolDescriptor(
            name: "aro_check",
            description: "Run `aro check` on a file or directory to validate ARO syntax without executing.",
            parameters: params
        ) { args in
            guard let path = args["path"]?.stringValue else {
                throw AskToolError.invalidArguments("missing 'path'")
            }
            let resolved = try pathGuard.resolve(path)
            let binary = aroBinary()
            let result = try ProcessRunner.runAndCapture(
                executable: binary,
                arguments: ["check", resolved.path],
                timeout: 30
            )
            var output = ""
            if !result.stdout.isEmpty { output += result.stdout }
            if !result.stderr.isEmpty { output += result.stderr }
            if output.isEmpty {
                output = result.exitCode == 0 ? "Check passed." : "Check failed (exit \(result.exitCode))."
            }
            return output
        }
    }

    // MARK: - aro_run

    public static func aroRun(guard pathGuard: PathGuard) -> AskToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the ARO application directory to run")
                ]),
                "args": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Additional arguments to pass to aro run (optional)")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        return AskToolDescriptor(
            name: "aro_run",
            description: "Run an ARO application with `aro run`. Returns stdout/stderr. Times out after 30 seconds.",
            parameters: params,
            requiresApproval: true
        ) { args in
            guard let path = args["path"]?.stringValue else {
                throw AskToolError.invalidArguments("missing 'path'")
            }
            let resolved = try pathGuard.resolve(path)
            let extraArgs = args["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let binary = aroBinary()
            var arguments = ["run", resolved.path]
            arguments.append(contentsOf: extraArgs)
            let result = try ProcessRunner.runAndCapture(
                executable: binary,
                arguments: arguments,
                timeout: 30
            )
            var output = ""
            if !result.stdout.isEmpty { output += result.stdout }
            if !result.stderr.isEmpty {
                if !output.isEmpty { output += "\n" }
                output += result.stderr
            }
            if output.isEmpty {
                output = result.exitCode == 0 ? "Completed successfully." : "Failed (exit \(result.exitCode))."
            }
            return output
        }
    }

    // MARK: - aro_test

    public static func aroTest(guard pathGuard: PathGuard) -> AskToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the ARO application directory to test")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        return AskToolDescriptor(
            name: "aro_test",
            description: "Run `aro test` on an ARO application directory and return test results.",
            parameters: params
        ) { args in
            guard let path = args["path"]?.stringValue else {
                throw AskToolError.invalidArguments("missing 'path'")
            }
            let resolved = try pathGuard.resolve(path)
            let binary = aroBinary()
            let result = try ProcessRunner.runAndCapture(
                executable: binary,
                arguments: ["test", resolved.path],
                timeout: 60
            )
            var output = ""
            if !result.stdout.isEmpty { output += result.stdout }
            if !result.stderr.isEmpty {
                if !output.isEmpty { output += "\n" }
                output += result.stderr
            }
            if output.isEmpty {
                output = result.exitCode == 0 ? "All tests passed." : "Tests failed (exit \(result.exitCode))."
            }
            return output
        }
    }

    // MARK: - aro_build

    public static func aroBuild(guard pathGuard: PathGuard) -> AskToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the ARO application directory to compile to a native binary")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        return AskToolDescriptor(
            name: "aro_build",
            description: "Compile an ARO application to a native binary with `aro build`. Returns compiler output.",
            parameters: params,
            requiresApproval: true
        ) { args in
            guard let path = args["path"]?.stringValue else {
                throw AskToolError.invalidArguments("missing 'path'")
            }
            let resolved = try pathGuard.resolve(path)
            let binary = aroBinary()
            let result = try ProcessRunner.runAndCapture(
                executable: binary,
                arguments: ["build", resolved.path],
                timeout: 120
            )
            var output = ""
            if !result.stdout.isEmpty { output += result.stdout }
            if !result.stderr.isEmpty {
                if !output.isEmpty { output += "\n" }
                output += result.stderr
            }
            if output.isEmpty {
                output = result.exitCode == 0 ? "Build succeeded." : "Build failed (exit \(result.exitCode))."
            }
            return output
        }
    }

    // MARK: - parse_aro

    public static func parseARO(guard pathGuard: PathGuard) -> AskToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to a .aro file to parse and return the AST for")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        return AskToolDescriptor(
            name: "parse_aro",
            description: "Parse a .aro file and return the AST as structured text. Useful for inspecting syntax without running.",
            parameters: params
        ) { args in
            guard let path = args["path"]?.stringValue else {
                throw AskToolError.invalidArguments("missing 'path'")
            }
            let resolved = try pathGuard.resolve(path)
            let source = try String(contentsOf: resolved, encoding: .utf8)

            let compiler = Compiler()
            let result = compiler.compile(source)

            if result.hasErrors {
                let errors = result.diagnostics
                    .filter { $0.severity == .error }
                    .map { "  \($0)" }
                    .joined(separator: "\n")
                return "Parse errors:\n\(errors)"
            }

            let program = result.program
            var lines: [String] = ["Program: \(program.featureSets.count) feature set(s)"]

            for fs in program.featureSets {
                lines.append("")
                lines.append("  (\(fs.name): \(fs.businessActivity))")
                for (i, stmt) in fs.statements.enumerated() {
                    lines.append("    [\(i + 1)] \(stmt.description)")
                }
            }

            if !result.diagnostics.isEmpty {
                lines.append("")
                lines.append("Diagnostics:")
                for d in result.diagnostics {
                    lines.append("  \(d)")
                }
            }

            return lines.joined(separator: "\n")
        }
    }

    // MARK: - list_actions

    public static func listActions() -> AskToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        return AskToolDescriptor(
            name: "list_actions",
            description: "List all available ARO actions with their verbs, roles, and valid prepositions.",
            parameters: params
        ) { _ in
            let registry = ActionRegistry.shared
            let byRole = await registry.actionsByRole

            var lines: [String] = []
            let roleOrder: [ActionRole] = [.request, .own, .response, .export, .server]
            for role in roleOrder {
                guard let verbs = byRole[role], !verbs.isEmpty else { continue }
                lines.append("\(role.rawValue.uppercased()) actions:")

                // Deduplicate: group verbs by their action type
                var seen = Set<String>()
                for verb in verbs.sorted() {
                    guard let action = await registry.action(for: verb) else { continue }
                    let allVerbs = type(of: action).verbs.sorted().joined(separator: ", ")
                    guard !seen.contains(allVerbs) else { continue }
                    seen.insert(allVerbs)

                    let preps = type(of: action).validPrepositions
                        .map(\.rawValue)
                        .sorted()
                        .joined(separator: ", ")
                    lines.append("  [\(allVerbs)] prepositions: \(preps)")
                }
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Public collection

    public static func all(guard pathGuard: PathGuard) -> [AskToolDescriptor] {
        [
            aroCheck(guard: pathGuard),
            aroRun(guard: pathGuard),
            aroTest(guard: pathGuard),
            aroBuild(guard: pathGuard),
            parseARO(guard: pathGuard),
            listActions(),
        ]
    }
}
