// ============================================================
// CompiledTestHarness.swift
// ARO Runtime - Running colocated tests inside a compiled binary
// ============================================================
//
// `aro test` only ever ran the interpreter (GitLab #694). The compiled path
// stripped every test feature set out of the binary — ARO-0015 §5.3 called that
// "test stripping" and it is still the right default for a shipped binary — but
// it also meant no `Given`/`When`/`Then` was ever evaluated by the code
// generator. Every compiled-mode divergence tracked by GitLab #838 (the `when`
// block, the missing `aro_action_touch` export, the error-message shape) was
// therefore invisible to the language's own test command: a green `aro test`
// said nothing about the binary a user ships.
//
// This file is the runtime half of `aro test --compiled`. A test-harness binary
// (`aro build --tests`) keeps its test feature sets, registers every feature-set
// body by name, and its generated `main` drives them through `aro_test_run_case`
// instead of calling `Application-Start`. Results are tallied here and reported
// with the same `TestReporter` the interpreter uses, so the two modes produce
// the same output format and can be compared line for line.

import Foundation
import AROParser

// MARK: - Compiled feature-set registry

/// Name → address of a compiled feature-set body (`ptr (*)(ptr)`).
///
/// The interpreter's `When` action resolves its target through
/// `TestExecutionContext.lookupFeatureSet`, which hands back an
/// `AnalyzedFeatureSet` for the executor to walk. A compiled binary has no AST
/// at run time — each feature set is a native function — so the harness binary
/// registers those functions here at startup and `When` dispatches through the
/// table instead.
///
/// Thread safety is the lock below; the dictionary is only written during
/// startup and only read afterwards, but `When` can run from any thread the
/// deep-call-stack machinery has moved onto.
public enum CompiledFeatureSetRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [String: Int] = [:]

    /// Record a compiled feature-set body under its ARO name.
    public static func register(name: String, bodyAddress: Int) {
        lock.lock()
        defer { lock.unlock() }
        bodies[name] = bodyAddress
    }

    /// Whether any body has been registered — i.e. whether this process is a
    /// test-harness binary at all.
    public static var isPopulated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !bodies.isEmpty
    }

    /// Resolve a feature-set name to its compiled body.
    ///
    /// The same three-step normalisation `TestContext.lookupFeatureSet` applies,
    /// and for the same reason: a test writes `When the <len> from the
    /// <get-length>.` and the feature set may be declared `get-length`,
    /// `get length` or `Get-Length`. The two lookups must agree, or a test that
    /// passes interpreted fails compiled for a reason that has nothing to do
    /// with the program.
    public static func lookup(_ name: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }

        if let address = bodies[name] { return address }

        let normalized = name.replacingOccurrences(of: "-", with: " ")
        if let address = bodies[normalized] { return address }

        for (key, address) in bodies {
            if key.lowercased() == name.lowercased() || key.lowercased() == normalized.lowercased() {
                return address
            }
        }
        return nil
    }
}

// MARK: - Harness state

/// Per-process state for a running test-harness binary.
public enum CompiledTestHarness {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var results: [TestResult] = []
    nonisolated(unsafe) private static var assertionLog: [LoggedAssertion] = []
    nonisolated(unsafe) private static var started: Date?
    nonisolated(unsafe) private static var active = false

    /// True once the harness has begun running cases.
    ///
    /// Read by `aro_context_print_error`: a feature set's error-exit block
    /// prints the context's error itself, which is right for `aro run`-shaped
    /// output but would print each failure twice in a test run — once raw, once
    /// as the reporter's `FAIL` line. The harness owns the reporting, so the
    /// raw print is suppressed while it is driving.
    public static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// `--filter` is a run-time choice but a compiled binary is built once, so
    /// the filter travels in the environment rather than being baked in.
    /// Matching is the same `localizedCaseInsensitiveContains` the interpreter's
    /// `TestRunner` uses.
    public static func shouldRun(_ name: String) -> Bool {
        guard let pattern = ProcessInfo.processInfo.environment["ARO_TEST_FILTER"],
              !pattern.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(pattern)
    }

    public static func begin() {
        lock.lock()
        defer { lock.unlock() }
        active = true
        if started == nil { started = Date() }
    }

    public static func record(_ result: TestResult) {
        lock.lock()
        defer { lock.unlock() }
        results.append(result)
    }

    /// `Then` and `Assert` record every comparison they make into a
    /// `TestExecutionContext`, which is how `aro test` can print the
    /// per-assertion breakdown under `--verbose`. A compiled context is a
    /// `RuntimeContext` and cannot be one — it has no AST to look a feature set
    /// up in — so in a harness binary the two actions log here instead.
    ///
    /// A process-wide log is enough because the generated `main` runs test cases
    /// one at a time, in source order; `assertions(since:)` slices out the ones
    /// belonging to the case that just ran.
    /// - Parameter failureMessage: the message the action is about to throw,
    ///   when the comparison failed. It is carried rather than recomposed so
    ///   `aro test --compiled` prints the same sentence `aro test` does — the
    ///   compiled error path cannot keep the `AssertionError` itself, and the
    ///   statement it reconstructs instead reads `Cannot then the len with the
    ///   _expression_.`, which is not what a test failure should say.
    public static func recordAssertion(_ assertion: TestAssertion, failureMessage: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        assertionLog.append(LoggedAssertion(assertion: assertion, failureMessage: failureMessage))
    }

