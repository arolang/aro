// ============================================================
// ThemeTests.swift
// SOLARO — design-token regression coverage (Swift Testing)
// ============================================================

import Testing
import SwiftUI
@testable import SOLARO

@Suite("Role colors")
struct RoleColorTests {

    @Test func mapsKnownVerbsToCorrectRoleFamily() {
        // REQUEST
        #expect(SolaroColor.roleColor(forVerb: "Extract")  == SolaroColor.roleRequest)
        #expect(SolaroColor.roleColor(forVerb: "retrieve") == SolaroColor.roleRequest)
        #expect(SolaroColor.roleColor(forVerb: "PULL")     == SolaroColor.roleRequest)

        // OWN
        #expect(SolaroColor.roleColor(forVerb: "Compute")  == SolaroColor.roleOwn)
        #expect(SolaroColor.roleColor(forVerb: "Validate") == SolaroColor.roleOwn)
        #expect(SolaroColor.roleColor(forVerb: "Create")   == SolaroColor.roleOwn)

        // RESPONSE
        #expect(SolaroColor.roleColor(forVerb: "Return")   == SolaroColor.roleResponse)
        #expect(SolaroColor.roleColor(forVerb: "Throw")    == SolaroColor.roleResponse)

        // EXPORT
        #expect(SolaroColor.roleColor(forVerb: "Emit")     == SolaroColor.roleExport)
        #expect(SolaroColor.roleColor(forVerb: "publish")  == SolaroColor.roleExport)
        #expect(SolaroColor.roleColor(forVerb: "Commit")   == SolaroColor.roleExport)
    }

    @Test func unknownVerbsFallBackToSecondaryText() {
        #expect(SolaroColor.roleColor(forVerb: "Bogus") == SolaroColor.textSecondary)
        #expect(SolaroColor.roleColor(forVerb: "")      == SolaroColor.textSecondary)
    }
}

@Suite("Wire colors")
struct WireColorTests {

    @Test func mapsKnownPrepositionsToDistinctColors() {
        #expect(SolaroColor.wireColor(forPreposition: "from")
                != SolaroColor.wireColor(forPreposition: "with"))
        #expect(SolaroColor.wireColor(forPreposition: "with")
                != SolaroColor.wireColor(forPreposition: "into"))
        #expect(SolaroColor.wireColor(forPreposition: "into")
                != SolaroColor.wireColor(forPreposition: "against"))
    }

    @Test func nilAndUnknownShareTheNeutralFallback() {
        let nilColor = SolaroColor.wireColor(forPreposition: nil)
        let unkColor = SolaroColor.wireColor(forPreposition: "bogus-preposition")
        #expect(nilColor == unkColor)
    }

    @Test func caseInsensitive() {
        #expect(SolaroColor.wireColor(forPreposition: "FROM")
                == SolaroColor.wireColor(forPreposition: "from"))
        #expect(SolaroColor.wireColor(forPreposition: "With")
                == SolaroColor.wireColor(forPreposition: "with"))
    }
}
