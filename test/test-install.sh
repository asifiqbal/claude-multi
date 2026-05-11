#!/usr/bin/env bash
#
# test/test-install.sh
# Tests for install.sh — runs in an isolated $HOME so it doesn't touch
# the real machine.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL+1)); }

TESTHOME="$(mktemp -d)"
echo "TESTHOME=$TESTHOME"

# Seed a realistic ~/.claude
mkdir -p "$TESTHOME/.claude/projects/proj-abc/sess-1"
mkdir -p "$TESTHOME/.claude/skills/my-skill"
mkdir -p "$TESTHOME/.claude/agents"
mkdir -p "$TESTHOME/.claude/commands"
mkdir -p "$TESTHOME/.claude/statsig"
mkdir -p "$TESTHOME/.claude/hooks"

echo "global instructions"             > "$TESTHOME/.claude/CLAUDE.md"
echo '{"theme":"dark"}'                > "$TESTHOME/.claude/settings.json"
echo "session"                         > "$TESTHOME/.claude/projects/proj-abc/sess-1/summary.md"
echo "skill body"                      > "$TESTHOME/.claude/skills/my-skill/SKILL.md"
echo "fake-token"                      > "$TESTHOME/.claude/.credentials.json"
echo "statsig junk"                    > "$TESTHOME/.claude/statsig/cache"
echo "original hook"                   > "$TESTHOME/.claude/hooks/existing.sh"
echo "custom"                          > "$TESTHOME/.claude/my-custom-notes.md"

# ============================================================================
echo "=== TEST 1: ~/.claude is byte-identical before and after install ==="
find "$TESTHOME/.claude" -type f -exec sha256sum {} \; | sort > "$TESTHOME/before.txt"

HOME="$TESTHOME" ZSHRC="$TESTHOME/.zshrc" bash "$INSTALL" 3 > "$TESTHOME/run1.log" 2>&1
RC=$?
[[ "$RC" == "0" ]] && pass "install returned 0" || { fail "install returned $RC"; cat "$TESTHOME/run1.log"; }

find "$TESTHOME/.claude" -type f -exec sha256sum {} \; | sort > "$TESTHOME/after.txt"
if diff -q "$TESTHOME/before.txt" "$TESTHOME/after.txt" > /dev/null; then
  pass "no file under ~/.claude was modified"
else
  fail "~/.claude was modified"
  diff "$TESTHOME/before.txt" "$TESTHOME/after.txt"
fi
echo

# ============================================================================
echo "=== TEST 2: overlay symlink shape ==="
for acct in "$TESTHOME/.claude-acct1" "$TESTHOME/.claude-acct2" "$TESTHOME/.claude-acct3"; do
  for shared in CLAUDE.md settings.json projects skills agents commands my-custom-notes.md; do
    if [[ -L "$acct/$shared" ]]; then
      tgt="$(readlink "$acct/$shared")"
      [[ "$tgt" == "$TESTHOME/.claude/$shared" ]] && pass "$(basename "$acct"): $shared -> correct" \
        || fail "$(basename "$acct"): $shared -> $tgt (wrong)"
    else
      fail "$(basename "$acct"): $shared is missing or not a symlink"
    fi
  done

  for private in .credentials.json statsig; do
    if [[ -L "$acct/$private" ]]; then
      fail "$(basename "$acct"): LEAK — $private was symlinked"
    else
      pass "$(basename "$acct"): $private not symlinked (good)"
    fi
  done

  if [[ -d "$acct/hooks" && ! -L "$acct/hooks" ]]; then
    pass "$(basename "$acct"): hooks/ is real per-account dir"
  else
    fail "$(basename "$acct"): hooks/ wrong type"
  fi
done
echo

# ============================================================================
echo "=== TEST 3: wrapper installed and executable ==="
WRAPPER="$TESTHOME/.claude-shared-bin/cc-launch.sh"
[[ -f "$WRAPPER" ]] && pass "wrapper installed at $WRAPPER" || fail "wrapper missing"
[[ -x "$WRAPPER" ]] && pass "wrapper is executable" || fail "wrapper not executable"
echo

# ============================================================================
echo "=== TEST 4: zshrc contains correct alias block ==="
if grep -q "claude-multi-account >>>" "$TESTHOME/.zshrc"; then
  pass "marker block present"
else
  fail "marker block missing"
fi

# Each cc1/cc2/cc3 should reference the wrapper
for i in 1 2 3; do
  if grep -q "alias cc$i='$TESTHOME/.claude-shared-bin/cc-launch.sh acct$i $TESTHOME/.claude-acct$i'" "$TESTHOME/.zshrc"; then
    pass "alias cc$i correct"
  else
    fail "alias cc$i wrong or missing"
    grep "alias cc$i" "$TESTHOME/.zshrc" || true
  fi
done
echo

