// ============================================================
// ComputeActionTests.swift
// ARO Runtime - Compute Action Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Compute Action Tests

@Suite("Compute Action Tests")
struct ComputeActionTests {

    func createDescriptors(
        resultBase: String = "result",
        resultSpecifiers: [String] = [],
        objectBase: String = "input",
        objectSpecifiers: [String] = [],
        preposition: Preposition = .from
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: objectSpecifiers, span: span)
        return (result, object)
    }

    @Test("Compute action role is own")
    func testComputeActionRole() {
        #expect(ComputeAction.role == .own)
    }

    @Test("Compute action verbs")
    func testComputeActionVerbs() {
        #expect(ComputeAction.verbs.contains("compute"))
        #expect(ComputeAction.verbs.contains("calculate"))
        #expect(ComputeAction.verbs.contains("derive"))
    }

    @Test("Compute action valid prepositions")
    func testComputeActionPrepositions() {
        #expect(ComputeAction.validPrepositions.contains(.from))
        #expect(ComputeAction.validPrepositions.contains(.for))
        #expect(ComputeAction.validPrepositions.contains(.with))
    }

    @Test("Compute hash of string")
    func testComputeHash() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("password", value: "secret123")

        let (result, object) = createDescriptors(resultBase: "hash", resultSpecifiers: ["hash"], objectBase: "password")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? Int != nil)
    }

    @Test("Compute length of string")
    func testComputeLength() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("text", value: "Hello World")

        let (result, object) = createDescriptors(resultBase: "len", resultSpecifiers: ["length"], objectBase: "text")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? Int == 11)
    }

    @Test("Compute count of array")
    func testComputeCount() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("items", value: [1, 2, 3, 4, 5] as [any Sendable])

        let (result, object) = createDescriptors(resultBase: "total", resultSpecifiers: ["count"], objectBase: "items")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? Int == 5)
    }

    @Test("Compute uppercase of string")
    func testComputeUppercase() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("text", value: "hello")

        let (result, object) = createDescriptors(resultBase: "upper", resultSpecifiers: ["uppercase"], objectBase: "text")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "HELLO")
    }

    @Test("Compute lowercase of string")
    func testComputeLowercase() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("text", value: "HELLO")

        let (result, object) = createDescriptors(resultBase: "lower", resultSpecifiers: ["lowercase"], objectBase: "text")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "hello")
    }

    @Test("Compute identity returns input")
    func testComputeIdentity() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("data", value: "test value")

        let (result, object) = createDescriptors(resultBase: "output", resultSpecifiers: ["identity"], objectBase: "data")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "test value")
    }

    @Test("Compute with undefined variable throws error")
    func testComputeUndefinedVariable() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")

        let (result, object) = createDescriptors(resultBase: "result", objectBase: "missing")

        do {
            _ = try await action.execute(result: result, object: object, context: context)
            #expect(Bool(false), "Should have thrown error")
        } catch let error as ActionError {
            #expect(error.localizedDescription.contains("missing"))
        }
    }

    @Test("Compute with invalid preposition throws error")
    func testComputeInvalidPreposition() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "test")

        let (result, object) = createDescriptors(objectBase: "input", preposition: .against)

        do {
            _ = try await action.execute(result: result, object: object, context: context)
            #expect(Bool(false), "Should have thrown error")
        } catch {
            #expect(true)
        }
    }

    @Test("Compute length of dictionary")
    func testComputeDictLength() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("dict", value: ["a": 1, "b": 2, "c": 3] as [String: any Sendable])

        let (result, object) = createDescriptors(resultBase: "size", resultSpecifiers: ["count"], objectBase: "dict")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? Int == 3)
    }

    @Test("Compute with legacy syntax (base is operation name)")
    func testComputeLegacySyntax() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("text", value: "hello world")

        // Legacy syntax: <length> is both variable name and operation
        let (result, object) = createDescriptors(resultBase: "length", resultSpecifiers: [], objectBase: "text")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? Int == 11)
    }
}

// MARK: - Validate Action Tests

@Suite("Validate Action Tests")
struct ValidateActionTests {

