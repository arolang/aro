// ============================================================
// ResponseActionTests.swift
// ARO Runtime - Response Action Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Return Action Tests

@Suite("Return Action Tests")
struct ReturnActionTests {

    @Test("Return action role is response")
    func testReturnActionRole() {
        #expect(ReturnAction.role == .response)
    }

    @Test("Return action verbs")
    func testReturnActionVerbs() {
        #expect(ReturnAction.verbs.contains("return"))
        #expect(ReturnAction.verbs.contains("respond"))
    }

    @Test("Return action valid prepositions")
    func testReturnActionPrepositions() {
        #expect(ReturnAction.validPrepositions.contains(.for))
        #expect(ReturnAction.validPrepositions.contains(.to))
        #expect(ReturnAction.validPrepositions.contains(.with))
    }
}

// MARK: - Response Tests

@Suite("Response Type Tests")
struct ResponseTypeTests {

    @Test("Response creation with status only")
    func testResponseStatusOnly() {
        let response = Response(status: "OK")
        #expect(response.status == "OK")
        #expect(response.reason == "")
        #expect(response.data.isEmpty == true)
    }

    @Test("Response creation with reason")
    func testResponseWithReason() {
        let response = Response(status: "Error", reason: "Not found")
        #expect(response.status == "Error")
        #expect(response.reason == "Not found")
    }

    @Test("Response.ok helper")
    func testResponseOkHelper() {
        let response = Response.ok()
        #expect(response.status == "OK")
    }

    @Test("Response.error helper")
    func testResponseErrorHelper() {
        let response = Response.error("Something went wrong")
        #expect(response.status == "Error")
        #expect(response.reason == "Something went wrong")
    }
}

// MARK: - Error Response Tests

@Suite("Error Response Tests")
struct ErrorResponseTests {

    @Test("Error response creation")
    func testErrorResponse() {
        let response = Response.error("Validation failed")
        #expect(response.status == "Error")
        #expect(response.reason == "Validation failed")
    }
}

