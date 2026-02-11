// ============================================================
// PluginManifestTests.swift
// ARO Package Manager Tests
// ============================================================

import XCTest
@testable import AROPackageManager

final class PluginManifestTests: XCTestCase {

    // MARK: - Parsing Tests

    func testParseMinimalManifest() throws {
        let yaml = """
        name: test-plugin
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        """

        let manifest = try PluginManifest.parse(yaml: yaml)

        XCTAssertEqual(manifest.name, "test-plugin")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.provides.count, 1)
        XCTAssertEqual(manifest.provides[0].type, .aroFiles)
        XCTAssertEqual(manifest.provides[0].path, "features/")
    }

    func testParseFullManifest() throws {
        let yaml = """
        name: my-awesome-plugin
        version: 2.1.0
        description: "An awesome plugin for ARO"
        author: "Test Author"
        license: MIT
        aro-version: ">=0.1.0"

        source:
          git: "git@github.com:user/plugin.git"
          ref: "main"
          commit: "abc123def456"

        provides:
          - type: aro-files
            path: features/
          - type: swift-plugin
            path: Sources/

        dependencies:
          other-plugin:
            git: "git@github.com:user/other.git"
            ref: "v1.0.0"

        build:
          swift:
            minimum-version: "6.2"
            targets:
              - name: MyPlugin
                path: Sources/
        """

        let manifest = try PluginManifest.parse(yaml: yaml)

        XCTAssertEqual(manifest.name, "my-awesome-plugin")
        XCTAssertEqual(manifest.version, "2.1.0")
        XCTAssertEqual(manifest.description, "An awesome plugin for ARO")
        XCTAssertEqual(manifest.author, "Test Author")
        XCTAssertEqual(manifest.license, "MIT")
        XCTAssertEqual(manifest.aroVersion, ">=0.1.0")

        // Source
        XCTAssertNotNil(manifest.source)
        XCTAssertEqual(manifest.source?.git, "git@github.com:user/plugin.git")
        XCTAssertEqual(manifest.source?.ref, "main")
        XCTAssertEqual(manifest.source?.commit, "abc123def456")

        // Provides
        XCTAssertEqual(manifest.provides.count, 2)
        XCTAssertEqual(manifest.provides[0].type, .aroFiles)
        XCTAssertEqual(manifest.provides[1].type, .swiftPlugin)

        // Dependencies
        XCTAssertNotNil(manifest.dependencies)
        XCTAssertEqual(manifest.dependencies?["other-plugin"]?.git, "git@github.com:user/other.git")
        XCTAssertEqual(manifest.dependencies?["other-plugin"]?.ref, "v1.0.0")

        // Build
        XCTAssertNotNil(manifest.build?.swift)
        XCTAssertEqual(manifest.build?.swift?.minimumVersion, "6.2")
    }

    func testParseRustPlugin() throws {
        let yaml = """
        name: rust-csv-formatter
        version: 1.0.0
        provides:
          - type: rust-plugin
            path: src/
            build:
              cargo-target: release
              output: libcsvformatter.dylib
        """

        let manifest = try PluginManifest.parse(yaml: yaml)

        XCTAssertEqual(manifest.provides[0].type, .rustPlugin)
        XCTAssertEqual(manifest.provides[0].build?.cargoTarget, "release")
        XCTAssertEqual(manifest.provides[0].build?.output, "libcsvformatter.dylib")
    }

    func testParsePythonPlugin() throws {
        let yaml = """
        name: python-analyzer
        version: 1.0.0
        provides:
          - type: python-plugin
            path: src/
            python:
              min-version: "3.9"
              requirements: requirements.txt
        """

        let manifest = try PluginManifest.parse(yaml: yaml)

        XCTAssertEqual(manifest.provides[0].type, .pythonPlugin)
        XCTAssertEqual(manifest.provides[0].python?.minVersion, "3.9")
        XCTAssertEqual(manifest.provides[0].python?.requirements, "requirements.txt")
    }

    // MARK: - Validation Tests

    func testValidationMissingName() {
        let yaml = """
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        """

        XCTAssertThrowsError(try PluginManifest.parse(yaml: yaml)) { error in
            XCTAssertTrue(error is ManifestError)
        }
    }

    func testValidationMissingVersion() {
        let yaml = """
        name: test-plugin
        provides:
          - type: aro-files
            path: features/
        """

        XCTAssertThrowsError(try PluginManifest.parse(yaml: yaml)) { error in
            XCTAssertTrue(error is ManifestError)
        }
    }

    func testValidationMissingProvides() {
        let yaml = """
        name: test-plugin
        version: 1.0.0
        """

        XCTAssertThrowsError(try PluginManifest.parse(yaml: yaml)) { error in
            XCTAssertTrue(error is ManifestError)
        }
    }

    func testValidationInvalidPackageName() {
        let yaml = """
        name: Test_Plugin
        version: 1.0.0
        provides:
          - type: aro-files
            path: features/
        """

        XCTAssertThrowsError(try PluginManifest.parse(yaml: yaml)) { error in
            XCTAssertTrue(error is ManifestError)
            if case let ManifestError.invalidPackageName(name) = error as! ManifestError {
                XCTAssertEqual(name, "Test_Plugin")
            }
        }
    }

    func testValidPackageNames() throws {
        let validNames = ["a", "ab", "a-b", "my-plugin", "plugin123", "a1b2c3"]

        for name in validNames {
            let yaml = """
            name: \(name)
            version: 1.0.0
            provides:
              - type: aro-files
                path: features/
            """
            XCTAssertNoThrow(try PluginManifest.parse(yaml: yaml), "Name '\(name)' should be valid")
        }
    }

    // MARK: - Serialization Tests

    func testToYAML() throws {
        let manifest = PluginManifest(
            name: "test-plugin",
            version: "1.0.0",
            description: "A test plugin",
            author: "Test Author",
            provides: [
                ProvideEntry(type: .aroFiles, path: "features/"),
                ProvideEntry(type: .swiftPlugin, path: "Sources/")
            ]
        )

        let yaml = try manifest.toYAML()

        XCTAssertTrue(yaml.contains("name: test-plugin"))
        XCTAssertTrue(yaml.contains("version: 1.0.0"))
        XCTAssertTrue(yaml.contains("description: A test plugin"))
    }
}
