// ============================================================
// TestActions.swift
// ARO Runtime - Test Framework Action Implementations
// ============================================================

import Foundation
import AROParser

// MARK: - Given Action

/// Sets up test data by binding a value to a variable
///
/// The Given action is used to establish the initial state for a test.
/// It binds a literal value or resolved variable to the result name.
///
/// ## Syntax
/// ```aro
/// <Given> the <variable> with <value>.
/// <Given> the <request> with { email: "test@example.com" }.
/// ```
public struct GivenAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["given"]
    public static let validPrepositions: Set<Preposition> = [.with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Priority: literal value > expression > resolved variable
        let value: any Sendable

        if let literalValue = context.resolveAny("_literal_") {
            value = literalValue
        } else if let expressionValue = context.resolveAny("_expression_") {
            value = expressionValue
        } else if let resolvedValue = context.resolveAny(object.base) {
            value = resolvedValue
        } else {
            // Return the object base as a literal string if nothing else matches
            value = object.base
        }

        // Bind to result name
        context.bind(result.base, value: value)

        return value
    }
}

// MARK: - When Action

/// Executes a feature set and captures the result
///
/// The When action invokes another feature set by name and stores the response.
///
/// ## Syntax
/// ```aro
/// <When> the <result> from the <Add-Numbers> feature.
/// <When> the <response> from the <CreateUser> feature with <request>.
/// ```
public struct WhenAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["when"]
    public static let validPrepositions: Set<Preposition> = [.from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Check if this is a test context with feature set lookup
        guard let testContext = context as? TestExecutionContext else {
            throw ActionError.runtimeError(
                "When action requires test execution context (got \(type(of: context))). Use 'aro test' command."
            )
        }

        // Parse feature set name from object
        // object.base might be "add-numbers" or "CreateUser"
        // Keep the original name - lookupFeatureSet handles normalization
        let featureSetName = object.base

        guard let featureSet = testContext.lookupFeatureSet(featureSetName) else {
            throw ActionError.runtimeError(
                "Feature set not found: '\(featureSetName)'"
            )
        }

        // Create child context with current bindings
        let childContext = testContext.createChildForFeatureSet(featureSetName)

        // Copy variable bindings to child context (test inputs)
        for name in testContext.variableNames {
            if let value = testContext.resolveAny(name) {
                // Map test variable to feature set input
                // e.g., <a> in test becomes <a> in feature set
                childContext.bind(name, value: value)
            }
        }

        // Execute the feature set
        let executor = FeatureSetExecutor(
            actionRegistry: ActionRegistry.shared,
            eventBus: EventBus.shared,
            globalSymbols: GlobalSymbolStorage()
        )

        let response = try await executor.execute(featureSet, context: childContext)

        // Extract result from response data
        // Try to get the primary result value
        let resultValue: any Sendable
        if !response.data.isEmpty {
            // Get the first value from response data
            if let firstValue = response.data.values.first?.get() as (any Sendable)? {
                resultValue = firstValue
            } else {
                resultValue = response
            }
        } else {
            resultValue = response
        }

        // Bind result
        context.bind(result.base, value: resultValue)

        return resultValue
    }
}

// MARK: - Then Action

/// Asserts a condition with "should be" matcher
///
/// The Then action verifies that a value matches an expected result.
///
/// ## Syntax
/// ```aro
/// <Then> the <result> should be 8.
/// <Then> the <response>.status should be 201.
/// ```
public struct ThenAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["then"]
    public static let validPrepositions: Set<Preposition> = [.with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // result.base is the variable to check
        // Specifiers may contain "should", "be" from parsing

        guard let actualValue = context.resolveAny(result.base) else {
            throw AssertionError(
                message: "Variable '\(result.base)' is undefined",
                expected: nil,
                actual: nil,
                variable: result.base
            )
        }

        // Get expected value from literal, expression, or object
        let expectedValue: any Sendable
        if let literalValue = context.resolveAny("_literal_") {
            expectedValue = literalValue
        } else if let expressionValue = context.resolveAny("_expression_") {
            expectedValue = expressionValue
        } else if let objectValue = context.resolveAny(object.base) {
            expectedValue = objectValue
        } else {
            expectedValue = object.base
        }

        // Record assertion in test context
        if let testContext = context as? TestExecutionContext {
            testContext.recordAssertion(
                variable: result.base,
                expected: expectedValue,
                actual: actualValue,
                passed: valuesEqual(actualValue, expectedValue)
            )
        }

        // Compare values
        if !valuesEqual(actualValue, expectedValue) {
            throw AssertionError(
                message: "Expected \(result.base) to be \(expectedValue), but was \(actualValue)",
                expected: expectedValue,
                actual: actualValue,
                variable: result.base
            )
        }

        return true
    }

    private func valuesEqual(_ a: any Sendable, _ b: any Sendable) -> Bool {
        // Integer comparison
        if let aInt = a as? Int, let bInt = b as? Int { return aInt == bInt }
        if let aInt = a as? Int, let bDouble = b as? Double { return Double(aInt) == bDouble }
        if let aDouble = a as? Double, let bInt = b as? Int { return aDouble == Double(bInt) }

        // Double comparison
        if let aDouble = a as? Double, let bDouble = b as? Double {
            return abs(aDouble - bDouble) < 0.0001
        }

        // String comparison
        if let aStr = a as? String, let bStr = b as? String { return aStr == bStr }

        // Bool comparison
        if let aBool = a as? Bool, let bBool = b as? Bool { return aBool == bBool }

        // Response comparison (check status)
        if let aResponse = a as? Response {
            if let bStr = b as? String { return aResponse.status == bStr }
            if let bInt = b as? Int { return aResponse.status == String(bInt) }
        }

        // Fallback to string representation
        return String(describing: a) == String(describing: b)
    }
}

