// ============================================================
// TrailingDotToleranceTests.swift
// ARO Parser — tolerate `..` at end of statement (#372)
// ============================================================
//
// A run of dots at the end of a statement — typically a
// double-tapped `.` keystroke — parses the same as a single
// terminator, with no diagnostic reported. The SOLARO
// reformatter cleans the source up on the next Reformat Code
// (AROFormatter.collapseTrailingDots).

import Testing
@testable import AROParser

@Suite("Trailing dot tolerance")
struct TrailingDotToleranceTests {

    /// Parse with an inspectable diagnostics bag — the parser
    /// collects errors instead of throwing at the top level, so
    /// "parses cleanly" means the bag stays empty.
    private func parse(_ source: String)
        throws -> (program: Program, diagnostics: DiagnosticCollector)
    {
        let tokens = try Lexer(source: source).tokenize()
        let collector = DiagnosticCollector()
        let parser = Parser(tokens: tokens, diagnostics: collector)
        let program = try parser.parse()
        return (program, collector)
    }

    @Test("Double dot at end of statement parses as one terminator")
    func doubleDot() throws {
        let (program, diags) = try parse("""
        (Application-Start: Demo) {
            Log "hi" to the <console>..
        }
        """)
        #expect(!diags.hasErrors)
        let fs = try #require(program.featureSets.first)
        #expect(fs.statements.count == 1)
        let stmt = try #require(fs.statements.first as? AROStatement)
        #expect(stmt.action.verb == "Log")
    }

    @Test("Longer dot runs parse too")
    func tripleAndMoreDots() throws {
        let (program, diags) = try parse("""
        (Application-Start: Demo) {
            Log "hi" to the <console>...
            Log "ho" to the <console>.....
        }
        """)
        #expect(!diags.hasErrors)
        let fs = try #require(program.featureSets.first)
        #expect(fs.statements.count == 2)
    }

    @Test("Statement after a double-dot statement still parses")
    func statementAfterDoubleDot() throws {
        let (program, diags) = try parse("""
        (Application-Start: Demo) {
            Extract the <id> from the <request: id>..
            Return an <OK: status> with <id>.
        }
        """)
        #expect(!diags.hasErrors)
        let fs = try #require(program.featureSets.first)
        #expect(fs.statements.count == 2)
        let second = try #require(fs.statements.last as? AROStatement)
        #expect(second.action.verb == "Return")
    }

    @Test("Two double-dot statements on one line parse separately")
    func inlineStatements() throws {
        let (program, diags) = try parse(
            "(Application-Start: Demo) { Log \"a\" to the <console>.. " +
            "Log \"b\" to the <console>.. }"
        )
        #expect(!diags.hasErrors)
        let fs = try #require(program.featureSets.first)
        #expect(fs.statements.count == 2)
    }

    @Test("Publish statement tolerates a double dot")
    func publishDoubleDot() throws {
        let (program, diags) = try parse("""
        (Application-Start: Demo) {
            Create the <user> with "Ada".
            Publish as <shared-user> <user>..
        }
        """)
        #expect(!diags.hasErrors)
        let fs = try #require(program.featureSets.first)
        #expect(fs.statements.count == 2)
        #expect(fs.statements.last is PublishStatement)
    }

    @Test("Pipeline statement tolerates a double dot")
    func pipelineDoubleDot() throws {
        let (program, diags) = try parse("""
        (Application-Start: Demo) {
            Extract the <raw> from the <request: body>
                |> Transform the <clean> from the <raw>..
        }
        """)
        #expect(!diags.hasErrors)
        let fs = try #require(program.featureSets.first)
        #expect(fs.statements.count == 1)
        #expect(fs.statements.first is PipelineStatement)
    }

    @Test("Single dot still terminates exactly as before")
    func singleDotUnchanged() throws {
        let (program, diags) = try parse("""
        (Application-Start: Demo) {
            Log "hi" to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(!diags.hasErrors)
        let fs = try #require(program.featureSets.first)
        #expect(fs.statements.count == 2)
    }

    @Test("Missing terminator still reports a parse error")
    func missingDotStillFails() throws {
        let (_, diags) = try parse("""
        (Application-Start: Demo) {
            Log "hi" to the <console>
        }
        """)
        #expect(diags.hasErrors)
    }
}
