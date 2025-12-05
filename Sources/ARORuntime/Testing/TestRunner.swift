// ============================================================
// TestRunner.swift
// ARO Runtime - Test Execution Engine
// ============================================================

import Foundation
import AROParser

// MARK: - Test Runner

/// Executes test feature sets and collects results
///
/// The TestRunner discovers test feature sets (those with business activity
/// ending in "Test" or "Tests"), executes them in isolation, and reports results.
public struct TestRunner: Sendable {
    // MARK: - Properties

    private let verbose: Bool

    // MARK: - Initialization

    public init(verbose: Bool = false) {
        self.verbose = verbose
    }

    // MARK: - Test Discovery

    /// Check if a feature set is a test
    public static func isTestFeatureSet(_ featureSet: FeatureSet) -> Bool {
        let activity = featureSet.businessActivity
        return activity.hasSuffix("Test") || activity.hasSuffix("Tests")
    }

    /// Filter test feature sets from a program
    public static func filterTests(_ featureSets: [AnalyzedFeatureSet]) -> [AnalyzedFeatureSet] {
        featureSets.filter { isTestFeatureSet($0.featureSet) }
    }

    /// Filter production (non-test) feature sets from a program
    public static func filterProduction(_ featureSets: [AnalyzedFeatureSet]) -> [AnalyzedFeatureSet] {
        featureSets.filter { !isTestFeatureSet($0.featureSet) }
    }

    // MARK: - Test Execution

    /// Run all test feature sets
    /// - Parameters:
    ///   - tests: The test feature sets to run
    ///   - allFeatureSets: All feature sets (for When action lookup)
    ///   - filter: Optional name filter pattern
    /// - Returns: Test suite result
    public func run(
        tests: [AnalyzedFeatureSet],
        allFeatureSets: [AnalyzedFeatureSet],
        filter: String? = nil
    ) async -> TestSuiteResult {
        let startTime = Date()
        var results: [TestResult] = []

        // Build feature set lookup (by name)
        let featureSetLookup = Dictionary(
            uniqueKeysWithValues: allFeatureSets.map {
                ($0.featureSet.name, $0)
            }
        )

        // Filter tests if pattern provided
        let testsToRun: [AnalyzedFeatureSet]
        if let pattern = filter {
            testsToRun = tests.filter { $0.featureSet.name.localizedCaseInsensitiveContains(pattern) }
        } else {
            testsToRun = tests
        }

        // Run each test
        for test in testsToRun {
            if verbose {
                print("  Running: \(test.featureSet.name)...")
            }

            let result = await runSingleTest(
                test,
                featureSetLookup: featureSetLookup
            )
            results.append(result)

            if verbose {
                let statusIcon = result.passed ? "PASS" : "FAIL"
                print("  [\(statusIcon)] \(test.featureSet.name)")
            }
        }

        let totalDuration = Date().timeIntervalSince(startTime)
        return TestSuiteResult(results: results, totalDuration: totalDuration)
    }

    /// Run a single test feature set
    private func runSingleTest(
        _ test: AnalyzedFeatureSet,
        featureSetLookup: [String: AnalyzedFeatureSet]
    ) async -> TestResult {
        let startTime = Date()
        let testName = test.featureSet.name
        let businessActivity = test.featureSet.businessActivity

        // Create test context with feature set lookup
        let context = TestContext(
            featureSetName: testName,
            featureSetLookup: featureSetLookup
        )

        do {
            // Execute the test feature set
            let executor = FeatureSetExecutor(
                actionRegistry: ActionRegistry.shared,
                eventBus: EventBus.shared,
                globalSymbols: GlobalSymbolStorage()
            )

            _ = try await executor.execute(test, context: context)

            // Test passed
            let duration = Date().timeIntervalSince(startTime)
            return TestResult(
                name: testName,
                businessActivity: businessActivity,
                status: .passed,
                duration: duration,
                assertions: context.assertions
            )

        } catch let error as AssertionError {
            // Assertion failed
            let duration = Date().timeIntervalSince(startTime)
            return TestResult(
                name: testName,
                businessActivity: businessActivity,
                status: .failed(error.message),
                duration: duration,
                assertions: context.assertions
            )

        } catch {
            // Other error
            let duration = Date().timeIntervalSince(startTime)
            return TestResult(
                name: testName,
                businessActivity: businessActivity,
                status: .error(error.localizedDescription),
                duration: duration,
                assertions: context.assertions
            )
        }
    }
}

// MARK: - Test Context

/// Execution context specialized for test execution
///
/// Provides feature set lookup for the When action and assertion recording.
public final class TestContext: ExecutionContext, TestExecutionContext, @unchecked Sendable {
    // MARK: - Properties

    private let lock = NSLock()
    private var variables: [String: any Sendable] = [:]
    private var services: [ObjectIdentifier: any Sendable] = [:]
    private var repositories: [String: Any] = [:]
    private var _response: Response?
    private var _assertions: [TestAssertion] = []
    private var _isWaiting: Bool = false
    private var shutdownContinuation: CheckedContinuation<Void, Error>?

