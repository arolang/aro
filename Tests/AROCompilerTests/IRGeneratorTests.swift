// ============================================================
// LLVMCodeGeneratorTests.swift
// AROCompiler Tests
// ============================================================

import XCTest
@testable import AROCompiler
@testable import AROParser

final class LLVMCodeGeneratorTests: XCTestCase {

    func testLLVMCodeGeneratorCreation() throws {
        let generator = LLVMCodeGenerator()
        XCTAssertNotNil(generator)
    }

    func testCompilerErrorDescriptions() throws {
        let errors: [LLVMCodeGeneratorError] = [
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

    func testLLVMEmitterCreation() throws {
        let emitter = LLVMEmitter()
        XCTAssertNotNil(emitter)
    }

    func testLLVMCodeGeneration() throws {
        // Create a simple analyzed program with Application-Start
        let dummyLocation = SourceLocation(line: 0, column: 0, offset: 0)
        let dummySpan = SourceSpan(at: dummyLocation)

        let action = Action(verb: "Log", span: dummySpan)
        let result = QualifiedNoun(base: "message", specifiers: [], span: dummySpan)
        let objectClause = ObjectClause(preposition: .for, noun: QualifiedNoun(base: "console", specifiers: [], span: dummySpan))
        let aroStatement = AROStatement(action: action, result: result, object: objectClause, literalValue: .string("Hello"), span: dummySpan)

        let featureSet = FeatureSet(
            name: "Application-Start",
            businessActivity: "Entry Point",
            statements: [aroStatement],
            span: dummySpan
        )

        let analyzedFeatureSet = AnalyzedFeatureSet(
            featureSet: featureSet,
            symbolTable: SymbolTable(scopeId: "Application-Start", scopeName: "Application-Start"),
            dataFlows: [],
            dependencies: [],
            exports: []
        )

        let program = Program(featureSets: [featureSet], span: dummySpan)
        let analyzedProgram = AnalyzedProgram(
            program: program,
            featureSets: [analyzedFeatureSet],
            globalRegistry: GlobalSymbolRegistry()
        )

        let generator = LLVMCodeGenerator()
        let result2 = try generator.generate(program: analyzedProgram)

        // Verify output contains expected LLVM IR elements
        XCTAssertTrue(result2.irText.contains("ModuleID"))
        XCTAssertTrue(result2.irText.contains("target triple"))
        XCTAssertTrue(result2.irText.contains("@aro_fs_application_start"))
        XCTAssertTrue(result2.irText.contains("@main"))
        XCTAssertTrue(result2.irText.contains("@aro_action_log"))
        XCTAssertTrue(result2.irText.contains("Hello"))
    }

    func testNoEntryPointError() throws {
        // Create a program without Application-Start
        let dummyLocation = SourceLocation(line: 0, column: 0, offset: 0)
        let dummySpan = SourceSpan(at: dummyLocation)

        let featureSet = FeatureSet(
            name: "Other-Feature",
            businessActivity: "Something",
            statements: [],
            span: dummySpan
        )

        let analyzedFeatureSet = AnalyzedFeatureSet(
            featureSet: featureSet,
            symbolTable: SymbolTable(scopeId: "Other-Feature", scopeName: "Other-Feature"),
            dataFlows: [],
            dependencies: [],
            exports: []
        )

        let program = Program(featureSets: [featureSet], span: dummySpan)
        let analyzedProgram = AnalyzedProgram(
            program: program,
            featureSets: [analyzedFeatureSet],
            globalRegistry: GlobalSymbolRegistry()
        )

        let generator = LLVMCodeGenerator()

        XCTAssertThrowsError(try generator.generate(program: analyzedProgram)) { error in
            XCTAssertTrue(error is LLVMCodeGeneratorError)
            if case LLVMCodeGeneratorError.noEntryPoint = error {
                // Expected
            } else {
                XCTFail("Expected noEntryPoint error")
            }
        }
    }
}
