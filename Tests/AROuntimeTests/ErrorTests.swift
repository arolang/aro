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
            statement: "<Retrieve> the <user> from the <user-repository> where id = <id>",
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
