// ============================================================
// BuildLinkModeCodeGenTests.swift
// AROCompiler Tests - the link mode travels with the binary (GitLab #618)
// ============================================================
//
// Whether a compiled binary may load a plugin shared object is decided when it
// is linked, so the answer has to be written into the binary. The generated
// `main` calls `aro_set_build_link_mode` before anything registers or loads a
// plugin; the interpreter never runs that code and keeps its own default.

import XCTest
@testable import AROCompiler
@testable import AROParser

#if !os(Windows)

final class BuildLinkModeCodeGenTests: XCTestCase {

    /// The smallest program the generator accepts: one Application-Start.
    private func minimalProgram() -> AnalyzedProgram {
        let span = SourceSpan(at: SourceLocation(line: 0, column: 0, offset: 0))
        let statement = AROStatement(
            action: Action(verb: "Log", span: span),
            result: QualifiedNoun(base: "message", specifiers: [], span: span),
            object: ObjectClause(
                preposition: .for,
                noun: QualifiedNoun(base: "console", specifiers: [], span: span)
            ),
            valueSource: .literal(.string("Hello")),
            span: span
        )
        let featureSet = FeatureSet(
            name: "Application-Start",
            businessActivity: "Entry Point",
            statements: [statement],
            span: span
        )
        let analyzed = AnalyzedFeatureSet(
            featureSet: featureSet,
            symbolTable: SymbolTable(scopeId: "Application-Start", scopeName: "Application-Start"),
            dataFlows: [],
            dependencies: [],
            exports: []
        )
        return AnalyzedProgram(
            program: Program(featureSets: [featureSet], span: span),
            featureSets: [analyzed],
            globalRegistry: GlobalSymbolRegistry()
        )
    }

    func testStaticLinkModeIsRecordedInMain() throws {
        let ir = try LLVMCodeGenerator()
            .generate(program: minimalProgram(), linkMode: CCompiler.LinkMode.staticLink.recordedName)
            .irText

        XCTAssertTrue(
            ir.contains("call void @aro_set_build_link_mode"),
            "generated main must record the link mode it was built with"
        )
        XCTAssertTrue(
            ir.contains(#"static\00"#),
            "the recorded mode should be the static one"
        )
    }

    func testDynamicLinkModeIsRecordedInMain() throws {
        let ir = try LLVMCodeGenerator()
            .generate(program: minimalProgram(), linkMode: CCompiler.LinkMode.dynamicLink.recordedName)
            .irText

        XCTAssertTrue(ir.contains("call void @aro_set_build_link_mode"))
        XCTAssertTrue(ir.contains(#"dynamic\00"#))
    }

    func testNoLinkModeEmitsNoCall() throws {
        // Callers that do not produce an executable (tests, `--emit-llvm`
        // experiments) leave it out, and the runtime keeps its default.
        let ir = try LLVMCodeGenerator().generate(program: minimalProgram()).irText
        XCTAssertFalse(ir.contains("call void @aro_set_build_link_mode"))
    }
}

#endif
