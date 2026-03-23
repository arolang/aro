// ============================================================
// ErrorTests.swift
// ARO Runtime Tests - Error Format Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

@Suite("Error Format Tests")
struct ErrorTests {

    @Test("AROError includes business activity in description")
    func testAROErrorFormat() async throws {
        let error = AROError(
            message: "Cannot retrieve the user from the user-repository where id = 530",
            featureSet: "getUser",
            businessActivity: "User API",
            statement: "Retrieve the <user> from the <user-repository> where id = <id>",
            resolvedValues: ["id": "530"]
        )

        let description = error.description
        #expect(description.contains("Runtime Error:"))
        #expect(description.contains("Feature: getUser"))
        #expect(description.contains("Business Activity: User API"))
        #expect(description.contains("Statement:"))
    }

    @Test("fromStatement creates error with business activity")
    func testFromStatementWithBusinessActivity() async throws {
        let error = AROError.fromStatement(
            verb: "Retrieve",
            result: "user",
            preposition: "from",
            object: "user-repository",
            condition: "where id = <id>",
            featureSet: "getUser",
            businessActivity: "User API",
            resolvedValues: ["id": "530"]
        )

        #expect(error.businessActivity == "User API")
        #expect(error.description.contains("Business Activity: User API"))
    }

    @Test("Error description format matches Book specification")
    func testErrorDescriptionFormat() async throws {
        let error = AROError.fromStatement(
            verb: "Extract",
            result: "id",
            preposition: "from",
            object: "pathParameters",
            featureSet: "getUser",
            businessActivity: "User API",
            resolvedValues: [:]
        )

        let lines = error.description.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }

        // Should have exactly 4 lines: Runtime Error, Feature, Business Activity, Statement
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("Runtime Error:"))
        #expect(lines[1].hasPrefix("Feature:"))
        #expect(lines[2].hasPrefix("Business Activity:"))
        #expect(lines[3].hasPrefix("Statement:"))
    }

    @Test("Error with resolved values substitutes them in message")
    func testErrorWithResolvedValues() async throws {
        let error = AROError.fromStatement(
            verb: "Retrieve",
            result: "user",
            preposition: "from",
            object: "user-repository",
            condition: "where id = <id>",
            featureSet: "getUser",
            businessActivity: "User API",
            resolvedValues: ["id": "530"]
        )

        // The message should have <id> replaced with 530
        #expect(error.message.contains("530"))
        #expect(!error.message.contains("<id>"))

        // But the statement should keep the original <id> placeholder
        #expect(error.statement.contains("<id>"))
    }

    @Test("Error description displays business activity for Order API")
    func testOrderAPIErrorFormat() async throws {
        let error = AROError.fromStatement(
            verb: "Validate",
            result: "data",
            preposition: "against",
            object: "order-schema",
            featureSet: "createOrder",
            businessActivity: "Order API",
            resolvedValues: [:]
        )

        #expect(error.description.contains("Feature: createOrder"))
        #expect(error.description.contains("Business Activity: Order API"))
        #expect(error.message.contains("Cannot validate the data against the order-schema"))
    }
}

// MARK: - Structured ActionError Cases

@Suite("Structured ActionError Tests")
struct StructuredActionErrorTests {

    @Test("missingRequiredField carries action and field")
    func testMissingRequiredField() {
        let error = ActionError.missingRequiredField(field: "a source path", action: "Copy")
        let desc = error.description
        #expect(desc.contains("Copy"))
        #expect(desc.contains("a source path"))
    }

    @Test("invalidURL carries the offending URL")
    func testInvalidURL() {
        let error = ActionError.invalidURL("ftp://example.com")
        let desc = error.description
        #expect(desc.contains("ftp://example.com"))
        #expect(desc.contains("http://") || desc.contains("https://"))
    }

    @Test("unsupportedPlatform carries the feature name")
    func testUnsupportedPlatform() {
        let error = ActionError.unsupportedPlatform("HTTP client")
        #expect(error.description.contains("HTTP client"))
        #expect(error.description.contains("platform"))
    }

    @Test("serviceStartFailed includes service name and port")
    func testServiceStartFailedWithPort() {
        let error = ActionError.serviceStartFailed(service: "HTTP server", port: 8080)
        let desc = error.description
        #expect(desc.contains("HTTP server"))
        #expect(desc.contains("8080"))
    }

    @Test("serviceStartFailed without port omits port")
    func testServiceStartFailedWithoutPort() {
        let error = ActionError.serviceStartFailed(service: "scheduler", port: nil)
        let desc = error.description
        #expect(desc.contains("scheduler"))
        #expect(!desc.contains("port"))
    }

    @Test("invalidArgument with valid values lists them")
    func testInvalidArgumentWithValidValues() {
        let error = ActionError.invalidArgument(
            argument: "parse type",
            value: "csv",
            validValues: ["links", "content", "text", "markdown"]
        )
        let desc = error.description
        #expect(desc.contains("csv"))
        #expect(desc.contains("links"))
        #expect(desc.contains("markdown"))
    }

    @Test("invalidArgument without valid values omits list")
    func testInvalidArgumentWithoutValidValues() {
        let error = ActionError.invalidArgument(argument: "state transition", value: "bad_val", validValues: nil)
        let desc = error.description
        #expect(desc.contains("bad_val"))
        #expect(!desc.contains("Valid values"))
    }

    @Test("scopeViolation names variable and both activities")
    func testScopeViolation() {
        let error = ActionError.scopeViolation(
            variable: "config",
            sourceActivity: "Startup",
            accessedFrom: "User API"
        )
        let desc = error.description
        #expect(desc.contains("config"))
        #expect(desc.contains("Startup"))
        #expect(desc.contains("User API"))
    }

    @Test("pluginError names plugin and underlying message")
    func testPluginError() {
        let error = ActionError.pluginError(plugin: "my-plugin", underlying: "symbol not found")
        let desc = error.description
        #expect(desc.contains("my-plugin"))
        #expect(desc.contains("symbol not found"))
    }

    @Test("all new cases conform to LocalizedError")
    func testLocalizedError() {
        let cases: [ActionError] = [
            .missingRequiredField(field: "a path", action: "Make"),
            .invalidURL("bad"),
            .unsupportedPlatform("Sockets"),
            .serviceStartFailed(service: "HTTP server", port: 443),
            .invalidArgument(argument: "type", value: "x", validValues: nil),
            .scopeViolation(variable: "v", sourceActivity: "A", accessedFrom: "B"),
            .pluginError(plugin: "p", underlying: "err"),
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
            #expect(error.errorDescription == error.description)
        }
    }
}
