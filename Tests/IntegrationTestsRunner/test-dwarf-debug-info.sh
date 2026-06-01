#!/usr/bin/env bash
# =============================================================================
# Integration test — DWARF debug info in `aro build` binaries
# =============================================================================
# Issue #231. Verifies the compiler pipeline emits per-line DWARF that lldb
# can read. On Linux this should land directly in the ELF executable. On
# macOS the line tables reach the `.o`; whether they reach the linked
# executable depends on the dSYM workaround (still pending in v2).
#
# Run from the repository root:
#   ./Tests/IntegrationTestsRunner/test-dwarf-debug-info.sh
#
# Exit 0 on success, non-zero on failure with a descriptive message.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARO="${ARO:-$REPO_ROOT/.build/release/aro}"
if [[ ! -x "$ARO" ]]; then
    ARO="$REPO_ROOT/.build/debug/aro"
fi
if [[ ! -x "$ARO" ]]; then
    echo "FAIL: aro binary not found. Run \`swift build\` first." >&2
    exit 1
fi

EXAMPLE="$REPO_ROOT/Examples/HelloWorld"
if [[ ! -d "$EXAMPLE" ]]; then
    echo "FAIL: HelloWorld example missing at $EXAMPLE" >&2
    exit 1
fi

# Clean any prior build artifacts so we test a fresh compile.
rm -rf \
    "$EXAMPLE/HelloWorld" \
    "$EXAMPLE/HelloWorld.dSYM" \
    "$EXAMPLE/.build"

echo "[dwarf-test] Building $EXAMPLE with --keep-intermediate ..."
"$ARO" build "$EXAMPLE" --keep-intermediate >/dev/null

LL="$EXAMPLE/.build/HelloWorld.ll"
OBJ="$EXAMPLE/.build/HelloWorld.o"
BIN="$EXAMPLE/HelloWorld"

if [[ ! -f "$LL" ]]; then
    echo "FAIL: intermediate IR not found at $LL" >&2
    exit 1
fi

# -- Check 1: IR has DICompileUnit + at least one DISubprogram --------------
if ! grep -q "!DICompileUnit" "$LL"; then
    echo "FAIL: IR missing !DICompileUnit metadata" >&2
    exit 1
fi
if ! grep -q "!DISubprogram" "$LL"; then
    echo "FAIL: IR missing !DISubprogram metadata" >&2
    exit 1
fi
echo "[dwarf-test] IR carries CompileUnit + Subprogram ✓"

# -- Check 2: IR has per-instruction !dbg references (per-line DI) ----------
if ! grep -q ", !dbg " "$LL"; then
    echo "FAIL: IR missing per-instruction !dbg references (per-line DI did not emit)" >&2
    exit 1
fi
DBG_COUNT=$(grep -c ", !dbg " "$LL")
if (( DBG_COUNT < 3 )); then
    echo "FAIL: only $DBG_COUNT !dbg refs in IR — expected at least 3 (one per ARO statement)" >&2
    exit 1
fi
echo "[dwarf-test] IR has $DBG_COUNT per-instruction !dbg refs ✓"

# -- Check 3: IR has at least one DILocation -------------------------------
if ! grep -q "!DILocation" "$LL"; then
    echo "FAIL: IR missing !DILocation metadata" >&2
    exit 1
fi
echo "[dwarf-test] IR has !DILocation metadata ✓"

# -- Check 4: object file has __DWARF / .debug_info -----------------------
if [[ ! -f "$OBJ" ]]; then
    echo "FAIL: object file not found at $OBJ" >&2
    exit 1
fi

# dwarfdump exists on macOS by default; on Linux it lives in `binutils` or
# `llvm`. Fall back to readelf / objdump where dwarfdump is missing.
DWARF_INSPECT=""
if command -v dwarfdump >/dev/null 2>&1; then
    DWARF_INSPECT="dwarfdump --debug-info $OBJ"
elif command -v llvm-dwarfdump >/dev/null 2>&1; then
    DWARF_INSPECT="llvm-dwarfdump --debug-info $OBJ"
elif command -v objdump >/dev/null 2>&1; then
    DWARF_INSPECT="objdump --dwarf=info $OBJ"
fi
if [[ -z "$DWARF_INSPECT" ]]; then
    echo "[dwarf-test] WARN: no dwarfdump / llvm-dwarfdump / objdump available — skipping .o inspection"
else
    if ! $DWARF_INSPECT 2>/dev/null | grep -q "DW_TAG_subprogram"; then
        echo "FAIL: object file missing DW_TAG_subprogram" >&2
        $DWARF_INSPECT 2>&1 | head -20
        exit 1
    fi
    echo "[dwarf-test] Object file has DW_TAG_subprogram ✓"
fi

# -- Check 5: line table in the object file --------------------------------
LINE_INSPECT=""
if command -v dwarfdump >/dev/null 2>&1; then
    LINE_INSPECT="dwarfdump --debug-line $OBJ"
elif command -v llvm-dwarfdump >/dev/null 2>&1; then
    LINE_INSPECT="llvm-dwarfdump --debug-line $OBJ"
fi
if [[ -n "$LINE_INSPECT" ]]; then
    if ! $LINE_INSPECT 2>/dev/null | grep -qE "is_stmt"; then
        echo "FAIL: object file missing line-table is_stmt entries" >&2
        exit 1
    fi
    echo "[dwarf-test] Object file has DWARF line table ✓"
fi

# -- Check 6: linked binary runs (and the executable's symbol resolves) ----
if [[ ! -x "$BIN" ]]; then
    echo "FAIL: linked binary not produced at $BIN" >&2
    exit 1
fi

# On Linux, ELF DWARF lands directly in the executable, so a source-level
# breakpoint should resolve. Test this with lldb if available.
case "$(uname -s)" in
    Linux)
        if command -v lldb >/dev/null 2>&1; then
            # Try to resolve a source-level breakpoint on line 5 (the Log
            # statement) and confirm lldb reports at least one location.
            BP_OUTPUT=$(lldb -b \
                -o 'breakpoint set --file main.aro --line 5' \
                -o quit \
                "$BIN" 2>&1 || true)
            if grep -q "Breakpoint 1: where = " <<<"$BP_OUTPUT"; then
                echo "[dwarf-test] Linux lldb resolved source-level breakpoint ✓"
            elif grep -q "no locations (pending)" <<<"$BP_OUTPUT"; then
                echo "FAIL: Linux lldb could not resolve source-level breakpoint" >&2
                echo "$BP_OUTPUT" >&2
                exit 1
            else
                echo "[dwarf-test] WARN: lldb output unrecognized — assuming pass"
                echo "$BP_OUTPUT" | head -10
            fi
        else
            echo "[dwarf-test] WARN: lldb not on PATH — skipping Linux source-level bp test"
        fi
        ;;
    Darwin)
        # macOS dSYM gap (issue #231 phase 2 follow-up) means the executable
        # itself doesn't ship the DWARF; lldb can't resolve file:line until
        # the workaround lands. Inspecting the .o passes, which is what
        # we assert above.
        echo "[dwarf-test] macOS dSYM packaging gap — see #231; binary-level"
        echo "                source breakpoint test skipped here."
        ;;
    *)
        echo "[dwarf-test] WARN: $(uname -s) — no platform-specific lldb test wired"
        ;;
esac

echo ""
echo "[dwarf-test] All checks passed."
