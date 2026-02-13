// ============================================================
// DependencyResolverTests.swift
// ARO Package Manager Tests
// ============================================================

import XCTest
@testable import AROPackageManager

final class DependencyResolverTests: XCTestCase {

    // MARK: - Simple Resolution Tests

    func testResolveNoDependencies() throws {
        let resolver = DependencyResolver(installed: [:])

        let manifest = PluginManifest(
            name: "test-plugin",
            version: "1.0.0",
            provides: [ProvideEntry(type: .aroFiles, path: "features/")]
        )

        let result = try resolver.resolve(manifest)

        XCTAssertTrue(result.isResolved)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.toInstall.isEmpty)
        XCTAssertTrue(result.satisfied.isEmpty)
    }

    func testResolveSatisfiedDependency() throws {
        // Install a dependency first
        let depManifest = PluginManifest(
            name: "dependency-plugin",
            version: "1.0.0",
            provides: [ProvideEntry(type: .aroFiles, path: "features/")]
        )

        let resolver = DependencyResolver(installed: ["dependency-plugin": depManifest])

        let manifest = PluginManifest(
            name: "test-plugin",
            version: "1.0.0",
            provides: [ProvideEntry(type: .aroFiles, path: "features/")],
            dependencies: ["dependency-plugin": DependencySpec(git: "git@github.com:test/dep.git")]
        )

        let result = try resolver.resolve(manifest)

        XCTAssertTrue(result.isResolved)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.toInstall.isEmpty)
        XCTAssertEqual(result.satisfied, ["dependency-plugin"])
    }

    func testResolveMissingDependency() throws {
        let resolver = DependencyResolver(installed: [:])

        let manifest = PluginManifest(
            name: "test-plugin",
            version: "1.0.0",
            provides: [ProvideEntry(type: .aroFiles, path: "features/")],
            dependencies: ["missing-plugin": DependencySpec(git: "git@github.com:test/missing.git")]
        )

        let result = try resolver.resolve(manifest)

        XCTAssertTrue(result.isResolved)  // Missing deps need to be installed, not a conflict
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(result.toInstall.count, 1)
        XCTAssertEqual(result.toInstall[0].git, "git@github.com:test/missing.git")
    }

    // MARK: - Installation Order Tests

    func testInstallationOrderNoDependencies() throws {
        let resolver = DependencyResolver(installed: [:])

        let plugins = [
            PluginManifest(name: "a", version: "1.0.0", provides: []),
            PluginManifest(name: "b", version: "1.0.0", provides: []),
            PluginManifest(name: "c", version: "1.0.0", provides: [])
        ]

        let order = try resolver.installationOrder(plugins)

        // All plugins should be present
        XCTAssertEqual(order.count, 3)
        let names = Set(order.map { $0.name })
        XCTAssertEqual(names, ["a", "b", "c"])
    }

    func testInstallationOrderWithDependencies() throws {
        let resolver = DependencyResolver(installed: [:])

        // c depends on b, b depends on a
        let plugins = [
            PluginManifest(
                name: "c",
                version: "1.0.0",
                provides: [],
                dependencies: ["b": DependencySpec(git: "git@github.com:test/b.git")]
            ),
            PluginManifest(
                name: "b",
                version: "1.0.0",
                provides: [],
                dependencies: ["a": DependencySpec(git: "git@github.com:test/a.git")]
            ),
            PluginManifest(
                name: "a",
                version: "1.0.0",
                provides: []
            )
        ]

        let order = try resolver.installationOrder(plugins)

        // a should come before b, b before c
        let indexA = order.firstIndex { $0.name == "a" }!
        let indexB = order.firstIndex { $0.name == "b" }!
        let indexC = order.firstIndex { $0.name == "c" }!

        XCTAssertTrue(indexA < indexB, "a should come before b")
        XCTAssertTrue(indexB < indexC, "b should come before c")
    }

    func testCircularDependencyDetection() throws {
        let resolver = DependencyResolver(installed: [:])

        // a depends on b, b depends on a (circular)
        let plugins = [
            PluginManifest(
                name: "a",
                version: "1.0.0",
                provides: [],
                dependencies: ["b": DependencySpec(git: "git@github.com:test/b.git")]
            ),
            PluginManifest(
                name: "b",
                version: "1.0.0",
                provides: [],
                dependencies: ["a": DependencySpec(git: "git@github.com:test/a.git")]
            )
        ]

        XCTAssertThrowsError(try resolver.installationOrder(plugins)) { error in
            XCTAssertTrue(error is ResolverError)
        }
    }

    // MARK: - Check Dependencies Tests

    func testCheckDependenciesAllSatisfied() throws {
        let depManifest = PluginManifest(
            name: "dep",
            version: "1.0.0",
            provides: []
        )

        let resolver = DependencyResolver(installed: ["dep": depManifest])

        let manifest = PluginManifest(
            name: "test",
            version: "1.0.0",
            provides: [],
            dependencies: ["dep": DependencySpec(git: "git@github.com:test/dep.git")]
        )

        let missing = resolver.checkDependencies(manifest)

        XCTAssertTrue(missing.isEmpty)
    }

    func testCheckDependenciesMissing() throws {
        let resolver = DependencyResolver(installed: [:])

        let manifest = PluginManifest(
            name: "test",
            version: "1.0.0",
            provides: [],
            dependencies: [
                "dep1": DependencySpec(git: "git@github.com:test/dep1.git"),
                "dep2": DependencySpec(git: "git@github.com:test/dep2.git")
            ]
        )

        let missing = resolver.checkDependencies(manifest)

        XCTAssertEqual(Set(missing), ["dep1", "dep2"])
    }
}