    func createDescriptors(
        resultBase: String = "validation",
        resultSpecifiers: [String] = [],
        objectBase: String = "input",
        preposition: Preposition = .for
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    @Test("Validate action role is own")
    func testValidateActionRole() {
        #expect(ValidateAction.role == .own)
    }

    @Test("Validate action verbs")
    func testValidateActionVerbs() {
        #expect(ValidateAction.verbs.contains("validate"))
        #expect(ValidateAction.verbs.contains("verify"))
        #expect(ValidateAction.verbs.contains("check"))
    }

    @Test("Validate required with value")
    func testValidateRequired() async throws {
        let action = ValidateAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "has value")

        let (result, object) = createDescriptors(resultSpecifiers: ["required"])
        let value = try await action.execute(result: result, object: object, context: context)

        let validationResult = value as? ValidationResult
        #expect(validationResult?.isValid == true)
    }

    @Test("Validate required with empty string fails")
    func testValidateRequiredEmpty() async throws {
        let action = ValidateAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "")

        let (result, object) = createDescriptors(resultSpecifiers: ["required"])
        let value = try await action.execute(result: result, object: object, context: context)

        let validationResult = value as? ValidationResult
        #expect(validationResult?.isValid == false)
    }

    @Test("Validate email with valid email")
    func testValidateEmailValid() async throws {
        let action = ValidateAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "test@example.com")

        let (result, object) = createDescriptors(resultSpecifiers: ["email"])
        let value = try await action.execute(result: result, object: object, context: context)

        let validationResult = value as? ValidationResult
        #expect(validationResult?.isValid == true)
    }

    @Test("Validate email with invalid email")
    func testValidateEmailInvalid() async throws {
        let action = ValidateAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "not-an-email")

        let (result, object) = createDescriptors(resultSpecifiers: ["email"])
        let value = try await action.execute(result: result, object: object, context: context)

        let validationResult = value as? ValidationResult
        #expect(validationResult?.isValid == false)
    }

    @Test("Validate numeric with number")
    func testValidateNumericValid() async throws {
        let action = ValidateAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: 42)

        let (result, object) = createDescriptors(resultSpecifiers: ["numeric"])
        let value = try await action.execute(result: result, object: object, context: context)

        let validationResult = value as? ValidationResult
        #expect(validationResult?.isValid == true)
    }

    @Test("Validate numeric with numeric string")
    func testValidateNumericString() async throws {
        let action = ValidateAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "123.45")

        let (result, object) = createDescriptors(resultSpecifiers: ["numeric"])
        let value = try await action.execute(result: result, object: object, context: context)

        let validationResult = value as? ValidationResult
        #expect(validationResult?.isValid == true)
    }
}

// MARK: - Compare Action Tests

@Suite("Compare Action Tests")
struct CompareActionTests {

    func createDescriptors(
        resultBase: String,
        objectBase: String,
        preposition: Preposition = .against
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    @Test("Compare action role is own")
    func testCompareActionRole() {
        #expect(CompareAction.role == .own)
    }

    @Test("Compare action verbs")
    func testCompareActionVerbs() {
        #expect(CompareAction.verbs.contains("compare"))
        #expect(CompareAction.verbs.contains("match"))
    }

    @Test("Compare equal integers")
    func testCompareEqualIntegers() async throws {
        let action = CompareAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("a", value: 42)
        context.bind("b", value: 42)

        let (result, object) = createDescriptors(resultBase: "a", objectBase: "b")
        let value = try await action.execute(result: result, object: object, context: context)

        let comparisonResult = value as? ARORuntime.ComparisonResult
        #expect(comparisonResult?.matches == true)
        #expect(comparisonResult?.result == .equal)
    }

    @Test("Compare unequal integers")
    func testCompareUnequalIntegers() async throws {
        let action = CompareAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("a", value: 10)
        context.bind("b", value: 20)

        let (result, object) = createDescriptors(resultBase: "a", objectBase: "b")
        let value = try await action.execute(result: result, object: object, context: context)

        let comparisonResult = value as? ARORuntime.ComparisonResult
        #expect(comparisonResult?.matches == false)
        #expect(comparisonResult?.result == .less)
    }

    @Test("Compare equal strings")
    func testCompareEqualStrings() async throws {
        let action = CompareAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("a", value: "hello")
        context.bind("b", value: "hello")

        let (result, object) = createDescriptors(resultBase: "a", objectBase: "b")
        let value = try await action.execute(result: result, object: object, context: context)

        let comparisonResult = value as? ARORuntime.ComparisonResult
        #expect(comparisonResult?.matches == true)
    }
}

// MARK: - Transform Action Tests

@Suite("Transform Action Tests")
struct TransformActionTests {

