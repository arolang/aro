# ARO-0015: Testing Framework

* Proposal: ARO-0015
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0010

## Abstract

This proposal introduces a built-in testing framework that keeps tests and production code together in the same `.aro` files. Tests are identified by business activity suffix and are automatically stripped from compiled binaries.

## Motivation

Testing is essential for:

1. **Verification**: Ensure features work correctly
2. **Documentation**: Tests as executable specifications
3. **Regression**: Prevent bugs from returning
4. **Colocation**: Keep tests close to the code they test

## Design Principles

1. **No setup/teardown** - Everything inside a test IS the test
2. **Colocated tests** - Test code lives in the same `.aro` file as production code
3. **Test stripping** - Compiler removes tests from native binaries
4. **Interpreter-only tests** - Tests run via `aro test`, not in compiled binaries

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
aro test ./Examples/Calculator           # Run all tests
aro test ./Examples/Calculator --verbose # Verbose output
aro test ./Examples/Calculator --filter "add" # Filter by name
aro test ./Examples/Calculator --no-color    # Disable ANSI colors
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

Both `aro build` (native compilation) and `LLVMCodeGenerator` filter out test feature sets:

```swift
let productionFeatureSets = allFeatureSets.filter { fs in
    !fs.featureSet.businessActivity.hasSuffix("Test") &&
    !fs.featureSet.businessActivity.hasSuffix("Tests")
}
```

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
