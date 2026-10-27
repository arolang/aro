// ============================================================
// REPLProjectContext.swift
// AROCLI — a REPL session opened inside a project sees that project
// (GitLab #691)
// ============================================================
//
// `aro repl` and `aro kernel` built a session that knew nothing about where it
// was standing. It registered a filesystem service and a terminal service and
// stopped: no `openapi.yaml`, no `.store` seed data, no `templates/`, no
// project plugins, and none of the project's own feature sets. So a notebook
// opened inside a project could not exercise that project, and teaching
// material diverged from `aro run` — `Render the <page> with { template:
// "x.tpl" }.` printed the raw dictionary and answered `ok`.
//
// What a project contributes is the same list `aro run` discovers, minus the
// one thing a session must not do: execute `Application-Start`. A REPL is a
// place to try statements, not a process that boots an application — binding
// ports and starting watchers on `aro repl ./MyApp` would be a surprise, and
// Solaro opens a project the moment a window appears.
//
// Everything here is additive and failure-tolerant per item: a project with a
// malformed contract still gives you its templates, and says what it could not
// read. A session is a tool for finding out why something is broken, so it has
// to survive the thing being broken.

import Foundation
import AROParser
import ARORuntime

/// What a project directory contributed to a session, and what it could not.
struct REPLProjectContext: Sendable {
    /// The project root, as resolved.
    let root: URL
    /// Human-readable lines describing what was wired in, in the order a
    /// reader cares about. Printed by the shell and sent as a notice by the
    /// JSON server, so a user can tell a project session from a bare one.
    let notes: [String]
    /// Problems that did not stop the session.
    let warnings: [String]

    /// Discover a project and wire it into `session`.
    ///
    /// - Parameters:
    ///   - directory: the project root, as the user typed it.
    ///   - session: the session to wire into, before any cell runs.
    @discardableResult
    static func load(
        directory: String,
        into session: REPLSession
    ) async -> REPLProjectContext {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        var notes: [String] = []
        var warnings: [String] = []

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return REPLProjectContext(
                root: root, notes: [],
                warnings: ["not a directory: \(root.path)"])
        }

        // ── The contract ────────────────────────────────────────────────────
        // Registered as a service, which is what makes `<request>`-shaped work
        // and `Return a <Name: status>` route the way they do under `aro run`.
        do {
            if let spec = try OpenAPILoader.load(fromDirectory: root) {
                try spec.validate()
                try ContractValidator.validateSpec(spec)
                session.context.register(OpenAPISpecService(spec: spec))
                notes.append("contract: \(spec.paths.count) path(s) from openapi.yaml")
            }
        } catch {
            warnings.append("openapi.yaml not loaded: \(error)")
        }

        // ── Seed data ───────────────────────────────────────────────────────
        // Same seeding `Application` does before Application-Start: the rows
        // go into the shared repository storage, so `Retrieve` in a cell sees
        // what a handler would see.
        do {
            let stores = try StoreFileLoader().discover(in: root)
            if !stores.isEmpty {
                let storage = InMemoryRepositoryStorage.shared
                var seeded = 0
                for descriptor in stores {
                    for entry in descriptor.entries {
                        await storage.store(
                            value: entry as [String: any Sendable],
                            in: descriptor.repositoryName,
                            businessActivity: "store-seed")
                        seeded += 1
                    }
                }
                notes.append(
                    "stores: \(seeded) row(s) in \(stores.count) repositor"
                    + (stores.count == 1 ? "y" : "ies"))

                // Writability is a property of the file's permissions
                // (ARO-0073), and `Commit the <r> to the <stores>.` needs the
                // registry to find a flush service at all.
                let writable = stores.filter { $0.isWritable }
                if !writable.isEmpty {
                    let flush = StoreFlushService(storage: storage)
                    StoreFlushRegistry.current = flush
                    await flush.register(stores: stores)
                    notes.append("stores: \(writable.count) writable")
                }
            }
        } catch {
            warnings.append(".store files not loaded: \(error)")
        }

