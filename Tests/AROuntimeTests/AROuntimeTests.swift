// ============================================================
// ARORuntimeTests.swift
// ARO Runtime - Unit Tests
// ============================================================

import XCTest
@testable import ARORuntime

final class ARORuntimeTests: XCTestCase {

    func testRuntimeContextCreation() throws {
        let context = RuntimeContext(featureSetName: "Test")
        XCTAssertNotNil(context)
    }
}
