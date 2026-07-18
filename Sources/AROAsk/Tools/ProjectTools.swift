// ============================================================
// ProjectTools.swift
// AROAsk - tools for creating plugins, OpenAPI specs, and docs
// ============================================================

import Foundation

/// High-level project scaffolding tools. These create files and directories
/// in the user's project — all require approval.
public enum ProjectTools {

    // MARK: - create_plugin

    public static func createPlugin(guard pathGuard: PathGuard) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "create_plugin",
            description: "Scaffold a new ARO plugin directory with plugin.yaml and source template.",
            schema: ToolParameterSchema([
                .required("name", .string, "Plugin name (kebab-case, e.g. 'my-plugin')"),
                .required("language", .enumeration(["swift", "c", "rust", "python"]), "Plugin implementation language"),
                .required("handle", .string, "PascalCase namespace handle (e.g. 'MyPlugin')"),
                .optional("actions", .array(of: .string), "Action names the plugin provides"),
                .optional("qualifiers", .array(of: .string), "Qualifier names the plugin provides (optional)"),
            ]),
            riskLevel: .modify
        ) { args in
            let name = try args.requireString("name")
            let language = try args.requireString("language")
            let handle = try args.requireString("handle")
            let actions = args.stringArray("actions") ?? []
            let qualifiers = args.stringArray("qualifiers") ?? []

            let pluginDir = try pathGuard.resolve("Plugins/\(name)")
            let srcDir = pluginDir.appendingPathComponent("src")
            let fm = FileManager.default
            try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)

            // plugin.yaml
            var yaml = """
            name: \(name)
            version: 1.0.0
            handle: \(handle)
            provides:
              - type: \(language)-plugin
                path: src/
            """
            if !actions.isEmpty {
                yaml += "\n    actions:\n"
                for a in actions { yaml += "      - \(a)\n" }
            }
            if !qualifiers.isEmpty {
                yaml += "\n    qualifiers:\n"
                for q in qualifiers { yaml += "      - \(q)\n" }
            }
            try Data(yaml.utf8).write(to: pluginDir.appendingPathComponent("plugin.yaml"))

            // Source template
            let sourceContent: String
            let sourceFile: String
            switch language {
            case "swift":
                sourceFile = "\(name).swift"
                sourceContent = swiftPluginTemplate(name: name, handle: handle, actions: actions, qualifiers: qualifiers)
            case "c":
                sourceFile = "\(name).c"
                sourceContent = cPluginTemplate(name: name, actions: actions, qualifiers: qualifiers)
            case "rust":
                sourceFile = "lib.rs"
                sourceContent = rustPluginTemplate(name: name, actions: actions, qualifiers: qualifiers)
            case "python":
                sourceFile = "\(name).py"
                sourceContent = pythonPluginTemplate(name: name, actions: actions, qualifiers: qualifiers)
            default:
                throw AskToolError.invalidArguments("unsupported language: \(language)")
            }
            try Data(sourceContent.utf8).write(to: srcDir.appendingPathComponent(sourceFile))

            return "Created plugin scaffold at Plugins/\(name)/\n  plugin.yaml\n  src/\(sourceFile)"
        }
    }

    // MARK: - write_openapi

    public static func writeOpenAPI(guard pathGuard: PathGuard) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "write_openapi",
            description: "Generate an openapi.yaml contract file for an ARO HTTP application.",
            schema: ToolParameterSchema([
                .required("title", .string, "API title"),
                .optional("version", .string, "API version (default: 1.0.0)"),
                .required("paths", .array(of: .object([
                    .optional("path", .string),
                    .optional("method", .string),
                    .optional("operationId", .string),
                    .optional("summary", .string),
                ])), "Array of route definitions"),
                .optional("output_path", .string, "Output file path (default: openapi.yaml)"),
            ]),
            riskLevel: .modify
        ) { args in
            let title = try args.requireString("title")
            let paths = try args.requireArray("paths")
            let version = args.string("version") ?? "1.0.0"
            let outputPath = args.string("output_path") ?? "openapi.yaml"

            var yaml = """
            openapi: 3.0.3
            info:
              title: \(title)
              version: \(version)
            paths:
            """

            // Group paths by URL
            var grouped: [String: [(method: String, opId: String, summary: String)]] = [:]
            for p in paths {
                guard let path = p["path"]?.stringValue,
                      let method = p["method"]?.stringValue,
                      let opId = p["operationId"]?.stringValue else { continue }
                let summary = p["summary"]?.stringValue ?? opId
                grouped[path, default: []].append((method.lowercased(), opId, summary))
            }

            for (path, methods) in grouped.sorted(by: { $0.key < $1.key }) {
                yaml += "\n  \(path):"
                for m in methods {
                    yaml += """
                    \n    \(m.method):
                          operationId: \(m.opId)
                          summary: \(m.summary)
                          responses:
                            '200':
                              description: Success
                    """
                }
            }
            yaml += "\n"

            let url = try pathGuard.resolve(outputPath)
            try Data(yaml.utf8).write(to: url)
            return "Wrote OpenAPI contract to \(outputPath) (\(grouped.count) paths, \(paths.count) operations)"
        }
    }

    // MARK: - generate_docs

    public static func generateDocs(guard pathGuard: PathGuard) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "generate_docs",
            description: "Generate markdown documentation for an ARO application by reading its source files.",
            schema: ToolParameterSchema([
                .required("path", .string, "Path to the .aro file or application directory to document"),
                .optional("output_path", .string, "Output markdown file path (default: README.md)"),
            ]),
            riskLevel: .modify
        ) { args in
            let path = try args.requireString("path")
            let outputPath = args.string("output_path") ?? "README.md"
            let url = try pathGuard.resolve(path)
            let fm = FileManager.default

            var aroFiles: [URL] = []
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: nil) {
                    while let item = enumerator.nextObject() as? URL {
                        if item.pathExtension == "aro" { aroFiles.append(item) }
                    }
                }
            } else if url.pathExtension == "aro" {
                aroFiles = [url]
            }

            guard !aroFiles.isEmpty else {
                return "No .aro files found at \(path)"
            }

            // Collect feature set names and their business activities
            var features: [(name: String, activity: String, file: String)] = []
            let regex = try NSRegularExpression(pattern: #"\(([^:]+):\s*([^)]+)\)"#)

            for file in aroFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let range = NSRange(content.startIndex..<content.endIndex, in: content)
                for match in regex.matches(in: content, range: range) {
                    if let nameRange = Range(match.range(at: 1), in: content),
                       let actRange = Range(match.range(at: 2), in: content) {
                        let name = String(content[nameRange]).trimmingCharacters(in: .whitespaces)
                        let activity = String(content[actRange]).trimmingCharacters(in: .whitespaces)
                        let relFile = file.lastPathComponent
                        features.append((name, activity, relFile))
                    }
                }
            }

            var doc = "# \(url.lastPathComponent)\n\n"
            doc += "ARO application with \(aroFiles.count) source file(s) and \(features.count) feature set(s).\n\n"
            doc += "## Feature Sets\n\n"
            doc += "| Feature Set | Business Activity | File |\n"
            doc += "|---|---|---|\n"
            for f in features {
                doc += "| \(f.name) | \(f.activity) | \(f.file) |\n"
            }
            doc += "\n## Source Files\n\n"
            for file in aroFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                doc += "- `\(file.lastPathComponent)`\n"
            }

            let outURL = try pathGuard.resolve(outputPath)
            try Data(doc.utf8).write(to: outURL)
            return "Generated documentation at \(outputPath) (\(features.count) feature sets documented)"
        }
    }

    public static func all(guard pathGuard: PathGuard) -> [AskToolDescriptor] {
        [
            createPlugin(guard: pathGuard),
            writeOpenAPI(guard: pathGuard),
            generateDocs(guard: pathGuard),
        ]
    }

    // MARK: - Plugin templates

    private static func swiftPluginTemplate(name: String, handle: String, actions: [String], qualifiers: [String]) -> String {
        var s = """
        import Foundation

        @_cdecl("aro_plugin_info")
        public func pluginInfo() -> UnsafeMutablePointer<CChar> {
            let info: [String: Any] = [
                "name": "\(name)",
                "version": "1.0.0",
                "actions": [\(actions.map { "\"\($0)\"" }.joined(separator: ", "))],
                "qualifiers": [\(qualifiers.map { "\"\($0)\"" }.joined(separator: ", "))],
            ]
            let data = try! JSONSerialization.data(withJSONObject: info)
            let str = String(data: data, encoding: .utf8)!
            return strdup(str)!
        }

        @_cdecl("aro_plugin_execute")
        public func pluginExecute(action: UnsafePointer<CChar>, inputJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
            let actionName = String(cString: action)
            let input = String(cString: inputJSON)
            // TODO: implement action logic
            let result = #"{"result": "\\#(actionName) executed with \\#(input)"}"#
            return strdup(result)!
        }

        @_cdecl("aro_plugin_free")
        public func pluginFree(ptr: UnsafeMutablePointer<CChar>) {
            free(ptr)
        }
        """
        if !qualifiers.isEmpty {
            s += """

            \n@_cdecl("aro_plugin_qualifier")
            public func pluginQualifier(qualifier: UnsafePointer<CChar>, inputJSON: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
                let name = String(cString: qualifier)
                let input = String(cString: inputJSON)
                // TODO: implement qualifier logic
                let result = #"{"result": "\\#(name) applied"}"#
                return strdup(result)!
            }
            """
        }
        return s
    }

    private static func cPluginTemplate(name: String, actions: [String], qualifiers: [String]) -> String {
        """
        #include <stdlib.h>
        #include <string.h>
        #include <stdio.h>

        char* aro_plugin_info(void) {
            const char* info = "{\\"name\\": \\"\(name)\\", \\"version\\": \\"1.0.0\\", "
                "\\"actions\\": [\(actions.map { "\\\"\($0)\\\"" }.joined(separator: ", "))], "
                "\\"qualifiers\\": [\(qualifiers.map { "\\\"\($0)\\\"" }.joined(separator: ", "))]}";
            return strdup(info);
        }

        char* aro_plugin_execute(const char* action, const char* input_json) {
            char buf[1024];
            snprintf(buf, sizeof(buf), "{\\"result\\": \\"%s executed\\"}", action);
            return strdup(buf);
        }

        void aro_plugin_free(char* ptr) {
            free(ptr);
        }
        """
    }

    private static func rustPluginTemplate(name: String, actions: [String], qualifiers: [String]) -> String {
        """
        use std::ffi::{CStr, CString};
        use std::os::raw::c_char;

        #[no_mangle]
        pub extern "C" fn aro_plugin_info() -> *mut c_char {
            let info = format!(r#"{{"name": "\(name)", "version": "1.0.0", "actions": [\(actions.map { "\"\($0)\"" }.joined(separator: ", "))], "qualifiers": [\(qualifiers.map { "\"\($0)\"" }.joined(separator: ", "))]}}"#);
            CString::new(info).unwrap().into_raw()
        }

        #[no_mangle]
        pub extern "C" fn aro_plugin_execute(action: *const c_char, input_json: *const c_char) -> *mut c_char {
            let action = unsafe { CStr::from_ptr(action).to_str().unwrap_or("?") };
            let result = format!(r#"{{"result": "{} executed"}}"#, action);
            CString::new(result).unwrap().into_raw()
        }

        #[no_mangle]
        pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
            if !ptr.is_null() {
                unsafe { drop(CString::from_raw(ptr)); }
            }
        }
        """
    }

    private static func pythonPluginTemplate(name: String, actions: [String], qualifiers: [String]) -> String {
        """
        def aro_plugin_info():
            return {
                "name": "\(name)",
                "version": "1.0.0",
                "actions": [\(actions.map { "\"\($0)\"" }.joined(separator: ", "))],
                "qualifiers": [\(qualifiers.map { "\"\($0)\"" }.joined(separator: ", "))],
            }

        \(actions.map { "def aro_action_\($0.replacingOccurrences(of: "-", with: "_"))(input_data):\n    \"\"\"TODO: implement \($0) action.\"\"\"\n    return {\"result\": f\"\($0) executed\"}\n" }.joined(separator: "\n"))
        \(qualifiers.map { "def aro_qualifier_\($0.replacingOccurrences(of: "-", with: "_"))(input_data):\n    \"\"\"TODO: implement \($0) qualifier.\"\"\"\n    return {\"result\": input_data}\n" }.joined(separator: "\n"))
        """
    }
}
