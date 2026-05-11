#!/usr/bin/env bash
#
# test/test-lock.sh
# Tests for bin/cc-launch.sh — uses a fake `claude` binary on PATH so we can
# run the full lifecycle without an actual Claude Code install.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRAPPER="$REPO_ROOT/bin/cc-launch.sh"

if [[ ! -x "$WRAPPER" ]]; then
  chmod +x "$WRAPPER" 2>/dev/null || true
fi

PASS=0
FAIL=0
pass() { echo "  ✅ PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL+1)); }

TESTHOME="$(mktemp -d)"
LOCKFILE="$TESTHOME/.claude-multi.lock"

FAKEBIN="$TESTHOME/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
duration=0
exitcode=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) duration="$2"; shift 2 ;;
    --exit) exitcode="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$duration" -gt 0 ]] && sleep "$duration"
exit "$exitcode"
EOF
chmod +x "$FAKEBIN/claude"

export PATH="$FAKEBIN:$PATH"
export HOME="$TESTHOME"

echo "=== TEST 1: clean run, no prior lock ==="
rm -f "$LOCKFILE"
"$WRAPPER" acct1 "$TESTHOME/.claude-acct1" > "$TESTHOME/t1.log" 2>&1
RC=$?
[[ "$RC" == "0" ]] && pass "wrapper returned 0" || fail "wrapper returned $RC"
[[ ! -f "$LOCKFILE" ]] && pass "lockfile cleaned up after exit" || fail "lockfile lingered"
echo

echo "=== TEST 2: lock blocks a different account ==="
rm -f "$LOCKFILE"
"$WRAPPER" acct1 "$TESTHOME/.claude-acct1" --duration 5 > "$TESTHOME/t2a.log" 2>&1 &
BG_PID=$!
sleep 1

"$WRAPPER" acct2 "$TESTHOME/.claude-acct2" > "$TESTHOME/t2b.log" 2>&1
RC=$?
[[ "$RC" == "1" ]] && pass "second account refused (exit 1)" || fail "second account got exit $RC"
grep -q "already running" "$TESTHOME/t2b.log" && pass "got 'already running' message" \
  || fail "missing 'already running' message"

wait "$BG_PID"
[[ ! -f "$LOCKFILE" ]] && pass "lockfile cleaned up after acct1 finished" || fail "lockfile lingered"
echo

echo "=== TEST 3: nested same-account allowed, outer lock preserved ==="
rm -f "$LOCKFILE"
"$WRAPPER" acct1 "$TESTHOME/.claude-acct1" --duration 4 > "$TESTHOME/t3a.log" 2>&1 &
BG_PID=$!
sleep 1

OUTER_LOCK="$(cat "$LOCKFILE")"

"$WRAPPER" acct1 "$TESTHOME/.claude-acct1" --duration 1 > "$TESTHOME/t3b.log" 2>&1
RC=$?
[[ "$RC" == "0" ]] && pass "nested same-account allowed" || fail "nested got exit $RC"
grep -q "already running" "$TESTHOME/t3b.log" && pass "got nested note" || fail "missing nested note"

if [[ -f "$LOCKFILE" ]]; then
  AFTER="$(cat "$LOCKFILE")"
  [[ "$AFTER" == "$OUTER_LOCK" ]] && pass "outer lock preserved" \
    || fail "outer lock changed (was '$OUTER_LOCK', now '$AFTER')"
else
  fail "outer lock removed by nested exit"
fi

wait "$BG_PID"
[[ ! -f "$LOCKFILE" ]] && pass "outer lock cleaned up" || fail "lockfile lingered"
echo

echo "=== TEST 4: stale lock is cleared ==="
echo "ghost 99999" > "$LOCKFILE"
"$WRAPPER" acct1 "$TESTHOME/.claude-acct1" > "$TESTHOME/t4.log" 2>&1
RC=$?
[[ "$RC" == "0" ]] && pass "wrapper proceeded past stale lock" || fail "got exit $RC"
grep -q "clearing stale lock" "$TESTHOME/t4.log" && pass "logged stale-lock cleanup" \
  || fail "missing stale-lock message"
[[ ! -f "$LOCKFILE" ]] && pass "lockfile cleaned after run" || fail "lockfile lingered"
echo

echo "=== TEST 5: SIGINT releases the lock ==="
rm -f "$LOCKFILE"
"$WRAPPER" acct1 "$TESTHOME/.claude-acct1" --duration 10 > "$TESTHOME/t5.log" 2>&1 &
BG_PID=$!
sleep 1
[[ -f "$LOCKFILE" ]] && pass "lock acquired during run" || fail "lock not acquired"
kill -INT "$BG_PID" 2>/dev/null
wait "$BG_PID" 2>/dev/null
sleep 0.5
[[ ! -f "$LOCKFILE" ]] && pass "lock released after SIGINT" || fail "lock lingered"
echo

echo "=== TEST 6: SIGTERM releases the lock ==="
rm -f "$LOCKFILE"
"$WRAPPER" acct1 "$TESTHOME/.claude-acct1" --duration 10 > "$TESTHOME/t6.log" 2>&1 &
BG_PID=$!
sleep 1
kill -TERM "$BG_PID" 2>/dev/null
wait "$BG_PID" 2>/dev/null
sleep 0.5
[[ ! -f "$LOCKFILE" ]] && pass "lock released after SIGTERM" || fail "lock lingered"
echo

echo "=== TEST 7: exit code propagates ==="
rm -f "$LOCKFILE"
"$WRAPPER" acct1 "$TESTHOME/.claude-acct1" --exit 42 > "$TESTHOME/t7.log" 2>&1
RC=$?
[[ "$RC" == "42" ]] && pass "exit code 42 propagated" || fail "expected 42, got $RC"
[[ ! -f "$LOCKFILE" ]] && pass "lock released after non-zero exit" || fail "lock lingered"
echo

echo "=== TEST 8: CLAUDE_CONFIG_DIR is set ==="
rm -f "$LOCKFILE"
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-UNSET}" > /tmp/cc-env-check.txt
EOF
chmod +x "$FAKEBIN/claude"

"$WRAPPER" acct1 "/Users/test/.claude-acct1" > "$TESTHOME/t8.log" 2>&1
if grep -q "CLAUDE_CONFIG_DIR=/Users/test/.claude-acct1" /tmp/cc-env-check.txt 2>/dev/null; then
  pass "CLAUDE_CONFIG_DIR correctly passed"
else
  fail "wrong or missing CLAUDE_CONFIG_DIR"
fi
rm -f /tmp/cc-env-check.txt
echo

echo "============================"
echo "  TOTAL: $PASS pass, $FAIL fail"
echo "============================"
[[ "$FAIL" == "0" ]] || exit 1
