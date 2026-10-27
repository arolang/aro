// ============================================================
// CompiledTestHarnessTests.swift
// AROCLI — `aro test --compiled` (GitLab #694)
// ============================================================
//
// `aro test` only ever ran the interpreter, so a green test run said nothing
// about the binary a user ships — which is why the compiled-mode divergences
// tracked by GitLab #838 went unnoticed. `--compiled` builds a test-harness
// binary and runs the same test feature sets through compiled code.
//
// These are the parts that can be asserted without an LLVM toolchain and a
// 30-second link: the naming rule the harness and the stripper share, the
// name resolution a compiled `When` does, and the harness's own tally. The
// end-to-end run (`aro test --compiled ./Examples/AssertDemo` matching
// `aro test ./Examples/AssertDemo` line for line) is in the MR's verification
// section rather than here, because a unit test that links a binary would
// dominate the suite's runtime.

import Testing
import Foundation
import AROParser
@testable import ARORuntime
@testable import AROCLI

// Serialized: `CompiledTestHarness` and the feature-set registry are
// process-wide by design — a compiled binary has exactly one test run in it —
// so cases that touch them cannot run in parallel with each other.
@Suite("`aro test --compiled` (GitLab #694)", .serialized)
struct CompiledTestHarnessTests {

    // MARK: - The naming rule all three users share

    @Test("A business activity ending in Test or Tests names a test feature set")
    func testNamingRule() {
        #expect(TestFeatureSetNaming.isTest(activity: "Calculator Test"))
        #expect(TestFeatureSetNaming.isTest(activity: "String Utils Tests"))
        #expect(!TestFeatureSetNaming.isTest(activity: "Calculator"))
        #expect(!TestFeatureSetNaming.isTest(activity: "Testing Service"))
    }