    func createDescriptors(
        resultBase: String,
        resultSpecifiers: [String] = [],
        objectBase: String,
        preposition: Preposition = .from
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    @Test("Transform action role is own")
    func testTransformActionRole() {
        #expect(TransformAction.role == .own)
    }

    @Test("Transform to string")
    func testTransformToString() async throws {
        let action = TransformAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: 42)

        let (result, object) = createDescriptors(resultBase: "output", resultSpecifiers: ["string"], objectBase: "input")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "42")
    }

    @Test("Transform to int")
    func testTransformToInt() async throws {
        let action = TransformAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "123")

        let (result, object) = createDescriptors(resultBase: "output", resultSpecifiers: ["int"], objectBase: "input")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? Int == 123)
    }

    @Test("Transform to double")
    func testTransformToDouble() async throws {
        let action = TransformAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "3.14")

        let (result, object) = createDescriptors(resultBase: "output", resultSpecifiers: ["double"], objectBase: "input")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? Double == 3.14)
    }

    @Test("Transform to bool true")
    func testTransformToBoolTrue() async throws {
        let action = TransformAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "true")

        let (result, object) = createDescriptors(resultBase: "output", resultSpecifiers: ["bool"], objectBase: "input")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? Bool == true)
    }
}

// MARK: - Create Action Tests

@Suite("Create Action Tests")
struct CreateActionTests {

    func createDescriptors(
        resultBase: String,
        resultSpecifiers: [String] = [],
        objectBase: String,
        preposition: Preposition = .with
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    @Test("Create action role is own")
    func testCreateActionRole() {
        #expect(CreateAction.role == .own)
    }

    @Test("Create action verbs")
    func testCreateActionVerbs() {
        #expect(CreateAction.verbs.contains("create"))
        #expect(CreateAction.verbs.contains("build"))
        #expect(CreateAction.verbs.contains("construct"))
        // Note: "make" verb moved to MakeAction for filesystem operations
    }

    @Test("Create returns source value")
    func testCreateReturnsSource() async throws {
        let action = CreateAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("data", value: ["name": "John"] as [String: any Sendable])

        let (result, object) = createDescriptors(resultBase: "user", objectBase: "data")
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        #expect(dict?["name"] as? String == "John")
    }

    @Test("Create with type specifier generates ID")
    func testCreateGeneratesId() async throws {
        let action = CreateAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("data", value: ["name": "John"] as [String: any Sendable])

        let (result, object) = createDescriptors(resultBase: "user", resultSpecifiers: ["User"], objectBase: "data")
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        #expect(dict?["id"] != nil)
    }
}

// MARK: - Update Action Tests

@Suite("Update Action Tests")
struct UpdateActionTests {

    func createDescriptors(
        resultBase: String,
        resultSpecifiers: [String] = [],
        objectBase: String,
        preposition: Preposition = .with
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    @Test("Update action role is own")
    func testUpdateActionRole() {
        #expect(UpdateAction.role == .own)
    }

    @Test("Update action verbs")
    func testUpdateActionVerbs() {
        #expect(UpdateAction.verbs.contains("update"))
        #expect(UpdateAction.verbs.contains("modify"))
        #expect(UpdateAction.verbs.contains("change"))
        #expect(UpdateAction.verbs.contains("set"))
    }

    @Test("Update specific field")
    func testUpdateField() async throws {
        let action = UpdateAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("entity", value: ["name": "John", "status": "active"] as [String: any Sendable])
        context.bind("newStatus", value: "inactive")

        let (result, object) = createDescriptors(resultBase: "entity", resultSpecifiers: ["status"], objectBase: "newStatus")
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        #expect(dict?["status"] as? String == "inactive")
        #expect(dict?["name"] as? String == "John")
    }
}

// MARK: - Sort Action Tests

@Suite("Sort Action Tests")
struct SortActionTests {

