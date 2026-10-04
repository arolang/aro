// ============================================================
// TestHarnessBridge.swift
// ARORuntime - C-callable entry points for a compiled test harness
// ============================================================
//
// The three exports a test-harness binary's generated `main` calls, so
// `aro test --compiled` can run colocated tests against compiled code
// (GitLab #694, part of the compiled/interpreted parity work in GitLab #838).
//
// A normal binary's `main` registers handlers and then calls
// `Application-Start`. A harness binary registers handlers, registers every
// feature-set body by name (so `When` can reach its target — a compiled binary
// has no AST to look one up in), then drives one `aro_test_run_case` per test
// feature set and finishes with `aro_test_report`, whose return value becomes
// the process exit code. `Application-Start` is deliberately never called: a
// test run must not start the application's servers or watchers.

import Foundation
import AROParser

/// Record a compiled feature-set body so `When` can invoke it by name.
///
/// - Parameters:
///   - runtimePtr: runtime handle (unused today; kept in the signature because
///     every other `aro_register_*` export takes it and the symbol is easier to
///     extend than to re-sign).
///   - namePtr: the feature set's ARO name, as written in source.
///   - bodyPtr: the compiled `ptr (*)(ptr)` body.
@_cdecl("aro_register_feature_set_body")
public func aro_register_feature_set_body(
    _ runtimePtr: UnsafeMutableRawPointer?,
    _ namePtr: UnsafePointer<CChar>?,
    _ bodyPtr: UnsafeMutableRawPointer?
) {
    guard let namePtr, let bodyPtr else { return }
    _ = runtimePtr
    CompiledFeatureSetRegistry.register(
        name: String(cString: namePtr),
        bodyAddress: Int(bitPattern: bodyPtr)
    )
}

/// Run one test feature set and record its result.
///
/// - Parameters:
///   - contextPtr: a context created by `aro_context_create_named` — the same
///     call a compiled `Application-Start` gets, so the test sees the same
///     services the application would.
///   - namePtr: test feature-set name (reported, and matched against
///     `ARO_TEST_FILTER`).
///   - bodyPtr: the compiled body to invoke.
/// - Returns: 1 when the test failed or errored, 0 otherwise (including when
///   the filter excluded it).
@_cdecl("aro_test_run_case")
public func aro_test_run_case(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ namePtr: UnsafePointer<CChar>?,
    _ activityPtr: UnsafePointer<CChar>?,
    _ bodyPtr: UnsafeMutableRawPointer?
) -> Int32 {
    guard let contextPtr, let namePtr, let bodyPtr else { return 0 }

    let name = String(cString: namePtr)
    let activity = activityPtr.map { String(cString: $0) } ?? ""

    guard CompiledTestHarness.shouldRun(name) else { return 0 }

    CompiledTestHarness.begin()

    let assertionMark = CompiledTestHarness.assertionCount
    let startTime = Date()
    let contextHandle = Unmanaged<AROCContextHandle>.fromOpaque(contextPtr).takeUnretainedValue()

    typealias BodyFunc = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    let bodyAddress = Int(bitPattern: bodyPtr)
    let contextAddress = Int(bitPattern: contextPtr)

    // The body is a compiled C function: it cannot throw, and it swallows
    // nothing either — a failure lands in the context's error slot, which the
    // generated error-exit block fills before returning null. `DeepCallStack`
    // for the same reason the user-action path uses it: a `When` inside the test
    // nests another body on this stack. Its own throw (the continuation thread
    // finished without a value) means the test never ran, which is an ERROR
    // worth reporting rather than a pass.
    var harnessError: Error?
    do {
        let returned = try DeepCallStack.run { () -> Int in
            guard let ptr = UnsafeMutableRawPointer(bitPattern: bodyAddress) else { return 0 }
            let body = unsafeBitCast(ptr, to: BodyFunc.self)
            let out = body(UnsafeMutableRawPointer(bitPattern: contextAddress))
            return Int(bitPattern: out)
        }
        if let box = UnsafeMutableRawPointer(bitPattern: returned) { aro_value_free(box) }
    } catch {
        harnessError = error
    }

    let duration = Date().timeIntervalSince(startTime)
    let assertions = CompiledTestHarness.assertions(since: assertionMark)
    let status: TestStatus

    if let harnessError {
        status = .error(compiledErrorMessage(harnessError))
    } else if let error = contextHandle.context.getExecutionError() {
        // A failed expectation and a broken statement are reported differently
        // (`FAIL` vs `ERROR`), and the interpreter tells them apart by catching
        // `AssertionError` by type. Nothing can be caught by type here: the body
        // is a C function and the bridge has already turned whatever it threw
        // into an `AROError` message. The assertion log answers the same
        // question — `Then`/`Assert` log every comparison they make, so a trailing
        // failed one means this test's last act was a failed expectation.
        if let failure = CompiledTestHarness.trailingFailureMessage(since: assertionMark) {
            status = .failed(failure)
        } else if assertions.last?.passed == false {
            status = .failed(assertionFailureMessage(error))
        } else {
            status = .error(compiledErrorMessage(error))
        }
    } else {
        status = .passed
    }

    CompiledTestHarness.record(
        TestResult(
            name: name,
            businessActivity: activity,
            status: status,
            duration: duration,
            assertions: assertions
        )
    )

    return status.isPassed ? 0 : 1
}

/// Print the suite report and answer the process exit code.
/// - Returns: 1 when any test failed or errored, 0 otherwise.
@_cdecl("aro_test_report")
public func aro_test_report() -> Int32 {
    let results = CompiledTestHarness.suiteResult()

    // Same reporter the interpreter uses, so `aro test` and
    // `aro test --compiled` print the same format and a divergence in the
    // program shows up as a difference in the results rather than in the
    // layout. `NO_COLOR` is the usual convention; `aro test --compiled`
    // forwards its own `--no-color` through it.
    let environment = ProcessInfo.processInfo.environment
    let useColors = environment["NO_COLOR"] == nil && environment["ARO_TEST_NO_COLOR"] == nil
    let verbose = environment["ARO_TEST_VERBOSE"] != nil
    TestReporter(verbose: verbose, useColors: useColors).report(results)

    if results.totalCount == 0 {
        print("No tests ran.")
        return 1
    }
    return results.hasFailures ? 1 : 0
}

// MARK: - Error classification

/// One line for a failed expectation, matching what `aro test` prints.
///
/// `AROError.message` is the reconstructed statement plus the curated hint the
/// `AssertionError` contributed (`AROError.curatedHint`) — i.e. `Cannot then the
/// <difference> with the 15. Expected difference to be 15, but was 20.` The
/// multi-line frame is right for a crash and noise for an expectation, so only
/// the message is used here.
private func assertionFailureMessage(_ error: Error) -> String {
    if let actionError = error as? ActionError,
       case .statementFailed(let aroError) = actionError {
        return aroError.message
    }
    if let assertion = error as? AssertionError {
        return assertion.message
    }
    return error.localizedDescription
}

/// Render a non-assertion failure.
///
/// `ActionError.statementFailed` already knows how to print itself — the same
/// rendering `aro_context_print_error` switched to in GitLab #692 — so the
/// compiled and interpreted messages for the same broken statement match.
private func compiledErrorMessage(_ error: Error) -> String {
    if let actionError = error as? ActionError,
       case .statementFailed(let aroError) = actionError {
        return aroError.description
    }
    return error.localizedDescription
}
