// ============================================================
// FeatureSetTemplateTests.swift
// SOLARO — "Create new Feature Set…" source generator
// ============================================================

import Testing
@testable import SOLARO

@Suite("FeatureSetTemplate")
struct FeatureSetTemplateTests {

    @Test func minimalBlockIsHeaderPlusEmptyBraces() {
        var draft = NewFeatureSetDraft()
        draft.name = "listUsers"
        draft.businessActivity = "User API"
        let out = FeatureSetTemplate.render(draft)
        #expect(out == "(listUsers: User API) {\n}")
    }

    @Test func appendsWhenClauseWhenPresent() {
        var draft = NewFeatureSetDraft()
        draft.name = "guardedHandler"
        draft.businessActivity = "Auth API"
        draft.whenCondition = "<token: valid>"
        let out = FeatureSetTemplate.render(draft)
        #expect(out.contains("when <token: valid>"))
        #expect(out.hasSuffix("{\n}"))
    }

    @Test func actionWithTakesEmitsTypeAnnotation() {
        var draft = NewFeatureSetDraft()
        draft.name = "DoubleValue"
        draft.businessActivity = "Action"
        draft.takesField = "n"
        draft.takesType = "Integer"
        let out = FeatureSetTemplate.render(draft)
        #expect(out.contains("takes <n: Integer>"))
    }

    @Test func actionWithoutTakesTypeStillRendersTakesClause() {
        var draft = NewFeatureSetDraft()
        draft.name = "Greet"
        draft.businessActivity = "Action"
        draft.takesField = "name"
        let out = FeatureSetTemplate.render(draft)
        #expect(out.contains("takes <name>"))
        // The takes clause specifically has no `:` (no type
        // annotation). The header itself separates name and
        // activity with a colon, so we assert on the takes slice.
        #expect(!out.contains("takes <name:"))
    }

    @Test func nonActionActivitiesIgnoreTakesField() {
        // Only `Action` business activities accept a `takes` clause —
        // a `User API` FS with a stray takesField shouldn't emit it.
        var draft = NewFeatureSetDraft()
        draft.name = "listUsers"
        draft.businessActivity = "User API"
        draft.takesField = "shouldBeIgnored"
        let out = FeatureSetTemplate.render(draft)
        #expect(!out.contains("takes"))
    }

    @Test func trimsWhitespaceOnFields() {
        var draft = NewFeatureSetDraft()
        draft.name = "   listUsers   "
        draft.businessActivity = "  User API  "
        let out = FeatureSetTemplate.render(draft)
        #expect(out.contains("(listUsers: User API)"))
    }

    @Test func isReadyToCreateRequiresNameAndActivity() {
        var draft = NewFeatureSetDraft()
        #expect(!draft.isReadyToCreate)
        draft.name = "listUsers"
        #expect(!draft.isReadyToCreate)
        draft.businessActivity = "User API"
        #expect(draft.isReadyToCreate)
        draft.name = "   "
        #expect(!draft.isReadyToCreate)
    }
}
