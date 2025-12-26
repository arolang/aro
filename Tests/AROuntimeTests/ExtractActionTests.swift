// ============================================================
// ExtractActionTests.swift
// ARO Runtime - Extract Action Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Extract Action Tests

@Suite("Extract Action Tests")
struct ExtractActionTests {

    func createDescriptors(
        resultBase: String = "result",
        resultSpecifiers: [String] = [],
        objectBase: String = "source",
        objectSpecifiers: [String] = [],
        preposition: Preposition = .from
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: objectSpecifiers, span: span)
        return (result, object)
    }

    @Test("Extract action role is request")
    func testExtractActionRole() {
        #expect(ExtractAction.role == .request)
    }

    @Test("Extract action verbs")
    func testExtractActionVerbs() {
        #expect(ExtractAction.verbs.contains("extract"))
        #expect(ExtractAction.verbs.contains("parse"))
        #expect(ExtractAction.verbs.contains("get"))
    }

    @Test("Extract action valid prepositions")
    func testExtractActionPrepositions() {
        #expect(ExtractAction.validPrepositions.contains(.from))
        #expect(ExtractAction.validPrepositions.contains(.via))
    }

    @Test("Extract simple value")
    func testExtractSimpleValue() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("source", value: "test value")

        let (result, object) = createDescriptors()
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "test value")
    }

    @Test("Extract nested property from dictionary")
    func testExtractNestedProperty() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("user", value: ["name": "John", "age": 30] as [String: any Sendable])

        let (result, object) = createDescriptors(objectBase: "user", objectSpecifiers: ["name"])
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "John")
    }

    @Test("Extract deeply nested property")
    func testExtractDeeplyNested() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("data", value: [
            "user": ["profile": ["email": "test@example.com"]]
        ] as [String: any Sendable])

        let (result, object) = createDescriptors(objectBase: "data", objectSpecifiers: ["user", "profile", "email"])
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "test@example.com")
    }

    @Test("Extract from array by index")
    func testExtractFromArray() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("items", value: ["first", "second", "third"] as [any Sendable])

        let (result, object) = createDescriptors(objectBase: "items", objectSpecifiers: ["1"])
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "second")
    }

    @Test("Extract with undefined variable throws error")
    func testExtractUndefinedVariable() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")

        let (result, object) = createDescriptors(objectBase: "missing")

        do {
            _ = try await action.execute(result: result, object: object, context: context)
            #expect(Bool(false), "Should have thrown error")
        } catch let error as ActionError {
            #expect(error.localizedDescription.contains("missing"))
        }
    }

    @Test("Extract with invalid preposition throws error")
    func testExtractInvalidPreposition() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("source", value: "test")

        let (result, object) = createDescriptors(preposition: .with)

        do {
            _ = try await action.execute(result: result, object: object, context: context)
            #expect(Bool(false), "Should have thrown error")
        } catch {
            #expect(true)
        }
    }

    @Test("Extract from JSON string")
    func testExtractFromJSONString() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("json", value: "{\"name\": \"John\", \"age\": 30}")

        let (result, object) = createDescriptors(objectBase: "json", objectSpecifiers: ["name"])
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "John")
    }

    @Test("Extract from form-urlencoded data")
    func testExtractFromFormData() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("form", value: "name=John&age=30")

        let (result, object) = createDescriptors(objectBase: "form", objectSpecifiers: ["name"])
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "John")
    }

    @Test("Extract from key-value format")
    func testExtractFromKeyValue() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("headers", value: "Content-Type: application/json\nHost: example.com")

        let (result, object) = createDescriptors(objectBase: "headers", objectSpecifiers: ["Host"])
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "example.com")
    }

    @Test("Extract parses JSON object without specifiers")
    func testExtractParsesJSON() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("json", value: "{\"id\": 1, \"name\": \"Test\"}")

        let (result, object) = createDescriptors(objectBase: "json")
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        #expect(dict?["id"] as? Int == 1)
        #expect(dict?["name"] as? String == "Test")
    }

    @Test("Extract property not found throws error")
    func testExtractPropertyNotFound() async throws {
        let action = ExtractAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("user", value: ["name": "John"] as [String: any Sendable])

        let (result, object) = createDescriptors(objectBase: "user", objectSpecifiers: ["nonexistent"])

        do {
            _ = try await action.execute(result: result, object: object, context: context)
            #expect(Bool(false), "Should have thrown error")
        } catch let error as ActionError {
            #expect(error.localizedDescription.contains("nonexistent"))
        }
    }
}

