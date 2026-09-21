// ============================================================
// CanvasAccessibilityTests.swift
// SOLARO — what the canvas says out loud (GitLab #770)
// ============================================================
//
// Two accessibility labels in fifty-odd thousand lines, one on a status
// pill and one on a breakpoint glyph. Canvas nodes, wires, repository
// cards and notebook cells had none — so a screen-reader user had the
// text editor and nothing else, while the canvas is the product.
//
// A label is a piece of writing that gets read aloud in order, which is
// why these rules live away from the views: they can be checked as
// text.

import Testing
import Foundation
@testable import SOLARO

@Suite("Canvas accessibility")
struct CanvasAccessibilityTests {

    // MARK: - Nodes

    @Test func aNodeLeadsWithWhatTheStatementDoes() {
        // A reader scanning a canvas asks "what is this" far more
        // often than "has it run", so the statement comes first and
        // unaltered — it is already a sentence.
        let label = CanvasAccessibility.nodeLabel(
            summary: "Create the <user> with <data>.",
            line: 12, isPaused: false, hasBreakpoint: false,
            hasExecuted: false, errorMessage: nil)
        #expect(label.hasPrefix("Create the <user> with <data>."))
        #expect(label.contains("line 12"))
    }

    @Test func anExecutedNodeSaysSo() {
        let label = CanvasAccessibility.nodeLabel(
            summary: "Log \"hi\" to the <console>.", line: 3,
            isPaused: false, hasBreakpoint: false,
            hasExecuted: true, errorMessage: nil)
        #expect(label.contains("executed"))
    }

    @Test func aFailureOutranksEveryOtherState() {
        // The most important thing about a failed statement is that it
        // failed, and what it said.
        let label = CanvasAccessibility.nodeLabel(
            summary: "Retrieve the <user> from the <user-repository>.",
            line: 7, isPaused: true, hasBreakpoint: true,
            hasExecuted: true,
            errorMessage: "Can not retrieve the user where id = 530")
        #expect(label.contains("failed: Can not retrieve the user where id = 530"))
        #expect(!label.contains("executed"))
        #expect(!label.contains("paused here"))
        // A breakpoint is still worth knowing about.
        #expect(label.contains("breakpoint set"))
    }

    @Test func aPausedNodeSaysWhereTheProgramIs() {
        let label = CanvasAccessibility.nodeLabel(
            summary: "Compute the <total> from <price> * <qty>.", line: 9,
            isPaused: true, hasBreakpoint: true,
            hasExecuted: true, errorMessage: nil)
        #expect(label.contains("paused here"))
        #expect(label.contains("breakpoint set"))
    }

    @Test func liveValuesAreAValueNotALabel() {
        // So the rotor reads them only when asked, rather than making
        // every node's name twice as long.
        #expect(CanvasAccessibility.nodeValue(symbols: []) == nil)
        let value = CanvasAccessibility.nodeValue(symbols: [
            ("user", "{name: Ada}"), ("total", "42"),
        ])
        #expect(value == "user is {name: Ada}, total is 42")
    }

    @Test func aNodeHasAHintSayingWhatHappensIfYouActOnIt() {
        #expect(!CanvasAccessibility.nodeHint.isEmpty)
    }

    // MARK: - Wires, containers, repositories

    @Test func wiresReadAsACountAndAgreeOnPlurals() {
        #expect(CanvasAccessibility.wiresLabel(count: 1)
                == "1 data-flow connection between statements")
        #expect(CanvasAccessibility.wiresLabel(count: 4)
                == "4 data-flow connections between statements")
    }

    @Test func aFeatureSetReadsAsItsNameActivityAndSize() {
        #expect(CanvasAccessibility.featureSetLabel(
            name: "createUser", activity: "User API", statementCount: 4)
            == "createUser, User API, 4 statements")
        #expect(CanvasAccessibility.featureSetLabel(
            name: "ping", activity: "Health", statementCount: 1)
            == "ping, Health, 1 statement")
    }

    @Test func aRepositorySaysHowManyRecordsItHolds() {
        #expect(CanvasAccessibility.repositoryLabel(name: "user", rowCount: 3)
                == "user repository, 3 records")
        #expect(CanvasAccessibility.repositoryLabel(name: "user", rowCount: 1)
                == "user repository, 1 record")
        // Before a run there is no count, and inventing zero would be
        // a different claim from "we do not know yet".
        #expect(CanvasAccessibility.repositoryLabel(name: "user", rowCount: nil)
                == "user repository")
    }

    @Test func theRuntimePillSaysSomethingAboutTheProgram() {
        // It used to say "Runtime status", which is the name of the
        // control and nothing about the program.
        let label = CanvasAccessibility.runStateLabel("running · pid 4120")
        #expect(label == "Runtime: running · pid 4120")
    }
}
