# ARO-0015: Testing Framework

* Proposal: ARO-0015
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0010

## Abstract

This proposal introduces a built-in testing framework that keeps tests and production code together in the same `.aro` files. Tests are identified by business activity suffix and are automatically stripped from compiled binaries. `aro test --compiled` is the exception: it builds a *test-harness* binary that keeps them, so the same tests can assert the behaviour of compiled code (§3.4).

## Motivation

Testing is essential for:

1. **Verification**: Ensure features work correctly
2. **Documentation**: Tests as executable specifications
3. **Regression**: Prevent bugs from returning
4. **Colocation**: Keep tests close to the code they test

## Design Principles

1. **No setup/teardown** - Everything inside a test IS the test
2. **Colocated tests** - Test code lives in the same `.aro` file as production code
3. **Test stripping** - A shipped binary contains no tests
4. **One suite, two modes** - The same test feature sets run interpreted
   (`aro test`, the default) and compiled (`aro test --compiled`)

The fourth principle replaces "interpreter-only tests". ARO-0009 promises that a
compiled binary answers a program the same way the interpreter does; a test
command that only ever ran the interpreter could not notice when it did not, so
a green test run said nothing about the binary a user ships (GitLab #694).

---

## 1. Test Identification

Tests are identified by the **`Test` suffix** in the business activity:

```aro
(* Production code - included in binary *)
(add-numbers: Calculator) {
    Create the <sum> with <a>.
    Return an <OK: status> with <sum>.
}

(* Test code - stripped from binary *)
(add-positive-numbers: Calculator Test) {
    Given the <a> with 5.
    Given the <b> with 3.
    When the <sum> from the <add-numbers>.
    Then the <sum> with 8.
}
```

The business activity suffix determines test membership:
- `Calculator Test` - test feature set
- `Calculator Tests` - test feature set (plural also works)
- `Calculator` - production feature set

---

## 2. Test Actions

Four actions support BDD-style testing:

### 2.1 Given Action

Sets up test data by binding a value to a variable.

```aro
Given the <variable> with <value>.
Given the <request> with { email: "test@example.com" }.
```

- Role: `OWN`
- Verb: `given`
- Preposition: `with`

### 2.2 When Action

Executes a feature set and captures the result.

```aro
When the <result> from the <feature-set-name>.
```

- Role: `OWN`
- Verb: `when`
- Preposition: `from`
- Looks up and executes the named feature set
- Binds result to the specified variable
- Passes all current context variables to the feature set

### 2.3 Then Action

Asserts that a value matches an expected result.

```aro
Then the <variable> with <expected-value>.
```

- Role: `OWN`
- Verb: `then`
- Preposition: `with`
- Throws `AssertionError` on mismatch

### 2.4 Assert Action

Direct equality assertion (alternative to Then).

```aro
Assert the <variable> with <expected-value>.
```

- Role: `OWN`
- Verb: `assert`
- Preposition: `with`, `for`

---

## 3. CLI Usage

### 3.1 Running Tests

```bash
aro test ./Examples/Calculator           # Run all tests (interpreter)
aro test ./Examples/Calculator --verbose # Verbose output
aro test ./Examples/Calculator --filter "add" # Filter by name
aro test ./Examples/Calculator --no-color    # Disable ANSI colors
aro test ./Examples/Calculator --compiled    # Run the same tests through a native binary (§3.4)
```

### 3.2 Output Format

```
=== ARO Test Results ===

  PASS  add-positive-numbers (<1ms)
  PASS  add-zero (<1ms)
  FAIL  subtract-negative
        Expected difference to be -2, but was 2
  ERROR divide-by-zero
        Division by zero

------------------------
Total:  4
Passed: 2
Failed: 1
Errors: 1
```

### 3.3 Building (Test Stripping)

When compiling to native binary, tests are automatically stripped:

```bash
aro build ./Examples/Calculator --verbose
# Output: Stripped 4 test feature set(s) from binary
```

### 3.4 Compiled Mode

`--compiled` builds a **test-harness binary** and runs the test feature sets
through it, then exits with that binary's status. The interpreter remains the
default: it is faster and needs no toolchain, which is what an edit/test loop
wants.

```bash
aro test ./MyApp              # interpreter (default)
aro test --compiled ./MyApp   # native binary
```

The report is produced by the same reporter in both modes, so the two runs are
comparable line for line and a divergence shows up as a difference in the
*results*:

```
$ aro test --no-color ./Examples/Calculator        $ aro test --compiled --no-color ./Examples/Calculator

=== ARO Test Results ===                           === ARO Test Results ===

  PASS  addition-test (3ms)                          PASS  addition-test (2ms)
  PASS  subtraction-test (<1ms)                      FAIL  subtraction-test
  PASS  multiplication-test (<1ms)                         Expected difference to be 15, but was
  ...                                                ...
```

That is the point of the mode, and the failure above is real: a `Compute` whose
result is *named* `difference` is read as the set-operation qualifier by the
compiled path. It is tracked separately under the dual-mode parity work.

**How it is built.** `aro build --tests` is the build half, and is usable on its
own:

```bash
aro build --tests ./MyApp -o myapp-test   # produces a harness binary
./myapp-test                              # runs the tests, exits 1 on failure
```

A harness binary differs from a shipped one in exactly two ways:

1. **Test feature sets are kept** instead of stripped (§5.3). Everything else —
   the production feature sets, the contract, the plugins, the event handlers,
   the user-defined actions — is compiled identically, because a test has to
   exercise the code the shipped binary runs.
2. **`main` drives the tests instead of calling `Application-Start`.** Each test
   gets its own context, runs, and is tallied; the process exit code is the
   suite's. `Application-Start` is never called: a test run must not bind ports
   or start file watchers.

**`When` in a compiled binary.** `When the <len> from the <get-length>.` resolves
its target through the AST when interpreted. A compiled binary has no AST, so the
harness registers every feature-set body by name at startup and `When` dispatches
through that table. Name normalisation (hyphens, spaces, case) is shared with the
interpreter's lookup, so a test does not resolve differently in the two modes.

**Run-time options.** A harness binary is built once and can be run many times,
so the options that are per-run travel in the environment rather than being baked
in. `aro test --compiled` sets them from its own flags:

| Variable | Set by | Effect |
|----------|--------|--------|
| `ARO_TEST_FILTER` | `--filter` | Run only tests whose name contains this, case-insensitively |
| `ARO_TEST_VERBOSE` | `--verbose` | Print the per-assertion breakdown for failures |
| `ARO_TEST_NO_COLOR` | `--no-color` | Disable ANSI colours (`NO_COLOR` works too) |

---

## 4. Complete Example

```aro
(* ============================================================
   Calculator Example with Tests

   Production and test code in the same file.
   Tests are stripped when building native binary.
   ============================================================ *)

(* --- Application Entry Point --- *)

(Application-Start: Calculator) {
    Log the <message> for the <console> with "Calculator ready".
    Return an <OK: status> for the <startup>.
}

(* --- Production Feature Sets --- *)

(add-numbers: Calculator) {
    Create the <sum> with <a>.
    Return an <OK: status> with <sum>.
}

(subtract-numbers: Calculator) {
    Create the <difference> with <a>.
    Return an <OK: status> with <difference>.
}

(multiply-numbers: Calculator) {
    Create the <product> with <a>.
    Return an <OK: status> with <product>.
}

(* --- Test Feature Sets --- *)

(add-positive-numbers: Calculator Test) {
    Given the <a> with 5.
    Given the <b> with 3.
    When the <sum> from the <add-numbers>.
    Then the <sum> with 8.
}

(add-zero: Calculator Test) {
    Given the <a> with 10.
    Given the <b> with 0.
    When the <sum> from the <add-numbers>.
    Then the <sum> with 10.
}

(subtract-basic: Calculator Test) {
    Given the <a> with 10.
    Given the <b> with 4.
    When the <difference> from the <subtract-numbers>.
    Then the <difference> with 6.
}

(multiply-basic: Calculator Test) {
    Given the <a> with 6.
    Given the <b> with 7.
    When the <product> from the <multiply-numbers>.
    Then the <product> with 42.
}
```

---

## 5. Implementation Details

### 5.1 Test Discovery

The `TestRunner` discovers tests by checking business activity suffix:

```swift
public static func isTestFeatureSet(_ featureSet: FeatureSet) -> Bool {
    let activity = featureSet.businessActivity
    return activity.hasSuffix("Test") || activity.hasSuffix("Tests")
}
```

### 5.2 Test Execution Context

Tests run in a `TestContext` that provides:
- Feature set lookup for `<When>` action
- Variable binding propagation to called feature sets
- Assertion recording for reporting

### 5.3 Compiler Stripping

`aro build` filters out test feature sets, unless `--tests` was given:

```swift
let productionFeatureSets = tests ? allFeatureSets : allFeatureSets.filter { fs in
    !TestFeatureSetNaming.isTest(activity: fs.featureSet.businessActivity)
}
```

The rule in §1 is asked through one function, `AROParser.TestFeatureSetNaming`,
because three separate things depend on it being the same rule: `TestRunner`
picks the tests to run, `aro build` strips them, and the code generator keeps and
drives them for a harness. Stripping and harnessing are exact complements — a
test the build stripped but the harness listed would be a call to a function
that was never emitted.

### 5.4 The Compiled Harness

Three C-ABI entry points, called from the generated `main`:

| Symbol | Purpose |
|--------|---------|
| `aro_register_feature_set_body(runtime, name, body)` | The name → body table a compiled `When` resolves through |
| `aro_test_run_case(ctx, name, activity, body)` | Run one test on its own context, classify the outcome, tally it |
| `aro_test_report()` | Print the suite report; returns the process exit code |

A compiled body cannot throw across the C ABI: a failure is left in the context's
error slot and the body returns null. The harness reads that slot after the call.
Telling a failed *expectation* (`FAIL`) from a broken *statement* (`ERROR`) needs
more than the slot, because the bridge has already turned the thrown
`AssertionError` into a message: `Then` and `Assert` therefore log every
comparison they make, and a run that ends on a failed one is a `FAIL`. The
message is carried from the action rather than recomposed, so both modes print
the same sentence.

### 5.5 Limitations of Compiled Mode

* **No `aro build`, no `--compiled`.** The mode needs the native pipeline, which
  is unavailable on Windows; `aro test` there is the interpreter only.
* **`--record` is interpreter-only.** The statement-level JSONL trace SOLARO
  tails comes from the interpreter's `DebugController`; a compiled binary has no
  per-statement checkpoints to record.
* **A harness is not a shipped binary.** It is the same compiled code plus the
  tests, and its `main` differs. The mode asserts that the *feature sets* behave
  the same; it does not assert anything about application startup, which only
  the real binary performs.
* **Test isolation is per-context, not per-process.** Each test gets a fresh
  context, as it does interpreted, but repositories and other process-wide state
  are shared across the run — the same caveat the interpreter has.

---

## 6. Grammar

Test actions use existing ARO statement syntax:

```ebnf
(* Test Actions - use standard ARO statement form *)
given_statement = "<Given>" , "the" , result , "with" , value , "." ;
when_statement  = "<When>" , "the" , result , "from" , "the" , feature_name , "." ;
then_statement  = "<Then>" , "the" , result , "with" , expected , "." ;
assert_statement = "<Assert>" , "the" , result , ("with" | "for") , expected , "." ;

(* Test Feature Set - identified by business activity suffix *)
test_feature_set = "(" , name , ":" , activity , "Test" , ")" , "{" , statements , "}" ;
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
| 2.0 | 2024-12 | Simplified design: removed setup/teardown, mocking, fixtures. Tests identified by business activity suffix. |
| 2.1 | 2026-10 | `aro test --compiled` and `aro build --tests`: the same tests run against compiled code (§3.4, §5.4, §5.5). "Interpreter-only tests" is no longer a design principle. |