    private let featureSetLookupTable: [String: AnalyzedFeatureSet]

    public let featureSetName: String
    public let executionId: String
    public let parent: ExecutionContext?

    // MARK: - Initialization

    public init(
        featureSetName: String,
        featureSetLookup: [String: AnalyzedFeatureSet],
        parent: ExecutionContext? = nil
    ) {
        self.featureSetName = featureSetName
        self.executionId = UUID().uuidString
        self.featureSetLookupTable = featureSetLookup
        self.parent = parent
    }

    // MARK: - TestExecutionContext

    public func lookupFeatureSet(_ name: String) -> AnalyzedFeatureSet? {
        // Try exact match first
        if let fs = featureSetLookupTable[name] {
            return fs
        }

        // Try with normalized name (spaces vs hyphens)
        let normalizedName = name.replacingOccurrences(of: "-", with: " ")
        if let fs = featureSetLookupTable[normalizedName] {
            return fs
        }

        // Try case-insensitive match
        for (key, fs) in featureSetLookupTable {
            if key.lowercased() == name.lowercased() ||
               key.lowercased() == normalizedName.lowercased() {
                return fs
            }
        }

        return nil
    }

    public func createChildForFeatureSet(_ name: String) -> ExecutionContext {
        TestContext(
            featureSetName: name,
            featureSetLookup: featureSetLookupTable,
            parent: self
        )
    }

    public func recordAssertion(variable: String, expected: any Sendable, actual: any Sendable, passed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _assertions.append(TestAssertion(variable: variable, expected: expected, actual: actual, passed: passed))
    }

    public var assertions: [TestAssertion] {
        lock.lock()
        defer { lock.unlock() }
        return _assertions
    }

    // MARK: - ExecutionContext Implementation

    public func resolve<T: Sendable>(_ name: String) -> T? {
        lock.lock()
        defer { lock.unlock() }

        if let value = variables[name] as? T {
            return value
        }
        return parent?.resolve(name)
    }

    public func resolveAny(_ name: String) -> (any Sendable)? {
        lock.lock()
        defer { lock.unlock() }

        if let value = variables[name] {
            return value
        }
        return parent?.resolveAny(name)
    }

    public func bind(_ name: String, value: any Sendable) {
        lock.lock()
        defer { lock.unlock() }
        variables[name] = value
    }

    public func exists(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return variables[name] != nil || (parent?.exists(name) ?? false)
    }

    public var variableNames: Set<String> {
        lock.lock()
        defer { lock.unlock() }

        var names = Set(variables.keys)
        if let parentNames = parent?.variableNames {
            names.formUnion(parentNames)
        }
        return names
    }

    public func service<S>(_ type: S.Type) -> S? {
        lock.lock()
        defer { lock.unlock() }

        if let service = services[ObjectIdentifier(type)] as? S {
            return service
        }
        return parent?.service(type)
    }

    public func register<S: Sendable>(_ service: S) {
        lock.lock()
        defer { lock.unlock() }
        services[ObjectIdentifier(S.self)] = service
    }

    public func registerWithTypeId(_ typeId: ObjectIdentifier, service: any Sendable) {
        lock.lock()
        defer { lock.unlock() }
        services[typeId] = service
    }

    public func repository<T: Sendable>(named name: String) -> (any Repository<T>)? {
        lock.lock()
        defer { lock.unlock() }

        if let repo = repositories[name] as? any Repository<T> {
            return repo
        }
        return parent?.repository(named: name)
    }

    public func registerRepository<T: Sendable>(name: String, repository: any Repository<T>) {
        lock.lock()
        defer { lock.unlock() }
        repositories[name] = repository
    }

    public func setResponse(_ response: Response) {
        lock.lock()
        defer { lock.unlock() }
        _response = response
    }

    public func getResponse() -> Response? {
        lock.lock()
        defer { lock.unlock() }
        return _response
    }

    public func emit(_ event: any RuntimeEvent) {
        EventBus.shared.publish(event)
    }

    public func createChild(featureSetName: String) -> ExecutionContext {
        createChildForFeatureSet(featureSetName)
    }

    public func enterWaitState() {
        lock.lock()
        defer { lock.unlock() }
        _isWaiting = true
    }

    public func waitForShutdown() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            shutdownContinuation = continuation
            lock.unlock()
        }
    }

    public var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isWaiting
    }

    public func signalShutdown() {
        lock.lock()
        let continuation = shutdownContinuation
        shutdownContinuation = nil
        _isWaiting = false
        lock.unlock()

        continuation?.resume(returning: ())
    }

    // MARK: - Output Context

    /// Test contexts always use developer output context
    public var outputContext: OutputContext {
        .developer
    }

    public var isDebugMode: Bool {
        true
    }

    public var isTestMode: Bool {
        true
    }
}
