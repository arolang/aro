// ============================================================
// ToolSchemaTests.swift
// AROAskTests - tool schema derivation + argument decoding (#357)
//
// The expected JSONValue trees below are copied verbatim from the
// hand-written schemas that each tool carried before #357. The
// tests assert that the schemas now derived from the shared
// ToolParameterSchema declarations are identical, so the LLM
// receives exactly the same JSON as before the refactoring.
// ============================================================

import Foundation
import Testing
@testable import AROAsk

private let guardRoot = PathGuard(root: URL(fileURLWithPath: "/tmp"))

// MARK: - Schema shape parity with the pre-#357 hand-written trees

@Suite("Tool schema generation")
struct ToolSchemaGenerationTests {

    @Test("aro_check matches legacy schema")
    func aroCheckSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to a .aro file or application directory to check")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        #expect(AROTools.aroCheck(guard: guardRoot).parameters == expected)
    }

    @Test("aro_run matches legacy schema (string array parameter)")
    func aroRunSchema() {
        let expected: JSONValue = .object([
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
        #expect(AROTools.aroRun(guard: guardRoot).parameters == expected)
    }

    @Test("aro_test matches legacy schema")
    func aroTestSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the ARO application directory to test")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        #expect(AROTools.aroTest(guard: guardRoot).parameters == expected)
    }

    @Test("aro_build matches legacy schema")
    func aroBuildSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the ARO application directory to compile to a native binary")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        #expect(AROTools.aroBuild(guard: guardRoot).parameters == expected)
    }

    @Test("parse_aro matches legacy schema")
    func parseAROSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to a .aro file to parse and return the AST for")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        #expect(AROTools.parseARO(guard: guardRoot).parameters == expected)
    }

    @Test("list_actions matches legacy schema (no properties, no required key)")
    func listActionsSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        #expect(AROTools.listActions().parameters == expected)
    }

    @Test("read_file matches legacy schema (optional integer parameters)")
    func readFileSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path (relative to working directory or absolute)")
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "description": .string("Line number to start reading from (1-based). Defaults to 1.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum number of lines to return. Defaults to all remaining lines.")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        #expect(FileTools.readFile(guard: guardRoot).parameters == expected)
    }

    @Test("write_file matches legacy schema (two required parameters, in order)")
    func writeFileSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path (relative to working directory or absolute)")
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("The content to write to the file")
                ])
            ]),
            "required": .array([.string("path"), .string("content")])
        ])
        #expect(FileTools.writeFile(guard: guardRoot).parameters == expected)
    }

    @Test("edit_file matches legacy schema")
    func editFileSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path (relative to working directory or absolute)")
                ]),
                "old_string": .object([
                    "type": .string("string"),
                    "description": .string("The exact text to find and replace (must be unique in the file)")
                ]),
                "new_string": .object([
                    "type": .string("string"),
                    "description": .string("The replacement text")
                ])
            ]),
            "required": .array([.string("path"), .string("old_string"), .string("new_string")])
        ])
        #expect(FileTools.editFile(guard: guardRoot).parameters == expected)
    }

    @Test("list_dir matches legacy schema (empty required array is preserved)")
    func listDirSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Directory path (relative to working directory or absolute). Defaults to '.'")
                ])
            ]),
            "required": .array([])
        ])
        #expect(FileTools.listDir(guard: guardRoot).parameters == expected)
    }

    @Test("grep matches legacy schema")
    func grepSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("Regular expression pattern to search for")
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File or directory to search in (relative to working directory or absolute). Defaults to '.'")
                ]),
                "glob": .object([
                    "type": .string("string"),
                    "description": .string("Glob pattern to filter files (e.g. '*.swift', '*.aro')")
                ])
            ]),
            "required": .array([.string("pattern")])
        ])
        #expect(FileTools.grep(guard: guardRoot).parameters == expected)
    }

    @Test("create_plugin matches legacy schema (enum parameter)")
    func createPluginSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Plugin name (kebab-case, e.g. 'my-plugin')")
                ]),
                "language": .object([
                    "type": .string("string"),
                    "enum": .array([.string("swift"), .string("c"), .string("rust"), .string("python")]),
                    "description": .string("Plugin implementation language")
                ]),
                "handle": .object([
                    "type": .string("string"),
                    "description": .string("PascalCase namespace handle (e.g. 'MyPlugin')")
                ]),
                "actions": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Action names the plugin provides")
                ]),
                "qualifiers": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Qualifier names the plugin provides (optional)")
                ])
            ]),
            "required": .array([.string("name"), .string("language"), .string("handle")])
        ])
        #expect(ProjectTools.createPlugin(guard: guardRoot).parameters == expected)
    }

    @Test("write_openapi matches legacy schema (nested object array)")
    func writeOpenAPISchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string"), "description": .string("API title")]),
                "version": .object(["type": .string("string"), "description": .string("API version (default: 1.0.0)")]),
                "paths": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "path": .object(["type": .string("string")]),
                            "method": .object(["type": .string("string")]),
                            "operationId": .object(["type": .string("string")]),
                            "summary": .object(["type": .string("string")])
                        ])
                    ]),
                    "description": .string("Array of route definitions")
                ]),
                "output_path": .object([
                    "type": .string("string"),
                    "description": .string("Output file path (default: openapi.yaml)")
                ])
            ]),
            "required": .array([.string("title"), .string("paths")])
        ])
        #expect(ProjectTools.writeOpenAPI(guard: guardRoot).parameters == expected)
    }

    @Test("generate_docs matches legacy schema")
    func generateDocsSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the .aro file or application directory to document")
                ]),
                "output_path": .object([
                    "type": .string("string"),
                    "description": .string("Output markdown file path (default: README.md)")
                ])
            ]),
            "required": .array([.string("path")])
        ])
        #expect(ProjectTools.generateDocs(guard: guardRoot).parameters == expected)
    }

    @Test("run_shell matches legacy schema")
    func runShellSchema() {
        let expected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("The shell command to execute")
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("Timeout in seconds (default 60)")
                ])
            ]),
            "required": .array([.string("command")])
        ])
        #expect(ShellTool.tool(guard: guardRoot).parameters == expected)
    }

    @Test("proposal tools match legacy schemas")
    func proposalToolSchemas() {
        let tools = ProposalTools.all(cwd: URL(fileURLWithPath: "/tmp"))
        let listExpected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        let readExpected: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "number": .object([
                    "type": .string("string"),
                    "description": .string("Proposal number, e.g. \"0001\" or \"ARO-0001\"")
                ])
            ]),
            "required": .array([.string("number")])
        ])
        #expect(tools.first(where: { $0.name == "list_proposals" })?.parameters == listExpected)
        #expect(tools.first(where: { $0.name == "read_proposal" })?.parameters == readExpected)
    }

    @Test("risk levels are preserved after migration")
    func riskLevels() {
        #expect(AROTools.aroCheck(guard: guardRoot).riskLevel == .readonly)
        #expect(AROTools.aroRun(guard: guardRoot).riskLevel == .modify)
        #expect(AROTools.aroBuild(guard: guardRoot).riskLevel == .modify)
        #expect(FileTools.readFile(guard: guardRoot).riskLevel == .readonly)
        #expect(FileTools.writeFile(guard: guardRoot).riskLevel == .modify)
        #expect(FileTools.editFile(guard: guardRoot).riskLevel == .modify)
        #expect(FileTools.listDir(guard: guardRoot).riskLevel == .readonly)
        #expect(FileTools.grep(guard: guardRoot).riskLevel == .readonly)
        #expect(ProjectTools.createPlugin(guard: guardRoot).riskLevel == .modify)
        #expect(ProjectTools.writeOpenAPI(guard: guardRoot).riskLevel == .modify)
        #expect(ProjectTools.generateDocs(guard: guardRoot).riskLevel == .modify)
        #expect(ShellTool.tool(guard: guardRoot).riskLevel == .modify)
        #expect(AROTools.listActions().riskLevel == .readonly)
    }
}