    func createDescriptors(
        resultBase: String,
        resultSpecifiers: [String] = [],
        objectBase: String,
        preposition: Preposition = .for
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    @Test("Sort action role is own")
    func testSortActionRole() {
        #expect(SortAction.role == .own)
    }

    @Test("Sort string array ascending")
    func testSortAscending() async throws {
        let action = SortAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("items", value: ["c", "a", "b"])

        let (result, object) = createDescriptors(resultBase: "sorted", resultSpecifiers: ["ascending"], objectBase: "items")
        let value = try await action.execute(result: result, object: object, context: context)

        let sorted = value as? [String]
        #expect(sorted == ["a", "b", "c"])
    }

    @Test("Sort int array")
    func testSortIntArray() async throws {
        let action = SortAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("numbers", value: [3, 1, 4, 1, 5])

        let (result, object) = createDescriptors(resultBase: "sorted", objectBase: "numbers")
        let value = try await action.execute(result: result, object: object, context: context)

        let sorted = value as? [Int]
        #expect(sorted == [1, 1, 3, 4, 5])
    }
}

// MARK: - Merge Action Tests

@Suite("Merge Action Tests")
struct MergeActionTests {

    func createDescriptors(
        resultBase: String,
        objectBase: String,
        preposition: Preposition = .with
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: resultBase, specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: [], span: span)
        return (result, object)
    }

    @Test("Merge action role is own")
    func testMergeActionRole() {
        #expect(MergeAction.role == .own)
    }

    @Test("Merge action verbs")
    func testMergeActionVerbs() {
        #expect(MergeAction.verbs.contains("merge"))
        #expect(MergeAction.verbs.contains("combine"))
        #expect(MergeAction.verbs.contains("join"))
        #expect(MergeAction.verbs.contains("concat"))
    }

    @Test("Merge dictionaries")
    func testMergeDictionaries() async throws {
        let action = MergeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("base", value: ["a": 1] as [String: any Sendable])
        context.bind("extra", value: ["b": 2] as [String: any Sendable])

        let (result, object) = createDescriptors(resultBase: "base", objectBase: "extra")
        let value = try await action.execute(result: result, object: object, context: context)

        let dict = value as? [String: any Sendable]
        #expect(dict?["a"] as? Int == 1)
        #expect(dict?["b"] as? Int == 2)
    }

    @Test("Merge strings")
    func testMergeStrings() async throws {
        let action = MergeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("first", value: "Hello, ")
        context.bind("second", value: "World!")

        let (result, object) = createDescriptors(resultBase: "first", objectBase: "second")
        let value = try await action.execute(result: result, object: object, context: context)

        #expect(value as? String == "Hello, World!")
    }
}

// MARK: - Delete Action Tests

@Suite("Delete Action Tests")
struct DeleteActionTests {

    @Test("Delete action role is own")
    func testDeleteActionRole() {
        #expect(DeleteAction.role == .own)
    }

    @Test("Delete action verbs")
    func testDeleteActionVerbs() {
        #expect(DeleteAction.verbs.contains("delete"))
        #expect(DeleteAction.verbs.contains("remove"))
        #expect(DeleteAction.verbs.contains("destroy"))
        #expect(DeleteAction.verbs.contains("clear"))
    }
}

// MARK: - Supporting Types Tests

@Suite("Supporting Types Tests")
struct SupportingTypesTests {

    @Test("ValidationResult creation")
    func testValidationResult() {
        let result = ValidationResult(isValid: true, rule: "required", message: nil)
        #expect(result.isValid == true)
        #expect(result.rule == "required")
        #expect(result.message == nil)
    }

    @Test("ValidationResult with message")
    func testValidationResultWithMessage() {
        let result = ValidationResult(isValid: false, rule: "email", message: "Invalid email format")
        #expect(result.isValid == false)
        #expect(result.message == "Invalid email format")
    }

    @Test("ComparisonResult creation")
    func testComparisonResult() {
        let result = ComparisonResult(matches: true, result: .equal)
        #expect(result.matches == true)
        #expect(result.result == .equal)
    }

    @Test("ComparisonOutcome values")
    func testComparisonOutcome() {
        #expect(ComparisonOutcome.equal.rawValue == "equal")
        #expect(ComparisonOutcome.notEqual.rawValue == "notEqual")
        #expect(ComparisonOutcome.less.rawValue == "less")
        #expect(ComparisonOutcome.greater.rawValue == "greater")
    }

    @Test("DeleteResult creation")
    func testDeleteResult() {
        let result = DeleteResult(target: "item", success: true)
        #expect(result.target == "item")
        #expect(result.success == true)
    }

    @Test("CreatedEntity creation")
    func testCreatedEntity() {
        let entity = CreatedEntity(type: "User", data: ["name": "John"])
        #expect(entity.type == "User")
        #expect(entity.data["name"] as? String == "John")
    }
}
