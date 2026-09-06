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
            "  1. Install Python dependencies (the ARO Plugin SDK):",
            "     pip install -r Plugins/\(name)/src/requirements.txt",
            "",
            "  2. Edit Plugins/\(name)/src/plugin.py",
            "     — add @action / @qualifier decorated functions",
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

        // Only import the decorators the generated code actually uses.
        var sdkImports = ["AROInput", "export_abi", "plugin", "run"]
        if options.includeActions    { sdkImports.append("action") }
        if options.includeQualifiers { sdkImports.append("qualifier") }
        let importList = sdkImports.sorted().joined(separator: ", ")

        var actionsBlock = ""
        if options.includeActions {
            actionsBlock = """


            # MARK: - Action handlers

            @action(
                name="example",
                verbs=["example"],
                role="own",
                prepositions=["with", "from"],
                description="An example action.",
            )
            def handle_example(input: AROInput) -> Dict[str, Any]:
                \"\"\"Invoked from ARO as: \(handle).Example the <result> from <source>.\"\"\"
                data = input.get("data")
                # TODO: Implement your action logic
                return {"result": "ok", "data": data}

            """
        }

        var qualifiersBlock = ""
        if options.includeQualifiers {
            qualifiersBlock = """


            # MARK: - Qualifier handlers

            @qualifier(name="example", description="Uppercases a string (example qualifier)")
            def qualifier_example(input: AROInput) -> str:
                \"\"\"Accessed from ARO as: <value: \(handle).example>

                Return the transformed value; raise to report an error.
                \"\"\"
                value = input.get("value")
                if not isinstance(value, str):
                    raise ValueError("example requires a string")
                return value.upper()

            """
        }

        return """
        \"\"\"
        ARO Plugin — \(name)

        Uses the ARO Plugin SDK decorator API (see requirements.txt):
          @plugin      — declares plugin identity (name, version, handle)
          @action      — one function per action
          @qualifier   — one function per qualifier
          export_abi() — generates the module-level ABI functions the ARO
                         runtime calls (aro_plugin_info, aro_plugin_execute,
                         aro_plugin_qualifier)
        \"\"\"

        from typing import Any, Dict

        from aro_plugin_sdk import \(importList)


        @plugin(name="\(name)", version="1.0.0", handle="\(handle)")
        class \(handle)Plugin:
            pass
        \(actionsBlock)\(qualifiersBlock)

        # Generate the module-level ABI functions for the ARO runtime.
        export_abi(globals())

        if __name__ == "__main__":
            run()
        """
    }
}