// MARK: - Retrieve Action Tests

@Suite("Retrieve Action Tests")
struct RetrieveActionTests {

    func createDescriptors(
        resultBase: String = "result",
        objectBase: String = "source",
        objectSpecifiers: [String] = []
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: objectBase, specifiers: objectSpecifiers, span: span)
        return (result, object)
    }

    @Test("Retrieve action role is request")
    func testRetrieveActionRole() {
        #expect(RetrieveAction.role == .request)
    }

    @Test("Retrieve action verbs")
    func testRetrieveActionVerbs() {
        #expect(RetrieveAction.verbs.contains("retrieve"))
        #expect(RetrieveAction.verbs.contains("fetch"))
        #expect(RetrieveAction.verbs.contains("load"))
        #expect(RetrieveAction.verbs.contains("find"))
    }

    @Test("Retrieve from variable")
    func testRetrieveFromVariable() async throws {
        let action = RetrieveAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("data", value: "test value")

        let (result, object) = createDescriptors(objectBase: "data")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "test value")
    }

    @Test("Retrieve with undefined source throws error")
    func testRetrieveUndefined() async throws {
        let action = RetrieveAction()
        let context = RuntimeContext(featureSetName: "Test")

        let (result, object) = createDescriptors(objectBase: "missing")

        do {
            _ = try await action.execute(result: result, object: object, context: context)
            #expect(Bool(false), "Should have thrown error")
        } catch {
            #expect(true)
        }
    }
}

// MARK: - Receive Action Tests

@Suite("Receive Action Tests")
struct ReceiveActionTests {

    @Test("Receive action role is request")
    func testReceiveActionRole() {
        #expect(ReceiveAction.role == .request)
    }

    @Test("Receive action verbs")
    func testReceiveActionVerbs() {
        #expect(ReceiveAction.verbs.contains("receive"))
    }

    @Test("Receive resolves source")
    func testReceiveSource() async throws {
        let action = ReceiveAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("data", value: "received data")

        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "result", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "data", specifiers: [], span: span)

        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "received data")
    }
}

// MARK: - Fetch Action Tests

@Suite("Fetch Action Tests")
struct FetchActionTests {

    @Test("Fetch action role is request")
    func testFetchActionRole() {
        #expect(FetchAction.role == .request)
    }

    @Test("Fetch action verbs")
    func testFetchActionVerbs() {
        #expect(FetchAction.verbs.contains("fetch"))
        #expect(FetchAction.verbs.contains("call"))
    }

    @Test("Fetch falls back to variable resolution")
    func testFetchFallback() async throws {
        let action = FetchAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("url", value: "http://example.com")

        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "result", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "url", specifiers: [], span: span)

        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "http://example.com")
    }
}

// MARK: - Read Action Tests

@Suite("Read Action Tests")
struct ReadActionTests {

    @Test("Read action role is request")
    func testReadActionRole() {
        #expect(ReadAction.role == .request)
    }

    @Test("Read action verbs")
    func testReadActionVerbs() {
        #expect(ReadAction.verbs.contains("read"))
    }

    @Test("Read action valid prepositions")
    func testReadActionPrepositions() {
        #expect(ReadAction.validPrepositions.contains(.from))
    }

    @Test("Read without file service throws error")
    func testReadWithoutService() async throws {
        let action = ReadAction()
        let context = RuntimeContext(featureSetName: "Test")

        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "content", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "file.txt", specifiers: [], span: span)

        do {
            _ = try await action.execute(result: result, object: object, context: context)
            #expect(Bool(false), "Should have thrown error")
        } catch let error as ActionError {
            #expect(error.localizedDescription.contains("FileSystemService"))
        }
    }
}