    /// Stripping (ARO-0015 §5.3) and harnessing are exact complements: a test
    /// the build strips but the harness lists would be a call to a function
    /// that was never emitted. Both now ask the same question.
    @Test("TestRunner and the compiler agree on which feature sets are tests")
    func testRunnerAgreesWithCompiler() {
        let test = FeatureSet(
            name: "addition-test", businessActivity: "Calculator Test",
            statements: [], span: SourceSpan(at: SourceLocation()))
        let production = FeatureSet(
            name: "add-numbers", businessActivity: "Calculator",
            statements: [], span: SourceSpan(at: SourceLocation()))

        #expect(TestRunner.isTestFeatureSet(test)
                == TestFeatureSetNaming.isTest(activity: test.businessActivity))
        #expect(TestRunner.isTestFeatureSet(production)
                == TestFeatureSetNaming.isTest(activity: production.businessActivity))
    }

    // MARK: - Name resolution for a compiled `When`

    /// A compiled binary has no AST, so `When the <len> from the <get-length>.`
    /// resolves through a table of function pointers instead of
    /// `TestExecutionContext.lookupFeatureSet`. The two must normalise names
    /// the same way, or a test that passes interpreted fails compiled for a
    /// reason that has nothing to do with the program.
    @Test("The compiled registry normalises names the way TestContext does")
    func testRegistryNormalisation() {
        CompiledFeatureSetRegistry.register(name: "get length", bodyAddress: 0x1234)
        CompiledFeatureSetRegistry.register(name: "Make-Uppercase", bodyAddress: 0x5678)

        #expect(CompiledFeatureSetRegistry.lookup("get length") == 0x1234)
        // hyphens in the call site, spaces in the declaration
        #expect(CompiledFeatureSetRegistry.lookup("get-length") == 0x1234)
        // case-insensitive
        #expect(CompiledFeatureSetRegistry.lookup("make-uppercase") == 0x5678)
        #expect(CompiledFeatureSetRegistry.lookup("no-such-feature-set") == nil)
    }

    @Test("An unpopulated registry means this process is not a harness binary")
    func testRegistryEmptyMeansInterpreted() {
        // `WhenAction` uses this to tell "I am interpreted" (fall through to the
        // `TestExecutionContext` error) from "I am a harness binary and that
        // feature set does not exist" (a hard failure naming the target).
        #expect(CompiledFeatureSetRegistry.lookup("anything-at-all-\(UUID().uuidString)") == nil)
    }

    // MARK: - The harness tally

    @Test("The harness reports a suite the same way TestReporter expects")
    func testTallyAndExitCode() {
        CompiledTestHarness.reset()
        #expect(!CompiledTestHarness.isActive)

        CompiledTestHarness.begin()
        #expect(CompiledTestHarness.isActive)

        CompiledTestHarness.record(TestResult(
            name: "passing", businessActivity: "X Test",
            status: .passed, duration: 0.001))
        CompiledTestHarness.record(TestResult(
            name: "failing", businessActivity: "X Test",
            status: .failed("Expected len to be 7, but was 5"), duration: 0.001))

        let suite = CompiledTestHarness.suiteResult()
        #expect(suite.totalCount == 2)
        #expect(suite.passedCount == 1)
        #expect(suite.failedCount == 1)
        #expect(suite.hasFailures)

        CompiledTestHarness.reset()
    }

    /// `aro test --compiled` must fail the way `aro test` does, so the failure
    /// message has to be the same sentence. It is carried from the action
    /// rather than recomposed, because the compiled error path turns the thrown
    /// `AssertionError` into a reconstructed statement
    /// (`Cannot then the len with the _expression_.`) and loses the type.
    @Test("A failed expectation's message survives into the compiled report")
    func testTrailingFailureMessage() {
        CompiledTestHarness.reset()
        CompiledTestHarness.begin()

        let mark = CompiledTestHarness.assertionCount
        CompiledTestHarness.recordAssertion(
            TestAssertion(variable: "len", expected: 7, actual: 5, passed: false),
            failureMessage: "Expected len to be 7, but was 5")

        #expect(CompiledTestHarness.trailingFailureMessage(since: mark)
                == "Expected len to be 7, but was 5")
        #expect(CompiledTestHarness.assertions(since: mark).count == 1)

        CompiledTestHarness.reset()
    }

    /// A passing run leaves no trailing failure, so the harness reports
    /// a non-assertion error as `ERROR` rather than `FAIL`.
    @Test("A passing assertion leaves no trailing failure message")
    func testNoTrailingFailureWhenPassing() {
        CompiledTestHarness.reset()
        CompiledTestHarness.begin()

        let mark = CompiledTestHarness.assertionCount
        CompiledTestHarness.recordAssertion(
            TestAssertion(variable: "len", expected: 5, actual: 5, passed: true))

        #expect(CompiledTestHarness.trailingFailureMessage(since: mark) == nil)

        CompiledTestHarness.reset()
    }

    // MARK: - Filtering

    /// A harness binary is built once and run many times, so `--filter` travels
    /// in the environment rather than being baked in.
    ///
    /// Set and unset are one test because the environment is process-wide and
    /// the suite runs its tests in parallel — two cases would race over it.
    @Test("ARO_TEST_FILTER selects tests by name, case-insensitively")
    func testEnvironmentFilter() {
        setenv("ARO_TEST_FILTER", "upper", 1)

        #expect(CompiledTestHarness.shouldRun("uppercase-simple"))
        #expect(CompiledTestHarness.shouldRun("UPPERCASE-mixed"))
        #expect(!CompiledTestHarness.shouldRun("length-of-hello"))

        unsetenv("ARO_TEST_FILTER")
        #expect(CompiledTestHarness.shouldRun("length-of-hello"))
    }

    // MARK: - The curated hint

    /// Without this, a compiled test failure named the statement and not the
    /// mismatch — and the mismatch is the entire content of the failure.
    @Test("An AssertionError contributes its message as a curated hint")
    func testAssertionErrorIsCurated() {
        let assertion = AssertionError(
            message: "Expected len to be 7, but was 5",
            expected: 7, actual: 5, variable: "len")

        #expect(AROError.curatedHint(for: assertion)
                == "Expected len to be 7, but was 5.")
    }

    // MARK: - CLI surface

    @Test("`aro test --compiled` parses")
    func testCompiledFlagParses() throws {
        let command = try TestCommand.parse(["./Examples/AssertDemo", "--compiled"])
        #expect(command.compiled)
        #expect(command.path == "./Examples/AssertDemo")
    }

    @Test("`aro test` defaults to the interpreter")
    func testInterpreterIsDefault() throws {
        let command = try TestCommand.parse(["./Examples/AssertDemo"])
        #expect(!command.compiled)
    }

    @Test("`aro build --tests` parses")
    func testBuildTestsFlagParses() throws {
        let command = try BuildCommand.parse(["./Examples/AssertDemo", "--tests"])
        #expect(command.tests)
    }

    @Test("`aro build` does not build a harness by default")
    func testBuildStripsByDefault() throws {
        let command = try BuildCommand.parse(["./Examples/AssertDemo"])
        #expect(!command.tests)
    }
}
