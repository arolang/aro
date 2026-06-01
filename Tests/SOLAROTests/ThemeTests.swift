// ============================================================
// ThemeTests.swift
// SOLARO — Phase 2: design-token regression tests
// ============================================================

import XCTest
@testable import SOLARO
import SwiftUI

final class ThemeTests: XCTestCase {

    // MARK: - Role colors

    func testRoleColorMapsKnownVerbsToCorrectFamily() {
        // REQUEST family
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "Extract"),  SolaroColor.roleRequest)
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "retrieve"), SolaroColor.roleRequest)
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "PULL"),     SolaroColor.roleRequest)

        // OWN family
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "Compute"),   SolaroColor.roleOwn)
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "Validate"),  SolaroColor.roleOwn)
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "Create"),    SolaroColor.roleOwn)

        // RESPONSE family
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "Return"),    SolaroColor.roleResponse)
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "Throw"),     SolaroColor.roleResponse)

        // EXPORT family
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "Emit"),      SolaroColor.roleExport)
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "publish"),   SolaroColor.roleExport)
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "Commit"),    SolaroColor.roleExport)
    }

    func testRoleColorFallsBackToSecondaryForUnknownVerb() {
        XCTAssertEqual(SolaroColor.roleColor(forVerb: "Bogus"),     SolaroColor.textSecondary)
        XCTAssertEqual(SolaroColor.roleColor(forVerb: ""),          SolaroColor.textSecondary)
    }

    // MARK: - Wire colors

    func testWireColorMapsKnownPrepositions() {
        // Distinct colors for from / with / into / against — they
        // need to be visually distinguishable in the canvas.
        XCTAssertNotEqual(SolaroColor.wireColor(forPreposition: "from"),
                          SolaroColor.wireColor(forPreposition: "with"))
        XCTAssertNotEqual(SolaroColor.wireColor(forPreposition: "with"),
                          SolaroColor.wireColor(forPreposition: "into"))
        XCTAssertNotEqual(SolaroColor.wireColor(forPreposition: "into"),
                          SolaroColor.wireColor(forPreposition: "against"))
    }

    func testWireColorFallsBackForNilOrUnknown() {
        // Nil and unknown collapse to the same "neutral" wire color.
        let nilColor = SolaroColor.wireColor(forPreposition: nil)
        let unkColor = SolaroColor.wireColor(forPreposition: "bogus-preposition")
        XCTAssertEqual(nilColor, unkColor)
    }

    func testWireColorIsCaseInsensitive() {
        XCTAssertEqual(SolaroColor.wireColor(forPreposition: "FROM"),
                       SolaroColor.wireColor(forPreposition: "from"))
        XCTAssertEqual(SolaroColor.wireColor(forPreposition: "With"),
                       SolaroColor.wireColor(forPreposition: "with"))
    }
}
