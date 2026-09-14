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
            // `#[qualifier]` is not importable: the SDK has a `qualifier`
            // *module*, so its prelude re-exports the attribute under a
            // different name (`pub use aro_plugin_sdk_macros::{action,
            // aro_export, qualifier as qualifier_attr}`). Telling people to
            // write `#[qualifier]` sends them to a name that does not resolve
            // — and the generated file already uses the right one.
            "     — add #[action] / #[qualifier_attr] functions and list them in aro_export!",
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

        var actionsBlock = ""
        var actionNames  = ""
        if options.includeActions {
            actionNames = "example"
            actionsBlock = """


            // MARK: - Actions

            /// Invoked from ARO as: \(handle).Example the <result> from <source>.
            #[action(name = "example", verbs = ["example"], role = "own",
                     prepositions = ["with", "from"],
                     description = "An example action.")]
            fn example(input: &Input) -> PluginResult<Output> {
                let data = input.string("data").unwrap_or("");
                // TODO: Implement your action logic
                Ok(Output::new()
                    .set("result", json!("ok"))
                    .set("data", json!(data)))
            }
            """
        }

        var qualifiersBlock = ""
        var qualifierNames  = ""
        if options.includeQualifiers {
            qualifierNames = "qualifier_example"
            qualifiersBlock = """


            // MARK: - Qualifiers

            /// Accessed from ARO as: <value: \(handle).example>
            #[qualifier_attr(name = "example", input_types = ["String"],
                             description = "Uppercases a string (example qualifier).")]
            fn qualifier_example(input: &Input) -> PluginResult<Output> {
                let value = input
                    .string("value")
                    .ok_or_else(|| PluginError::invalid_type("value", "a string"))?;
                // The runtime reads the transformed value from the "result" field.
                Ok(Output::new().set("result", json!(value.to_uppercase())))
            }
            """
        }

        return """
        //! ARO Plugin — \(name)
        //!
        //! Uses the ARO Plugin SDK macros for zero-boilerplate C ABI generation.
        //! The `aro_export!` macro generates every export the ARO runtime needs:
        //! `aro_plugin_info`, `aro_plugin_execute`, `aro_plugin_qualifier`,
        //! `aro_plugin_free`, `aro_plugin_init`, and `aro_plugin_shutdown`.
        //!
        //! See: https://github.com/arolang/aro-plugin-sdk-rust

        use aro_plugin_sdk::prelude::*;
        \(actionsBlock)\(qualifiersBlock)

        // Wire every #[action] / #[qualifier_attr] function into the C ABI exports.
        aro_export! {
            name: "\(name)",
            version: "1.0.0",
            handle: "\(handle)",
            actions: [\(actionNames)],
            qualifiers: [\(qualifierNames)],
        }
        """
    }
}
