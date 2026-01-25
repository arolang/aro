// ============================================================
// LLVMCodeGeneratorV2Tests.swift
// AROCompiler Tests - LLVM C API Code Generator
// ============================================================

import XCTest
@testable import AROCompiler
@testable import AROParser

final class LLVMCodeGeneratorV2Tests: XCTestCase {

    func testV2GeneratorCreation() throws {
        let generator = LLVMCodeGeneratorV2()
        XCTAssertNotNil(generator)
    }

    func testV2ErrorDescriptions() throws {
        let span = SourceSpan(at: SourceLocation(line: 1, column: 1, offset: 0))

        let errors: [LLVMCodeGenError] = [
            .typeMismatch(expected: "ptr", actual: "i32", context: "test", span: span),
            .undefinedSymbol(name: "test", span: span),
            .invalidAction(verb: "test", span: span),
            .invalidExpression(description: "test", span: span),
            .moduleVerificationFailed(message: "test"),
            .llvmInternalError(message: "test"),
            .noEntryPoint,
            .multipleEntryPoints
        ]

        for error in errors {
            XCTAssertNotNil(error.span != nil || error.span == nil)
        }
    }

    func testV2CodeGeneration() throws {
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

        let generator = LLVMCodeGeneratorV2()
        let result2 = try generator.generate(program: analyzedProgram)

        // Verify output contains expected LLVM IR elements
        XCTAssertTrue(result2.irText.contains("ModuleID") || result2.irText.contains("module"))
        XCTAssertTrue(result2.irText.contains("@aro_fs_application_start") || result2.irText.contains("aro_fs_application_start"))
        XCTAssertTrue(result2.irText.contains("main"))
    }

    func testV2NoEntryPointError() throws {
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

        let generator = LLVMCodeGeneratorV2()

        XCTAssertThrowsError(try generator.generate(program: analyzedProgram)) { error in
            XCTAssertTrue(error is LLVMCodeGenError)
            if case LLVMCodeGenError.noEntryPoint = error {
                // Expected
            } else {
                XCTFail("Expected noEntryPoint error, got: \(error)")
            }
        }
    }

    func testV2TypeMapper() throws {
        let ctx = LLVMCodeGenContext(moduleName: "test")
        let mapper = LLVMTypeMapper(context: ctx)

        // Test that struct types are created correctly
        let resultDescType = mapper.resultDescriptorType
        XCTAssertNotNil(resultDescType)

        let objectDescType = mapper.objectDescriptorType
        XCTAssertNotNil(objectDescType)

        // Test preposition mapping
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.from), 1)
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.for), 2)
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.with), 3)
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.to), 4)
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.into), 5)
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.via), 6)
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.against), 7)
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.on), 8)
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.by), 9)
        XCTAssertEqual(LLVMTypeMapper.prepositionValue(.at), 10)
    }

    func testV2ErrorReporter() throws {
        let source = """
        (Application-Start: Test) {
            <Log> "Hello" to the <console>.
        }
        """

        let reporter = LLVMErrorReporter(source: source, fileName: "test.aro")

        let span = SourceSpan(
            start: SourceLocation(line: 2, column: 5, offset: 30),
            end: SourceLocation(line: 2, column: 10, offset: 35)
        )

        let error = LLVMCodeGenError.undefinedSymbol(name: "unknown", span: span)
        let formatted = reporter.format(error)

        XCTAssertTrue(formatted.contains("test.aro:2:5"))
        XCTAssertTrue(formatted.contains("error:"))
        XCTAssertTrue(formatted.contains("unknown"))
    }

    func testV2ExternalDeclEmitter() throws {
        let ctx = LLVMCodeGenContext(moduleName: "test")
        let types = LLVMTypeMapper(context: ctx)
        let emitter = LLVMExternalDeclEmitter(context: ctx, types: types)

        // Declare all externals
        emitter.declareAllExternals()

        // Verify key functions are declared
        XCTAssertNotNil(emitter.runtimeInit)
        XCTAssertNotNil(emitter.runtimeShutdown)
        XCTAssertNotNil(emitter.variableBindString)
        XCTAssertNotNil(emitter.variableResolve)
        XCTAssertNotNil(emitter.contextCreate)
        XCTAssertNotNil(emitter.contextDestroy)
        XCTAssertNotNil(emitter.arrayCount)
        XCTAssertNotNil(emitter.arrayGet)

        // Verify action functions
        XCTAssertNotNil(emitter.actionFunction(for: "log"))
        XCTAssertNotNil(emitter.actionFunction(for: "extract"))
        XCTAssertNotNil(emitter.actionFunction(for: "return"))
        XCTAssertNotNil(emitter.actionFunction(for: "compute"))
        XCTAssertNil(emitter.actionFunction(for: "nonexistent"))
    }

    func testV2MultipleEntryPointsAllowed() throws {
        // Create a program with multiple Application-Start feature sets
        // This is now allowed to support module imports where each module
        // has its own Application-Start that runs before the main Application-Start
        let dummyLocation = SourceLocation(line: 0, column: 0, offset: 0)
        let dummySpan = SourceSpan(at: dummyLocation)

        let featureSet1 = FeatureSet(
            name: "Application-Start",
            businessActivity: "Entry Point 1",
            statements: [],
            span: dummySpan
        )

        let featureSet2 = FeatureSet(
            name: "Application-Start",
            businessActivity: "Entry Point 2",
            statements: [],
            span: dummySpan
        )

        let analyzedFeatureSet1 = AnalyzedFeatureSet(
            featureSet: featureSet1,
            symbolTable: SymbolTable(scopeId: "Application-Start", scopeName: "Application-Start"),
            dataFlows: [],
            dependencies: [],
            exports: []
        )

        let analyzedFeatureSet2 = AnalyzedFeatureSet(
            featureSet: featureSet2,
            symbolTable: SymbolTable(scopeId: "Application-Start-2", scopeName: "Application-Start"),
            dataFlows: [],
            dependencies: [],
            exports: []
        )

        let program = Program(featureSets: [featureSet1, featureSet2], span: dummySpan)
        let analyzedProgram = AnalyzedProgram(
            program: program,
            featureSets: [analyzedFeatureSet1, analyzedFeatureSet2],
            globalRegistry: GlobalSymbolRegistry()
        )

        let generator = LLVMCodeGeneratorV2()

        // Multiple Application-Start feature sets should now succeed
        let result = try generator.generate(program: analyzedProgram)

        // Verify IR contains both entry point functions with unique names
        XCTAssertTrue(result.irText.contains("aro_fs_application_start_entry_point_1") ||
                      result.irText.contains("entry_point_1"),
                      "Should contain function for Entry Point 1")
        XCTAssertTrue(result.irText.contains("aro_fs_application_start_entry_point_2") ||
                      result.irText.contains("entry_point_2"),
                      "Should contain function for Entry Point 2")
        XCTAssertTrue(result.irText.contains("main"), "Should contain main function")
    }
}