        // ── Templates ───────────────────────────────────────────────────────
        // The reported symptom. `Render … { template: "x.tpl" }` has nowhere
        // to look without this and prints its own argument back.
        let templates = root.appendingPathComponent("templates")
        if FileManager.default.fileExists(atPath: templates.path) {
            let service = AROTemplateService(templatesDirectory: templates.path)
            // The executor is not optional furniture: without it the service
            // finds the file and then answers "Template executor not
            // configured", which is a worse failure than not being registered
            // at all. `Application` sets one for the same reason.
            service.setExecutor(TemplateExecutor(
                actionRegistry: ActionRegistry.shared,
                eventBus: session.eventBus))
            session.context.register(service as TemplateService)
            notes.append("templates: \(templates.lastPathComponent)/")
        }

        // ── Project plugins ─────────────────────────────────────────────────
        // `Plugins/` is the canonical directory (GitLab #848); the loader
        // resolves the lowercase spelling itself.
        if FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Plugins").path)
            || FileManager.default.fileExists(
                atPath: root.appendingPathComponent("plugins").path) {
            do {
                try UnifiedPluginLoader.shared.loadPlugins(from: root)
                notes.append("plugins: loaded from the project")
            } catch {
                warnings.append("project plugins not loaded: \(error)")
            }
        }

        // ── The project's own feature sets ──────────────────────────────────
        // Through `addFeatureSet`, the same door a `:load` or a cell
        // definition goes through — so handler families are registered by the
        // one classifier that knows which of them a session can deliver
        // (GitLab #688), and `Application.<Name>` calls resolve.
        //
        // `Application-Start` and the two `Application-End` handlers are
        // skipped deliberately: they are what `aro run` executes, and a
        // session is not a run. They are still *visible* in the project, just
        // not registered as something a cell can trip over.
        do {
            let sources = try Self.sourceFiles(in: root)
            var added = 0
            var skippedLifecycle = 0
            for file in sources {
                let text = try String(contentsOf: file, encoding: .utf8)
                let compiled = Compiler.compile(text)
                guard compiled.isSuccess else {
                    warnings.append(
                        "\(file.lastPathComponent): \(compiled.diagnostics.count) diagnostic(s), not loaded")
                    continue
                }
                for featureSet in compiled.analyzedProgram.featureSets {
                    let name = featureSet.featureSet.name
                    if Self.isLifecycle(name) {
                        skippedLifecycle += 1
                        continue
                    }
                    session.addFeatureSet(
                        name: name, featureSet: featureSet, source: text)
                    added += 1
                }
            }
            if added > 0 {
                notes.append("feature sets: \(added) from \(sources.count) file(s)")
            }
            if skippedLifecycle > 0 {
                notes.append(
                    "lifecycle: \(skippedLifecycle) Application-Start/End not run")
            }
        } catch {
            warnings.append("source files not read: \(error)")
        }

        return REPLProjectContext(root: root, notes: notes, warnings: warnings)
    }

    /// Every `.aro` file under the root, at any depth — the rule ARO-0005 §
    /// states and `aro run` follows, including the `sources/` convention.
    static func sourceFiles(in root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            // A plugin's own `.aro` files belong to the plugin, and `.build`
            // holds whatever a previous compile left behind.
            let path = url.path
            if path.contains("/.build/") || path.contains("/Plugins/")
                || path.contains("/plugins/") { continue }
            if url.pathExtension == "aro" { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// Whether a feature-set name is one `aro run` executes rather than one a
    /// cell may call.
    static func isLifecycle(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "application-start"
            || lower == "application-end"
            || lower.hasPrefix("application-end")
    }

    /// One line per note, prefixed so a project session is visibly different
    /// from a bare one.
    var summary: String {
        var lines = ["Project: \(root.lastPathComponent)"]
        lines += notes.map { "  \($0)" }
        lines += warnings.map { "  warning: \($0)" }
        return lines.joined(separator: "\n")
    }
}
