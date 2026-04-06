// ============================================================
// AROTools.swift
// AROLM - tools for invoking the aro toolchain and parser
// ============================================================

import Foundation
import AROParser
import ARORuntime

public enum AROTools {

    /// Locate the `aro` binary to shell out to. Uses the current executable if
    /// we're running as `aro lm`; otherwise falls back to PATH.
    private static func aroBinary() -> String {
        let args = CommandLine.arguments
        if let first = args.first, first.hasSuffix("/aro") || first == "aro" {
            return first.hasPrefix("/") ? first : (ProcessRunner.which("aro") ?? first)
        }
        return ProcessRunner.which("aro") ?? "aro"
    }

    // MARK: - aro_check

    public static func aroCheck(guard pathGuard: PathGuard) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")])
            ]),
            "required": .array([.string("path")])
        ])
        return LMToolDescriptor(
            name: "aro_check",
            description: "Run `aro check` on the given file or application directory.",
            parameters: params
        ) { args in
            guard let p = args["path"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'path'")
            }
            let url = try pathGuard.resolve(p)
            let result = try ProcessRunner.runAndCapture(
                executable: aroBinary(),
                arguments: ["check", url.path],
                cwd: pathGuard.root,
                timeout: 60
            )
            return "exit: \(result.exitCode)\n\(result.stdout)\n\(result.stderr)"
        }
    }

    // MARK: - aro_run

    public static func aroRun(guard pathGuard: PathGuard) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "args": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")])
                ])
            ]),
            "required": .array([.string("path")])
        ])
        return LMToolDescriptor(
            name: "aro_run",
            description: "Run an ARO application via `aro run`.",
            parameters: params
        ) { args in
            guard let p = args["path"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'path'")
            }
            let url = try pathGuard.resolve(p)
            var processArgs = ["run", url.path]
            if let extra = args["args"]?.arrayValue {
                processArgs.append(contentsOf: extra.compactMap { $0.stringValue })
            }
            let result = try ProcessRunner.runAndCapture(
                executable: aroBinary(),
                arguments: processArgs,
                cwd: pathGuard.root,
                timeout: 120
            )
            return "exit: \(result.exitCode)\n\(result.stdout)\n\(result.stderr)"
        }
    }

    // MARK: - aro_test

    public static func aroTest(guard pathGuard: PathGuard) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")])
            ]),
            "required": .array([.string("path")])
        ])
        return LMToolDescriptor(
            name: "aro_test",
            description: "Run `aro test` on the given application directory.",
            parameters: params
        ) { args in
            guard let p = args["path"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'path'")
            }
            let url = try pathGuard.resolve(p)
            let result = try ProcessRunner.runAndCapture(
                executable: aroBinary(),
                arguments: ["test", url.path],
                cwd: pathGuard.root,
                timeout: 300
            )
            return "exit: \(result.exitCode)\n\(result.stdout)\n\(result.stderr)"
        }
    }

    // MARK: - aro_build

    public static func aroBuild(guard pathGuard: PathGuard) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string")]),
                "optimize": .object(["type": .string("boolean")])
            ]),
            "required": .array([.string("path")])
        ])
        return LMToolDescriptor(
            name: "aro_build",
            description: "Compile an ARO application to a native binary via `aro build`.",
            parameters: params
        ) { args in
            guard let p = args["path"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'path'")
            }
            let url = try pathGuard.resolve(p)
            var processArgs = ["build", url.path]
            if args["optimize"]?.boolValue == true {
                processArgs.append("--optimize")
            }
            let result = try ProcessRunner.runAndCapture(
                executable: aroBinary(),
                arguments: processArgs,
                cwd: pathGuard.root,
                timeout: 600
            )
            return "exit: \(result.exitCode)\n\(result.stdout)\n\(result.stderr)"
        }
    }

    // MARK: - parse_aro

    public static func parseARO() -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "source": .object(["type": .string("string")])
            ]),
            "required": .array([.string("source")])
        ])
        return LMToolDescriptor(
            name: "parse_aro",
            description: "Parse ARO source without writing to disk. Returns 'ok' or a parser diagnostic.",
            parameters: params
        ) { args in
            guard let source = args["source"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'source'")
            }
            do {
                let lexer = Lexer(source: source)
                let tokens = try lexer.tokenize()
                let parser = Parser(tokens: tokens)
                _ = try parser.parse()
                return "ok"
            } catch {
                return "parse error: \(error)"
            }
        }
    }

    // MARK: - list_actions

    public static func listActions() -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        return LMToolDescriptor(
            name: "list_actions",
            description: "Return the verbs of all actions registered in the ARO runtime.",
            parameters: params
        ) { _ in
            let verbs = await ActionRegistry.shared.registeredVerbs
            return verbs.sorted().joined(separator: "\n")
        }
    }

    public static func all(guard pathGuard: PathGuard) -> [LMToolDescriptor] {
        [
            aroCheck(guard: pathGuard),
            aroRun(guard: pathGuard),
            aroTest(guard: pathGuard),
            aroBuild(guard: pathGuard),
            parseARO(),
            listActions()
        ]
    }
}
