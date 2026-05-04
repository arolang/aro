#!/usr/bin/env bash
# ARO stdin-pipe smoke tests (issue #200)
#
# Verifies that piping ARO source into `aro` with no arguments evaluates the
# source through the REPL and produces clean output.
#
# Usage:
#   ./test_stdin.sh                       # uses .build/release/aro
#   ARO_BIN=.build/debug/aro ./test_stdin.sh

set -u

ARO_BIN="${ARO_BIN:-.build/release/aro}"

if [[ ! -x "$ARO_BIN" ]]; then
    echo "ARO binary not found or not executable: $ARO_BIN" >&2
    echo "Set ARO_BIN to the path of the aro binary, or build first." >&2
    exit 2
fi

pass=0
fail=0

# Run a stdin-pipe test.
# Args: <description> <input> <expected stdout substring>
run_test() {
    local desc="$1"
    local input="$2"
    local expected="$3"

    local actual
    actual=$(printf '%s' "$input" | "$ARO_BIN" 2>&1)
    local rc=$?

    if [[ $rc -eq 0 && "$actual" == *"$expected"* ]]; then
        printf '[PASS] %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf '[FAIL] %s\n' "$desc"
        printf '       input:    %q\n' "$input"
        printf '       expected: %q\n' "$expected"
        printf '       got (rc=%d): %q\n' "$rc" "$actual"
        fail=$((fail + 1))
    fi
}

# Run a stdin-pipe test that should fail (non-zero exit).
run_failing_test() {
    local desc="$1"
    local input="$2"

    local actual
    actual=$(printf '%s' "$input" | "$ARO_BIN" 2>&1)
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        printf '[PASS] %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf '[FAIL] %s (expected non-zero exit, got %d)\n' "$desc" "$rc"
        printf '       output: %q\n' "$actual"
        fail=$((fail + 1))
    fi
}

run_test "single Log statement prints message without prefix" \
    'Log "Hello World" to the <console>.' \
    "Hello World"

run_test "single Log statement does NOT contain feature-set prefix" \
    'Log "no prefix here" to the <console>.' \
    "no prefix here"

run_test "multi-line input shares evaluation context" \
    'Compute the <x> from 21.
Compute the <doubled> from <x> * 2.
Log <doubled> to the <console>.' \
    "42"

run_test "multi-line Log statements run in order" \
    'Log "Line 1" to the <console>.
Log "Line 2" to the <console>.' \
    "Line 1"

run_test "computed string length works" \
    'Create the <greeting> with "Hello, World!".
Compute the <len: length> from the <greeting>.
Log <len> to the <console>.' \
    "13"

run_failing_test "garbage input exits with non-zero code" \
    "totally bogus syntax that is not ARO"

run_failing_test "unknown action exits with non-zero code" \
    "FooBar the <thing> with the <other>."

# stdin pipe should not leak the [_repl_session_] internal name
internal_marker=$(printf 'Log "x" to the <console>.' | "$ARO_BIN" 2>&1)
if [[ "$internal_marker" == *"_repl_session_"* ]]; then
    printf '[FAIL] stdin pipe must not leak _repl_session_ marker\n'
    printf '       output: %q\n' "$internal_marker"
    fail=$((fail + 1))
else
    printf '[PASS] stdin pipe does not leak _repl_session_ marker\n'
    pass=$((pass + 1))
fi

printf '\n=== %d passed, %d failed ===\n' "$pass" "$fail"

if [[ $fail -gt 0 ]]; then
    exit 1
fi
exit 0
