// ============================================================
// GraphDiffRangeTests.swift
// SOLARO — comparing two revisions, not one (GitLab #767)
// ============================================================
//
// The graph-diff view took one typed revision and always compared it
// against the working tree, while the CLI has supported main..my-branch
// ranges the whole time. A reviewer's actual question is "what did this
// branch change in the graph", which needs both ends.

import Testing
import Foundation
@testable import SOLARO

@Suite("Graph diff range")
@MainActor
struct GraphDiffRangeTests {

    @Test func defaultsToComparingHeadAgainstTheWorkingTree() {
        let model = GraphDiffModel()
        // What the view has always done, and still does unless asked
        // for something else.
        #expect(model.baseRevision == "HEAD")
        #expect(model.targetRevision.isEmpty)
        #expect(model.rangeExpression == "HEAD")
    }

    @Test func twoRevisionsReadAsARange() {
        let model = GraphDiffModel()
        model.baseRevision = "main"
        model.targetRevision = "topic"
        // The same spelling the CLI takes, so the export below can
        // simply hand it over.
        #expect(model.rangeExpression == "main..topic")
    }

    @Test func aPastedRangeSplitsAcrossBothFields() {
        let model = GraphDiffModel()
        model.setRange("main..feature/graph")
        #expect(model.baseRevision == "main")
        #expect(model.targetRevision == "feature/graph")
        #expect(model.rangeExpression == "main..feature/graph")
    }

    @Test func aSingleRevisionClearsTheOtherSide() {
        let model = GraphDiffModel()
        model.setRange("main..topic")
        model.setRange("HEAD~3")
        // Otherwise the previous target would silently survive and the
        // comparison would not be the one on screen.
        #expect(model.baseRevision == "HEAD~3")
        #expect(model.targetRevision.isEmpty)
        #expect(model.rangeExpression == "HEAD~3")
    }

    @Test func surroundingSpaceIsIgnored() {
        let model = GraphDiffModel()
        model.setRange("  main..topic  ")
        #expect(model.baseRevision == "main")
        #expect(model.targetRevision == "topic")
    }

    @Test func aRangeWithAnEmptySideMeansTheWorkingTree() {
        let model = GraphDiffModel()
        model.setRange("main..")
        #expect(model.baseRevision == "main")
        #expect(model.targetRevision.isEmpty)
        #expect(model.rangeExpression == "main")
    }

    @Test func aCommitHashIsAcceptedLikeAnyOtherRevision() {
        // A reviewer often wants a commit or a tag, which is why there
        // is a typed field as well as a branch menu.
        let model = GraphDiffModel()
        model.setRange("9f56dbdd..HEAD")
        #expect(model.baseRevision == "9f56dbdd")
        #expect(model.targetRevision == "HEAD")
    }
}
