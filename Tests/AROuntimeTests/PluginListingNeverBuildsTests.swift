// ============================================================
// PluginListingNeverBuildsTests.swift
// ARORuntime — `aro plugins list` does not compile (GitLab #850)
// ============================================================
//
// `aro plugins list -d Examples/QualifierPlugin` never returned. Listing went
// through PluginLoader, which compiles a plugin on demand — so a command whose
// entire job is to print a table could spend minutes in `swift build`, or block
// forever on a SwiftPM lock another process holds. `list` is what you reach for
// when something is already wrong.
//
// These fixtures are deliberately unbuildable: a Package.swift and a .swift
// plugin that no compiler would accept. If listing still compiled, it would
// report a compilation error and take seconds doing it. It must instead report
// "not built" immediately.

import Testing
import Foundation
@testable import ARORuntime

@Suite("Plugin listing never builds (#850)")
struct PluginListingNeverBuildsTests {

    private func project() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-pluginlist-\(UUID().uuidString)")
        let plugins = root.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)

        // An unbuildable Swift package plugin.
        let package = plugins.appendingPathComponent("BrokenPackage")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "this is not a valid Package.swift at all\n"
            .write(to: package.appendingPathComponent("Package.swift"),
                   atomically: true, encoding: .utf8)

        // An unbuildable single-file Swift plugin.
        try "this is not valid Swift either {{{\n"
            .write(to: plugins.appendingPathComponent("BrokenFile.swift"),
                   atomically: true, encoding: .utf8)

        return root
    }

    @Test("Unbuilt plugins are listed as not built, not compiled")
    func listingDoesNotCompile() throws {
        let root = try project()
        defer { try? FileManager.default.removeItem(at: root) }

        let started = Date()
        let listed = try PluginLoader.shared.listLocalPlugins(from: root)
        let elapsed = Date().timeIntervalSince(started)

        #expect(listed.count == 2)

        for plugin in listed {
            #expect(plugin.isBuilt == false, "\(plugin.name) should be reported as not built")
            // A build was never attempted, so there is no build failure to
            // report. Under the old behaviour this was the compiler's output.
            #expect(plugin.error == nil, "\(plugin.name) reported an error: \(plugin.error ?? "")")
            #expect(plugin.services.isEmpty)
        }

        #expect(Set(listed.map(\.name)) == ["BrokenPackage", "BrokenFile"])
        #expect(Set(listed.map(\.type).map { $0 == .swiftPackage }) == [true, false])

        // Invoking any compiler at all costs seconds; a directory walk plus two
        // `stat`s does not. The bound is loose enough for a loaded CI runner and
        // still far below a `swift build`.
        #expect(elapsed < 5, "listing took \(elapsed)s — did it start a build?")
    }

    @Test("A directory with no plugins/ folder lists nothing")
    func noPluginsDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-pluginlist-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try PluginLoader.shared.listLocalPlugins(from: root).isEmpty)
    }
}
