// ============================================================
// CCodeGeneratorTests.swift
// AROCompiler Tests
// ============================================================

import XCTest
@testable import AROCompiler
@testable import AROParser

final class CCodeGeneratorTests: XCTestCase {

    func testCCodeGeneratorCreation() throws {
        let generator = CCodeGenerator()
        XCTAssertNotNil(generator)
    }

    func testCompilerErrorDescriptions() throws {
        let errors: [CCodeGeneratorError] = [
            .noEntryPoint,
            .unsupportedAction("test"),
            .invalidType("test"),
            .compilationFailed("test")
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
        }
    }

    func testLinkerErrorDescriptions() throws {
        let errors: [LinkerError] = [
            .compilationFailed("test"),
            .linkFailed("test"),
            .runtimeNotFound("test")
        ]

        for error in errors {
            XCTAssertFalse(error.description.isEmpty)
        }
    }

    func testCCompilerCreation() throws {
        let compiler = CCompiler()
        XCTAssertNil(compiler.runtimeLibraryPath)
        XCTAssertNil(compiler.targetPlatform)
    }

    func testCCompilerWithOptions() throws {
        let compiler = CCompiler(
            runtimeLibraryPath: "/usr/local/lib/libAROCRuntime.a",
            targetPlatform: "x86_64-apple-darwin"
        )
        XCTAssertEqual(compiler.runtimeLibraryPath, "/usr/local/lib/libAROCRuntime.a")
        XCTAssertEqual(compiler.targetPlatform, "x86_64-apple-darwin")
    }
}
