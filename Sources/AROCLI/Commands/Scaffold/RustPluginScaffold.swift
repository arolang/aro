// ============================================================
// RustPluginScaffold.swift
// ARO CLI - Rust plugin scaffolding
// ============================================================

import Foundation

/// Scaffolds a Rust plugin (plugin.yaml, Cargo.toml, src/lib.rs).
struct RustPluginScaffold: PluginScaffold {
    func generate(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []

        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: pluginYaml(options: options), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        let cargoURL = pluginDir.appendingPathComponent("Cargo.toml")
        try write(content: cargoToml(options: options), to: cargoURL)
        created.append(relativePath(cargoURL, to: pluginDir))

        let libURL = pluginDir.appendingPathComponent("src/lib.rs")
        try write(content: libRs(options: options), to: libURL)
        created.append(relativePath(libURL, to: pluginDir))

        try appendHybridFeatures(options: options, pluginDir: pluginDir, into: &created)
        return created
    }

    func nextSteps(options: ScaffoldOptions) -> [String] {
        let name = options.pluginName
        return [
            "  1. Edit Plugins/\(name)/src/lib.rs",
            "     — implement your actions in aro_plugin_execute()",
            "",
            "  2. Build the plugin dynamic library:",
            "     cd Plugins/\(name) && cargo build --release",
            "",
            "  3. Reference the plugin in your .aro application and run:",
            "     aro run .",
        ]
    }

    // MARK: - Templates

    private func pluginYaml(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle
        let crateName = name.replacingOccurrences(of: "-", with: "_")
        var provides = """
        - type: rust-plugin
          path: src/
          build:
            cargo-target: release
            output: target/release/lib\(crateName).dylib
        """
        if options.includeHybrid {
            provides += "\n- type: aro-files\n  path: features/"
        }
        return """
        name: \(name)
        version: 1.0.0
        handle: \(handle)
        description: A Rust plugin that provides \(name) functionality
        author: ""
        license: MIT
        aro-version: '>=0.1.0'
        provides:
        \(provides)
        """
    }

    private func cargoToml(options: ScaffoldOptions) -> String {
        let name      = options.pluginName
        let crateName = name.replacingOccurrences(of: "-", with: "_")
        return """
        [package]
        name = "\(crateName)"
        version = "1.0.0"
        edition = "2021"
        description = "ARO plugin: \(name)"
        license = "MIT"

        [lib]
        name = "\(crateName)"
        crate-type = ["cdylib"]

        [dependencies]
        serde_json = "1.0"
        aro-plugin-sdk = { git = "https://github.com/arolang/aro-plugin-sdk-rust.git", branch = "main" }

        [profile.release]
        lto = true
        opt-level = "z"
        panic = "abort"
        """
    }

    private func libRs(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle

        // Build the optional fields for plugin info JSON (as Rust literal string fragments)
        var extraInfoFields = ""
        if options.includeActions {
            extraInfoFields += #","actions":[{"name":"Example","verbs":["example"],"role":"own","prepositions":["with","from"],"description":"An example action."}]"#
        }
        if options.includeQualifiers {
            extraInfoFields += #","qualifiers":[{"name":"example","description":"An example qualifier.","input":"Any","output":"Any"}]"#
        }

        // Build match arms for aro_plugin_execute
        var matchArms = ""
        if options.includeActions {
            matchArms += """
                        "example" => r#"{"result":"ok"}"#.to_string(),
            """
        }

        // Produce the Rust literal for the static info JSON string
        let infoJsonLiteral = #"{"name":""# + name + #"","version":"1.0.0","handle":""# + handle + #"","abi":"ARO-0073""# + extraInfoFields + "}"

        return """
        //! ARO Plugin — \(name) (ARO-0073 ABI)
        //!
        //! Implements the ARO native plugin C ABI:
        //!   aro_plugin_info      — required: return JSON metadata
        //!   aro_plugin_init      — lifecycle: called after load
        //!   aro_plugin_shutdown  — lifecycle: called before unload
        //!   aro_plugin_execute   — optional: dispatch actions
        //!   aro_plugin_free      — required: free plugin-allocated strings

        use std::ffi::{CStr, CString};
        use std::os::raw::c_char;

        // ── C ABI ──────────────────────────────────────────────────────────────

        /// Return plugin metadata as a JSON string.
        #[no_mangle]
        pub extern "C" fn aro_plugin_info() -> *mut c_char {
            let info = "\(infoJsonLiteral.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))";
            CString::new(info).unwrap().into_raw()
        }

        /// Called once after the plugin dylib is loaded.
        #[no_mangle]
        pub extern "C" fn aro_plugin_init() {
            // Allocate long-lived resources here.
        }

        /// Called once before the plugin dylib is unloaded.
        #[no_mangle]
        pub extern "C" fn aro_plugin_shutdown() {
            // Release resources here.
        }

        /// Execute a plugin action.
        ///
        /// `action`     — action name (e.g. "example")
        /// `input_json` — ARO-0073 JSON envelope:
        ///   { "result": {...}, "source": {...}, "preposition": "...",
        ///     "data": <primary value>, "_with": {...}, "_context": {...} }
        #[no_mangle]
        pub extern "C" fn aro_plugin_execute(
            action:     *const c_char,
            input_json: *const c_char,
        ) -> *mut c_char {
            let action = unsafe {
                if action.is_null() { return error_json("null action ptr") }
                CStr::from_ptr(action).to_string_lossy().into_owned()
            };
            let _input = unsafe {
                if input_json.is_null() { return error_json("null input ptr") }
                CStr::from_ptr(input_json).to_string_lossy().into_owned()
            };

            let result = match action.as_str() {
        \(matchArms)
                // TODO: Add further action handlers
                other => format!(r#"{{"error":"Unknown action: {}"}}"#, other),
            };

            CString::new(result).unwrap().into_raw()
        }

        /// Free a string allocated by this plugin.
        #[no_mangle]
        pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
            if ptr.is_null() { return }
            unsafe { drop(CString::from_raw(ptr)) }
        }

        // ── Helpers ────────────────────────────────────────────────────────────

        fn error_json(msg: &str) -> *mut c_char {
            CString::new(format!(r#"{{"error":"{}"}}"#, msg))
                .unwrap()
                .into_raw()
        }
        """
    }
}