// MARK: - Assert Action

/// Direct assertion for equality
///
/// The Assert action verifies that a value equals an expected value.
///
/// ## Syntax
/// ```aro
/// <Assert> that <user-repo id> is <1>.
/// <Assert> that <count> is <5>.
/// ```
public struct AssertAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["assert"]
    public static let validPrepositions: Set<Preposition> = [.for, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // result.base is the variable to check
        guard let actualValue = context.resolveAny(result.base) else {
            throw AssertionError(
                message: "Variable '\(result.base)' is undefined",
                expected: nil,
                actual: nil,
                variable: result.base
            )
        }

        // Get expected value
        let expectedValue: any Sendable
        if let literalValue = context.resolveAny("_literal_") {
            expectedValue = literalValue
        } else if let expressionValue = context.resolveAny("_expression_") {
            expectedValue = expressionValue
        } else if let objectValue = context.resolveAny(object.base) {
            expectedValue = objectValue
        } else {
            expectedValue = object.base
        }

        // Record assertion
        if let testContext = context as? TestExecutionContext {
            testContext.recordAssertion(
                variable: result.base,
                expected: expectedValue,
                actual: actualValue,
                passed: valuesEqual(actualValue, expectedValue)
            )
        }

        // Perform assertion
        if !valuesEqual(actualValue, expectedValue) {
            throw AssertionError(
                message: "Assertion failed: \(result.base) is \(actualValue), expected \(expectedValue)",
                expected: expectedValue,
                actual: actualValue,
                variable: result.base
            )
        }

        return true
    }

    private func valuesEqual(_ a: any Sendable, _ b: any Sendable) -> Bool {
        if let aInt = a as? Int, let bInt = b as? Int { return aInt == bInt }
        if let aInt = a as? Int, let bDouble = b as? Double { return Double(aInt) == bDouble }
        if let aDouble = a as? Double, let bInt = b as? Int { return aDouble == Double(bInt) }
        if let aDouble = a as? Double, let bDouble = b as? Double {
            return abs(aDouble - bDouble) < 0.0001
        }
        if let aStr = a as? String, let bStr = b as? String { return aStr == bStr }
        if let aBool = a as? Bool, let bBool = b as? Bool { return aBool == bBool }
        return String(describing: a) == String(describing: b)
    }
}

// MARK: - Assertion Error

/// Error thrown when a test assertion fails
public struct AssertionError: Error, LocalizedError, Sendable {
    public let message: String
    public let expected: (any Sendable)?
    public let actual: (any Sendable)?
    public let variable: String

    public init(
        message: String,
        expected: (any Sendable)?,
        actual: (any Sendable)?,
        variable: String
    ) {
        self.message = message
        self.expected = expected
        self.actual = actual
        self.variable = variable
    }

    public var errorDescription: String? {
        message
    }
}

// MARK: - Test Execution Context Protocol

/// Extended execution context for test execution
public protocol TestExecutionContext: ExecutionContext {
    /// Look up a feature set by name
    func lookupFeatureSet(_ name: String) -> AnalyzedFeatureSet?

    /// Create a child context for executing a feature set
    func createChildForFeatureSet(_ name: String) -> ExecutionContext

    /// Record an assertion result
    func recordAssertion(variable: String, expected: any Sendable, actual: any Sendable, passed: Bool)

    /// Get all recorded assertions
    var assertions: [TestAssertion] { get }
}

// MARK: - Test Assertion

/// Records a single assertion made during test execution
public struct TestAssertion: Sendable {
    public let variable: String
    public let expectedDescription: String
    public let actualDescription: String
    public let passed: Bool

    public init(variable: String, expected: any Sendable, actual: any Sendable, passed: Bool) {
        self.variable = variable
        self.expectedDescription = String(describing: expected)
        self.actualDescription = String(describing: actual)
        self.passed = passed
    }
}
