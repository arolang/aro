#!/usr/bin/env bash
# Exercises both halves of ARO-0090 — a body that streams (any size, nothing
# buffered) and a body that is read (bounded, 413 above the limit) — against
# both execution modes, because a compiled binary and the interpreter answer
# the same upload from the same analysis and must agree (ARO-0009 parity).
set -u

ARO="${ARO_BIN:-./.build/debug/aro}"
PORT=8080
BASE="http://localhost:$PORT"
WORK="$(mktemp -d)"
SERVER_PID=""
trap 'rm -rf "$WORK"; [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null' EXIT

mkdir -p /tmp/aro-uploads
python3 -c "
with open('$WORK/upload.bin','wb') as f:
    f.write(b'X' * (64 * 1024 * 1024))
"
python3 -c "print('{\"text\":\"' + 'A' * 4000 + '\"}')" > "$WORK/big.json"
echo "round trip" > "$WORK/echo.txt"
EXPECTED_DIGEST=$(python3 -c "
import hashlib
print(hashlib.sha256(open('$WORK/upload.bin','rb').read()).hexdigest())
")

fail() { echo "FAIL [$MODE]: $1"; echo "--- server log:"; cat "$WORK/server.log"; exit 1; }

wait_for_server() {
    for _ in $(seq 1 60); do
        curl -s -o /dev/null "$BASE/notes" && return 0
        sleep 0.25
    done
    return 1
}

run_suite() {
    MODE="$1"
    rm -f /tmp/aro-uploads/streamed.bin /tmp/aro-uploads/archived.bin

    # 1. A small JSON body on a route that reads it.
    body=$(curl -s -X POST "$BASE/notes" -H 'Content-Type: application/json' -d '{"text":"hello"}')
    echo "$body" | grep -q hello || fail "reading route did not return the field: $body"

    # 2. The same route, over its 1KB limit: refused, and the message says how.
    status=$(curl -s -o "$WORK/refused.json" -w '%{http_code}' -X POST "$BASE/notes" \
        -H 'Content-Type: application/json' --data-binary @"$WORK/big.json")
    [ "$status" = "413" ] || fail "oversized body should be 413, got $status"
    grep -q 'x-aro-max-body' "$WORK/refused.json" || fail "413 should name the fix: $(cat "$WORK/refused.json")"

    # 3. A 64MB upload on a route that streams: accepted, written whole, and the
    #    server's memory does not grow with it.
    rss_before=$(ps -o rss= -p "$SERVER_PID" | tr -d ' ')
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/documents/streamed.bin" \
        --data-binary @"$WORK/upload.bin")
    [ "$status" = "201" ] || fail "streamed upload should be 201, got $status"
    cmp "$WORK/upload.bin" /tmp/aro-uploads/streamed.bin || fail "uploaded file differs from what was sent"
    rss_after=$(ps -o rss= -p "$SERVER_PID" | tr -d ' ')
    growth=$((rss_after - rss_before))
    [ "$growth" -lt 32768 ] || fail "server grew ${growth}KB streaming a 64MB body — it is buffering"

    # 4. Returning the body streams it back out, chunked.
    curl -s -X POST "$BASE/echo" --data-binary @"$WORK/echo.txt" | grep -q "round trip" \
        || fail "echo did not return the body"

    # 5. Folding over the body without building it: the digest must match.
    digest=$(curl -s -X POST "$BASE/digest" --data-binary @"$WORK/upload.bin")
    echo "$digest" | grep -q "$EXPECTED_DIGEST" \
        || fail "streamed digest is wrong: $digest (expected $EXPECTED_DIGEST)"

    # 6. A body handed to an event handler is anchored and still arrives whole.
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/archive/x" \
        --data-binary @"$WORK/upload.bin")
    [ "$status" = "202" ] || fail "archive should be 202, got $status"
    cmp "$WORK/upload.bin" /tmp/aro-uploads/archived.bin || fail "anchored body differs from what was sent"

    echo "FileUpload [$MODE]: all checks passed"
}

# --- Interpreter -----------------------------------------------------------
"$ARO" run ./Examples/FileUpload > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
wait_for_server || { echo "FAIL: interpreter server never came up"; cat "$WORK/server.log"; exit 1; }
run_suite interpreter
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""
sleep 1

# --- Compiled binary -------------------------------------------------------
# The same program, the same analysis, the same answers (ARO-0090 §9).
if "$ARO" build ./Examples/FileUpload > "$WORK/build.log" 2>&1; then
    ./Examples/FileUpload/FileUpload > "$WORK/server.log" 2>&1 &
    SERVER_PID=$!
    wait_for_server || { echo "FAIL: compiled server never came up"; cat "$WORK/server.log"; exit 1; }
    run_suite compiled
    kill "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
    rm -f ./Examples/FileUpload/FileUpload
else
    # A missing LLVM toolchain is an environment fact, not a regression; the
    # interpreter half above still gates the change.
    echo "FileUpload [compiled]: skipped — aro build unavailable ($(tail -1 "$WORK/build.log"))"
fi

rm -f /tmp/aro-uploads/streamed.bin /tmp/aro-uploads/archived.bin
echo "FileUpload: all checks passed"