# ============================================================================
echo "=== TEST 5: idempotency (re-running install) ==="
HOME="$TESTHOME" ZSHRC="$TESTHOME/.zshrc" bash "$INSTALL" 3 > "$TESTHOME/run2.log" 2>&1
RC=$?
[[ "$RC" == "0" ]] && pass "second install returned 0" || fail "second install returned $RC"

COUNT=$(grep -c "claude-multi-account >>>" "$TESTHOME/.zshrc")
[[ "$COUNT" == "1" ]] && pass "alias block appears exactly once" \
  || fail "alias block appears $COUNT times"
echo

# ============================================================================
echo "=== TEST 6: write-through (sharing actually works) ==="
echo "new session data" > "$TESTHOME/.claude-acct1/projects/proj-abc/sess-1/new.md"
for acct in .claude-acct2 .claude-acct3; do
  if [[ -f "$TESTHOME/$acct/projects/proj-abc/sess-1/new.md" ]]; then
    pass "$acct sees write from acct1"
  else
    fail "$acct does not see write from acct1"
  fi
done
[[ -f "$TESTHOME/.claude/projects/proj-abc/sess-1/new.md" ]] \
  && pass "~/.claude has the new file" \
  || fail "~/.claude missing the new file"
echo

# ============================================================================
echo "=== TEST 7: variable account count ==="
rm -rf "$TESTHOME/.claude-acct"* "$TESTHOME/.claude-shared-bin"
rm -f "$TESTHOME/.zshrc"

HOME="$TESTHOME" ZSHRC="$TESTHOME/.zshrc" bash "$INSTALL" 5 > "$TESTHOME/run5.log" 2>&1
RC=$?
[[ "$RC" == "0" ]] && pass "install with N=5 returned 0" || fail "install with N=5 returned $RC"

for i in 1 2 3 4 5; do
  if [[ -d "$TESTHOME/.claude-acct$i" ]]; then
    pass ".claude-acct$i created"
  else
    fail ".claude-acct$i missing"
  fi
done
echo

# ============================================================================
echo "=== TEST 8: invalid input rejected ==="
rm -f "$TESTHOME/.zshrc"
HOME="$TESTHOME" ZSHRC="$TESTHOME/.zshrc" bash "$INSTALL" 99 > "$TESTHOME/run99.log" 2>&1
RC=$?
[[ "$RC" != "0" ]] && pass "N=99 rejected" || fail "N=99 incorrectly accepted"

HOME="$TESTHOME" ZSHRC="$TESTHOME/.zshrc" bash "$INSTALL" foo > "$TESTHOME/runfoo.log" 2>&1
RC=$?
[[ "$RC" != "0" ]] && pass "non-integer rejected" || fail "non-integer incorrectly accepted"
echo

# ============================================================================
echo "=== TEST 9: rm -rf overlay does not damage ~/.claude ==="
find "$TESTHOME/.claude" -type f -exec sha256sum {} \; | sort > "$TESTHOME/before-rm.txt"
rm -rf "$TESTHOME/.claude-acct1"
find "$TESTHOME/.claude" -type f -exec sha256sum {} \; | sort > "$TESTHOME/after-rm.txt"
if diff -q "$TESTHOME/before-rm.txt" "$TESTHOME/after-rm.txt" > /dev/null; then
  pass "rm -rf overlay left ~/.claude intact"
else
  fail "rm -rf overlay damaged ~/.claude"
fi
echo

# ============================================================================
echo "=== TEST 10: uninstall ==="
# Reinstall first so we have something to uninstall
HOME="$TESTHOME" ZSHRC="$TESTHOME/.zshrc" bash "$INSTALL" 3 > "$TESTHOME/reinstall.log" 2>&1

HOME="$TESTHOME" ZSHRC="$TESTHOME/.zshrc" bash "$INSTALL" --uninstall > "$TESTHOME/uninstall.log" 2>&1
RC=$?
[[ "$RC" == "0" ]] && pass "uninstall returned 0" || fail "uninstall returned $RC"

for i in 1 2 3; do
  [[ ! -d "$TESTHOME/.claude-acct$i" ]] && pass ".claude-acct$i removed" \
    || fail ".claude-acct$i still exists"
done

[[ ! -d "$TESTHOME/.claude-shared-bin" ]] && pass ".claude-shared-bin removed" \
  || fail ".claude-shared-bin still exists"

if grep -q "claude-multi-account" "$TESTHOME/.zshrc" 2>/dev/null; then
  fail "alias block still in zshrc"
else
  pass "alias block removed from zshrc"
fi

[[ -d "$TESTHOME/.claude" ]] && pass "~/.claude preserved" || fail "~/.claude was removed!"
echo

# ============================================================================
echo "============================"
echo "  TOTAL: $PASS pass, $FAIL fail"
echo "============================"
[[ "$FAIL" == "0" ]] || exit 1
