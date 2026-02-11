// ============================================================
// PluginScannerTests.swift
// ARO Package Manager Tests
// ============================================================

import XCTest
@testable import AROPackageManager

final class PluginScannerTests: XCTestCase {

    var testDirectory: URL!
    var pluginsDirectory: URL!

    override func setUpWithError() throws {
        // Create a temporary test directory
        let tempDir = FileManager.default.temporaryDirectory
        testDirectory = tempDir.appendingPathComponent("aro-test-\(UUID().uuidString)")
        pluginsDirectory = testDirectory.appendingPathComponent("Plugins")

        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Clean up test directory
        if FileManager.default.fileExists(atPath: testDirectory.path) {
            try FileManager.default.removeItem(at: testDirectory)
        }
    }

    // MARK: - Scanning Tests

    func testScanEmptyDirectory() throws {
        let scanner = PluginScanner(directory: pluginsDirectory)
        let plugins = try scanner.scan()

        XCTAssertTrue(plugins.isEmpty)
    }

    func testScanNonExistentDirectory() throws {
        let noDir = testDirectory.appendingPathComponent("NonExistent/Plugins")
        let scanner = PluginScanner(directory: noDir)
        let plugins = try scanner.scan()

        XCTAssertTrue(plugins.isEmpty)
    }

    func testScanSinglePlugin() throws {
        // Create a plugin directory with manifest
        let pluginDir = pluginsDirectory.appendingPathComponent("my-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        let manifestYAML = """
        name: my-plugin
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        """

        try manifestYAML.write(
            to: pluginDir.appendingPathComponent("plugin.yaml"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = PluginScanner(directory: pluginsDirectory)
        let plugins = try scanner.scan()

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins[0].manifest.name, "my-plugin")
        XCTAssertEqual(plugins[0].manifest.version, "1.0.0")
    }

    func testScanMultiplePlugins() throws {
        // Create two plugin directories
        for pluginName in ["plugin-a", "plugin-b"] {
            let pluginDir = pluginsDirectory.appendingPathComponent(pluginName)
            try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

            let manifestYAML = """
            name: \(pluginName)
            version: 1.0.0
            provides:
              - type: aro-files
                path: features/
            """

            try manifestYAML.write(
                to: pluginDir.appendingPathComponent("plugin.yaml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let scanner = PluginScanner(directory: pluginsDirectory)
        let plugins = try scanner.scan()

        XCTAssertEqual(plugins.count, 2)
        let names = Set(plugins.map { $0.manifest.name })
        XCTAssertTrue(names.contains("plugin-a"))
        XCTAssertTrue(names.contains("plugin-b"))
    }

    func testScanSkipsDirectoriesWithoutManifest() throws {
        // Create a plugin with manifest
        let goodPlugin = pluginsDirectory.appendingPathComponent("good-plugin")
        try FileManager.default.createDirectory(at: goodPlugin, withIntermediateDirectories: true)

        let manifestYAML = """
        name: good-plugin
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        """
        try manifestYAML.write(
            to: goodPlugin.appendingPathComponent("plugin.yaml"),
            atomically: true,
            encoding: .utf8
        )

        // Create a directory without manifest
        let badPlugin = pluginsDirectory.appendingPathComponent("bad-plugin")
        try FileManager.default.createDirectory(at: badPlugin, withIntermediateDirectories: true)
        try "not a manifest".write(
            to: badPlugin.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = PluginScanner(directory: pluginsDirectory)
        let plugins = try scanner.scan()

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins[0].manifest.name, "good-plugin")
    }

    // MARK: - Validation Tests

    func testValidateNoDuplicates() throws {
        let plugins = [
            DiscoveredPlugin(
                path: pluginsDirectory.appendingPathComponent("a"),
                manifest: PluginManifest(name: "a", version: "1.0.0", provides: [])
            ),
            DiscoveredPlugin(
                path: pluginsDirectory.appendingPathComponent("b"),
                manifest: PluginManifest(name: "b", version: "1.0.0", provides: [])
            )
        ]

        let scanner = PluginScanner(directory: pluginsDirectory)
        let result = scanner.validate(plugins)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testValidateDetectsDuplicates() throws {
        let plugins = [
            DiscoveredPlugin(
                path: pluginsDirectory.appendingPathComponent("a1"),
                manifest: PluginManifest(name: "same-name", version: "1.0.0", provides: [])
            ),
            DiscoveredPlugin(
                path: pluginsDirectory.appendingPathComponent("a2"),
                manifest: PluginManifest(name: "same-name", version: "2.0.0", provides: [])
            )
        ]

        let scanner = PluginScanner(directory: pluginsDirectory)
        let result = scanner.validate(plugins)

        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertTrue(result.errors[0].contains("Duplicate"))
    }

    func testValidateMissingDependencyWarning() throws {
        let plugins = [
            DiscoveredPlugin(
                path: pluginsDirectory.appendingPathComponent("test"),
                manifest: PluginManifest(
                    name: "test",
                    version: "1.0.0",
                    provides: [],
                    dependencies: ["missing": DependencySpec(git: "git@github.com:test/missing.git")]
                )
            )
        ]

        let scanner = PluginScanner(directory: pluginsDirectory)
        let result = scanner.validate(plugins)

        XCTAssertTrue(result.isValid)  // Missing deps are warnings, not errors
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.warnings[0].contains("missing"))
    }

    // MARK: - Sorted Scan Tests

    func testScanSortedWithDependencies() throws {
        // Create two plugins: b depends on a
        let pluginA = pluginsDirectory.appendingPathComponent("plugin-a")
        try FileManager.default.createDirectory(at: pluginA, withIntermediateDirectories: true)
        try """
        name: plugin-a
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        """.write(
            to: pluginA.appendingPathComponent("plugin.yaml"),
            atomically: true,
            encoding: .utf8
        )

        let pluginB = pluginsDirectory.appendingPathComponent("plugin-b")
        try FileManager.default.createDirectory(at: pluginB, withIntermediateDirectories: true)
        try """
        name: plugin-b
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        dependencies:
          plugin-a:
            git: "git@github.com:test/plugin-a.git"
        """.write(
            to: pluginB.appendingPathComponent("plugin.yaml"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = PluginScanner(directory: pluginsDirectory)
        let plugins = try scanner.scanSorted()

        XCTAssertEqual(plugins.count, 2)

        // a should come before b
        let indexA = plugins.firstIndex { $0.manifest.name == "plugin-a" }!
        let indexB = plugins.firstIndex { $0.manifest.name == "plugin-b" }!

        XCTAssertTrue(indexA < indexB, "plugin-a should come before plugin-b")
    }

    // MARK: - Application Directory Init Tests

    func testInitWithApplicationDirectory() throws {
        let scanner = PluginScanner(applicationDirectory: testDirectory)

        // Create a plugin
        let pluginDir = pluginsDirectory.appendingPathComponent("test-plugin")
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        try """
        name: test-plugin
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        """.write(
            to: pluginDir.appendingPathComponent("plugin.yaml"),
            atomically: true,
            encoding: .utf8
        )

        let plugins = try scanner.scan()

        XCTAssertEqual(plugins.count, 1)
        XCTAssertEqual(plugins[0].manifest.name, "test-plugin")
    }
}
