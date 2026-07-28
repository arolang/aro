// ============================================================
// PythonPluginScaffold.swift
// ARO CLI - Python plugin scaffolding
// ============================================================

import Foundation

/// Scaffolds a Python plugin (plugin.yaml, src/plugin.py, src/requirements.txt).
struct PythonPluginScaffold: PluginScaffold {
    func generate(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []

        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: pluginYaml(options: options), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        let srcURL = pluginDir.appendingPathComponent("src/plugin.py")
        try write(content: pluginSource(options: options), to: srcURL)
        created.append(relativePath(srcURL, to: pluginDir))

        let reqURL = pluginDir.appendingPathComponent("src/requirements.txt")
        try write(content: "aro-plugin-sdk @ git+https://github.com/arolang/aro-plugin-sdk-python.git@main\n", to: reqURL)
        created.append(relativePath(reqURL, to: pluginDir))

        try appendHybridFeatures(options: options, pluginDir: pluginDir, into: &created)
        return created
    }

    func nextSteps(options: ScaffoldOptions) -> [String] {
        let name = options.pluginName
        return [
            "  1. Edit Plugins/\(name)/src/plugin.py",
            "     — implement your actions in aro_plugin_execute()",
            "",
            "  2. Install Python dependencies (if any):",
            "     pip install -r Plugins/\(name)/src/requirements.txt",
            "",
            "  3. Reference the plugin in your .aro application and run:",
            "     aro run .",
        ]
    }

    // MARK: - Templates

    private func pluginYaml(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle
        var provides = """
        - type: python-plugin
          path: src/
          handler: \(handle.lowercased())
          python:
            min-version: '3.9'
            requirements: requirements.txt
        """
        if options.includeHybrid {
            provides += "\n- type: aro-files\n  path: features/"
        }
        return """
        name: \(name)
        version: 1.0.0
        handle: \(handle)
        description: A Python plugin that provides \(name) functionality
        author: ""
        license: MIT
        aro-version: '>=0.1.0'
        provides:
        \(provides)
        """
    }

    private func pluginSource(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle

        var actionsBlock = ""
        if options.includeActions {
            actionsBlock = """
                    {
                        "name": "example",
                        "verbs": ["example"],
                        "role": "own",
                        "prepositions": ["with", "from"],
                        "description": "An example action.",
                    },
            """
        }

        var qualifiersBlock = ""
        if options.includeQualifiers {
            qualifiersBlock = """
                    {
                        "name": "example",
                        "description": "An example qualifier.",
                        "input": "Any",
                        "output": "Any",
                    },
            """
        }

        var dispatchBlock = ""
        if options.includeActions {
            dispatchBlock = """
                if action == "example":
                    # TODO: Implement example action
                    return {"result": "ok", "action": action}
            """
        }

        return """
        \"\"\"
        ARO Plugin — \(name) (Python, ARO-0073 ABI)

        Implements the ARO Python plugin interface:
          aro_plugin_info()        — required: return metadata dict
          on_init()                — lifecycle: called once after load
          on_shutdown()            — lifecycle: called once before unload
          aro_action_<name>()      — one function per action
        \"\"\"

        from typing import Any, Dict


        def aro_plugin_info() -> Dict[str, Any]:
            \"\"\"Return plugin metadata.\"\"\"
            info: Dict[str, Any] = {
                "name": "\(name)",
                "version": "1.0.0",
                "handle": "\(handle)",
                "abi": "ARO-0073",
            }
            actions = [
        \(actionsBlock)
            ]
            qualifiers = [
        \(qualifiersBlock)
            ]
            if actions:
                info["actions"] = actions
            if qualifiers:
                info["qualifiers"] = qualifiers
            return info


        def on_init() -> None:
            \"\"\"Called once after the plugin is loaded. Allocate resources here.\"\"\"
            pass


        def on_shutdown() -> None:
            \"\"\"Called once before the plugin is unloaded. Release resources here.\"\"\"
            pass


        def aro_plugin_execute(action: str, input_json: Dict[str, Any]) -> Dict[str, Any]:
            \"\"\"
            Dispatch an action.

            input_json conforms to ARO-0073:
              {
                "result": {...}, "source": {...}, "preposition": "...",
                "data": <primary value>, "_with": {...}, "_context": {...}
              }
            \"\"\"
            with_args = input_json.get("_with", {})
            data = input_json.get("data")

        \(dispatchBlock)
            return {"error": f"Unknown action: {action}"}


        # ── Per-action helpers (optional convenience pattern) ─────────────────

        def aro_action_example(input_json: Dict[str, Any]) -> Dict[str, Any]:
            \"\"\"Example action implementation.\"\"\"
            # TODO: Implement
            return {"result": "ok"}
        """
    }
}