// MARK: - ToolArguments decoding against the same declaration

@Suite("Tool argument decoding")
struct ToolArgumentDecodingTests {

    private let schema = ToolParameterSchema([
        .required("path", .string, "a path"),
        .optional("limit", .integer, "a limit"),
        .optional("args", .array(of: .string), "extra args"),
        .optional("verbose", .boolean),
    ])

    @Test("missing required parameter throws invalidArguments")
    func missingRequired() throws {
        let raw = try JSONValue.decode(from: #"{"limit": 3}"#)
        #expect(throws: AskToolError.self) {
            _ = try ToolArguments(raw: raw, schema: schema)
        }
    }

    @Test("null required parameter counts as missing")
    func nullRequired() throws {
        let raw = try JSONValue.decode(from: #"{"path": null}"#)
        #expect(throws: AskToolError.self) {
            _ = try ToolArguments(raw: raw, schema: schema)
        }
    }

    @Test("typed accessors decode the declared parameters")
    func typedAccessors() throws {
        let raw = try JSONValue.decode(
            from: #"{"path": "a/b", "limit": 7, "args": ["x", "y"], "verbose": true}"#
        )
        let args = try ToolArguments(raw: raw, schema: schema)
        #expect(try args.requireString("path") == "a/b")
        #expect(args.int("limit") == 7)
        #expect(args.stringArray("args") == ["x", "y"])
        #expect(args.bool("verbose") == true)
    }

    @Test("optional accessors return nil for absent parameters")
    func absentOptionals() throws {
        let raw = try JSONValue.decode(from: #"{"path": "a"}"#)
        let args = try ToolArguments(raw: raw, schema: schema)
        #expect(args.int("limit") == nil)
        #expect(args.stringArray("args") == nil)
        #expect(args.bool("verbose") == nil)
        #expect(args.string("nonexistent") == nil)
    }

    @Test("requireString throws on type mismatch")
    func typeMismatch() throws {
        let raw = try JSONValue.decode(from: #"{"path": 42}"#)
        // 42 is present, so required-presence passes; the accessor
        // rejects the wrong type.
        let args = try ToolArguments(raw: raw, schema: ToolParameterSchema([
            .required("path", .string),
        ]))
        #expect(throws: AskToolError.self) {
            _ = try args.requireString("path")
        }
    }

    @Test("descriptor execute rejects missing required argument end-to-end")
    func descriptorRejectsMissing() async throws {
        let tool = AROTools.aroCheck(guard: PathGuard(root: URL(fileURLWithPath: "/tmp")))
        await #expect(throws: AskToolError.self) {
            _ = try await tool.execute(.object([:]))
        }
    }

    @Test("empty schema accepts empty arguments")
    func emptySchema() throws {
        let args = try ToolArguments(raw: .object([:]), schema: .empty)
        #expect(args["anything"] == nil)
    }
}
