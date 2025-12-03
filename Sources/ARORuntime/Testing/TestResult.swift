// ============================================================
// TestResult.swift
// ARO Runtime - Test Result Types
// ============================================================

import Foundation

// MARK: - Test Status

/// Status of a test execution
public enum TestStatus: Sendable, Equatable {
    case passed
    case failed(String)
    case error(String)
    case skipped(String)

    public var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .passed:
            return nil
        case .failed(let msg):
            return msg
        case .error(let msg):
            return msg
        case .skipped(let reason):
            return reason
        }
    }
}

// MARK: - Test Result

/// Result of a single test execution
public struct TestResult: Sendable {
    /// Name of the test (feature set name)
    public let name: String

    /// Business activity of the test
    public let businessActivity: String

    /// Test execution status
    public let status: TestStatus

    /// Duration in seconds
    public let duration: TimeInterval

    /// Assertions made during the test
    public let assertions: [TestAssertion]

    /// Whether the test passed
    public var passed: Bool {
        status.isPassed
    }

    public init(
        name: String,
        businessActivity: String,
        status: TestStatus,
        duration: TimeInterval,
        assertions: [TestAssertion] = []
    ) {
        self.name = name
        self.businessActivity = businessActivity
        self.status = status
        self.duration = duration
        self.assertions = assertions
    }
}

// MARK: - Test Suite Result

/// Result of running a complete test suite
public struct TestSuiteResult: Sendable {
    /// All individual test results
    public let results: [TestResult]

    /// Total execution time
    public let totalDuration: TimeInterval

    /// Total number of tests
    public var totalCount: Int { results.count }

    /// Number of passed tests
    public var passedCount: Int { results.filter { $0.passed }.count }

    /// Number of failed tests
    public var failedCount: Int { results.filter { $0.status.isFailed }.count }

    /// Number of tests with errors
    public var errorCount: Int { results.filter { $0.status.isError }.count }

    /// Number of skipped tests
    public var skippedCount: Int {
        results.filter { if case .skipped = $0.status { return true }; return false }.count
    }

    /// Whether any tests failed or errored
    public var hasFailures: Bool { failedCount > 0 || errorCount > 0 }

    /// Whether all tests passed
    public var allPassed: Bool { !hasFailures && totalCount > 0 }

    public init(results: [TestResult], totalDuration: TimeInterval) {
        self.results = results
        self.totalDuration = totalDuration
    }

    /// Get only failing test results
    public var failures: [TestResult] {
        results.filter { $0.status.isFailed || $0.status.isError }
    }
}

// MARK: - Re-export TestAssertion

// TestAssertion is defined in TestActions.swift for use by actions
// It's available through the same module
