// ============================================================
// CLIErrorFormatterTests.swift
// ARO CLI — the error sentences a runner gets to read
// ============================================================

import Foundation
import Testing
@testable import AROCLI
@testable import ARORuntime

enum NoConformanceError: Error {
    case payload(label: String)
}

enum AuthoredError: Error, CustomStringConvertible {
    case broke(String)
    var description: String { "the program broke, and the author said so" }
}

struct BothFoxes: Error, LocalizedError, CustomStringConvertible {
    var errorDescription: String? { "the localized sentence" }
    var description: String { "the described sentence" }
}

/// CLIErrorFormatter picks the human sentence, and the pick cannot depend on
/// the host's Foundation: Darwin surfaces a `CustomStringConvertible` error's
/// own description through `localizedDescription`, corelibs-foundation does
/// not — so the Linux oracle job printed
/// "The operation could not be completed. (ARORuntime.ExpressionError error
/// 0.)" where a Mac printed "Undefined variable: never-defined-name"
/// (train:oracle, the sequel to #900). The formatter reads the conformance
/// directly, so both hosts print the author's sentence.
@Suite("CLI Error Rendering")
struct CLIErrorFormatterTests {

    @Test("an authored description is what the author wrote, on every host")
    func authoredDescriptionWins() {
        let error = AuthoredError.broke("x")
        #expect(CLIErrorFormatter.describe(error) == "the program broke, and the author said so")
    }

    @Test("the runtime's ExpressionError keeps its sentence (the Linux regression)")
    func expressionErrorKeepsItsSentence() {
        let error = ExpressionError.undefinedVariable("never-defined-name")
        #expect(CLIErrorFormatter.describe(error) == "Undefined variable: never-defined-name")
    }

    @Test("LocalizedError outranks CustomStringConvertible when both match")
    func localizedWins() {
        #expect(CLIErrorFormatter.describe(BothFoxes()) == "the localized sentence")
    }

    @Test("no conformance: the last-resort case name, never an opaque NSError")
    func caseNameLastResort() {
        // The generic NSError spellings both platforms emit must not survive
        // the formatter: "couldn't" is Darwin's, "could not" is corelibs'.
        let rendered = CLIErrorFormatter.describe(NoConformanceError.payload(label: "x"))
        #expect(!rendered.hasPrefix("The operation could"))
        #expect(rendered.contains("payload"))
    }
}