    public static var assertionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return assertionLog.count
    }

    public static func assertions(since mark: Int) -> [TestAssertion] {
        lock.lock()
        defer { lock.unlock() }
        guard mark < assertionLog.count else { return [] }
        return assertionLog[mark...].map(\.assertion)
    }

    /// The message of the last failed assertion since `mark`, if the run ended
    /// on one. `nil` means the failure was not an expectation.
    public static func trailingFailureMessage(since mark: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = assertionLog.last, assertionLog.count > mark, !last.assertion.passed else {
            return nil
        }
        return last.failureMessage
    }

    private struct LoggedAssertion {
        let assertion: TestAssertion
        let failureMessage: String?
    }

    /// Everything run so far, as the suite result `TestReporter` expects.
    public static func suiteResult() -> TestSuiteResult {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        return TestSuiteResult(results: results, totalDuration: elapsed)
    }

    /// Reset, for the unit tests that drive the harness in-process.
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        results = []
        assertionLog = []
        started = nil
        active = false
    }
}

// MARK: - Calling a compiled feature set from `When`

/// Invoke a compiled feature-set body on behalf of the `When` action.
///
/// Mirrors what `WhenAction` does in the interpreter: a child context that can
/// see the test's `Given` bindings, the body, then the primary value out of the
/// response. The differences are forced by the compiled world and are all in
/// the comments below.
///
/// Returns `nil` when this process has no compiled body of that name, which is
/// how `WhenAction` tells "I am interpreted" from "I am a harness binary and
/// that feature set does not exist".
func invokeCompiledFeatureSet(
    named featureSetName: String,
    resultBase: String,
    caller: ExecutionContext
) throws -> (any Sendable)? {
    guard CompiledFeatureSetRegistry.isPopulated else { return nil }
    guard let bodyAddress = CompiledFeatureSetRegistry.lookup(featureSetName) else {
        throw ActionError.featureSetNotFound(featureSetName)
    }
    guard let callerRuntime = caller as? RuntimeContext,
          let runtimePtr = globalRuntimePtr else {
        return nil
    }

    // The `When` statement's own modifiers are spent. A compiled binary has no
    // per-statement scope — the generated code binds `_with_` / `_literal_` /
    // `_expression_` straight onto the feature set's context — so without this
    // the callee's first statement would read the caller's modifiers as its own
    // payload. The compiled user-action path clears them for exactly this
    // reason (GitLab #887).
    caller.clearTransientFrameworkVariables()

    guard let childContext = callerRuntime.createChild(featureSetName: featureSetName) as? RuntimeContext else {
        return nil
    }

    let runtimeHandle = Unmanaged<AROCRuntimeHandle>.fromOpaque(runtimePtr).takeUnretainedValue()
    let childHandle = AROCContextHandle(runtime: runtimeHandle, existingContext: childContext)
    let childPtr = Unmanaged.passRetained(childHandle).toOpaque()
    defer { Unmanaged<AROCContextHandle>.fromOpaque(childPtr).release() }

    // The child is parented to the test's context and is NOT marked a call-frame
    // root: a `When` target is meant to see the test's `Given` bindings, which
    // is what the interpreter achieves by copying every binding across. A user
    // action is the opposite case and does mark the root.
    typealias BodyFunc = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    let childAddress = Int(bitPattern: childPtr)
    let returnedAddress = try DeepCallStack.run { () -> Int in
        guard let bodyPtr = UnsafeMutableRawPointer(bitPattern: bodyAddress) else { return 0 }
        let body = unsafeBitCast(bodyPtr, to: BodyFunc.self)
        let out = body(UnsafeMutableRawPointer(bitPattern: childAddress))
        return Int(bitPattern: out)
    }
    if let returned = UnsafeMutableRawPointer(bitPattern: returnedAddress) { aro_value_free(returned) }

    // A compiled body reports failure by leaving an error on its context and
    // returning null — it cannot throw across the C ABI. Re-raise it here so the
    // test fails at the `When` statement, as it does interpreted.
    if let error = childContext.getExecutionError() {
        throw error
    }

    return compiledResponseValue(from: childContext, resultBase: resultBase)
}

/// Pull the value a `When` should bind out of the callee's response.
///
/// `Return … with <len>.` records its payload in `Response.payload` when the value
/// is structured and in `data` otherwise (GitLab #504), so both are consulted —
/// the name the test asked for first, then the single value a one-value response
/// carries, which is what makes `When the <sum> from the <add-numbers>.` work
/// when the callee named its result something else.
private func compiledResponseValue(
    from context: RuntimeContext,
    resultBase: String
) -> any Sendable {
    guard let response = context.getResponse() else {
        return context.resolveAny(resultBase) ?? ""
    }

    // `payload` is the shape the feature set produced (#504). `data` is the
    // flattened transport rendering of it, computed on each access since #711
    // — so it is read once into a local here rather than four times.
    if let structured = response.payload[resultBase] { return structured }
    let flat = response.data
    if let named = flat[resultBase]?.get() as (any Sendable)? { return named }
    if response.payload.count == 1, let only = response.payload.values.first { return only }
    if flat.count == 1, let only = flat.values.first?.get() as (any Sendable)? { return only }
    if let bound = context.resolveAny(resultBase) { return bound }
    if let first = flat.values.first?.get() as (any Sendable)? { return first }
    return response
}
