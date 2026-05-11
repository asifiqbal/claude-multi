#!/usr/bin/env bash
#
# cc-launch.sh
# ------------
# Wrapper that enforces "only one cc-account at a time" via a shared lockfile.
#
# Usage:
#   cc-launch.sh <account-label> <config-dir> [claude-args...]
#
# Behavior:
#   - Before launching claude, check ~/.claude-multi.lock
#   - If the lock is held by a live process:
#       * Same account label → allow (nested shell case)
#       * Different label    → refuse with a clear message
#   - Stale lock (PID dead)  → log and overwrite
#   - On exit (clean, Ctrl-C, SIGTERM, SIGHUP) → release the lock via trap
#
# We do NOT exec claude — we run it as a child so the trap fires on exit.

set -u

LOCKFILE="$HOME/.claude-multi.lock"

LABEL="${1:-}"
CONFIG_DIR="${2:-}"
shift 2 || true

if [[ -z "$LABEL" || -z "$CONFIG_DIR" ]]; then
  echo "usage: cc-launch.sh <label> <config-dir> [claude args...]" >&2
  exit 2
fi

# --- Check existing lock ----------------------------------------------------

NESTED=0
existing_label=""
existing_pid=""

if [[ -f "$LOCKFILE" ]]; then
  read -r existing_label existing_pid < "$LOCKFILE" || true

  if [[ -n "${existing_pid:-}" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    if [[ "$existing_label" == "$LABEL" ]]; then
      echo "note: $LABEL already running (pid $existing_pid); launching nested" >&2
      NESTED=1
    else
      echo "❌ Cannot launch $LABEL: $existing_label is already running (pid $existing_pid)" >&2
      echo "   Exit that session first, or inspect with:  ps -p $existing_pid" >&2
      exit 1
    fi
  else
    echo "note: clearing stale lock from ${existing_label:-?} (pid ${existing_pid:-?} not running)" >&2
    rm -f "$LOCKFILE"
  fi
fi

# --- Acquire / preserve lock ------------------------------------------------

if [[ "$NESTED" == "0" ]]; then
  echo "$LABEL $$" > "$LOCKFILE"
fi

cleanup() {
  if [[ "$NESTED" == "0" ]] && [[ -f "$LOCKFILE" ]]; then
    local current_label current_pid
    read -r current_label current_pid < "$LOCKFILE" 2>/dev/null || true
    if [[ "${current_pid:-}" == "$$" ]]; then
      rm -f "$LOCKFILE"
    fi
  fi
}
trap cleanup EXIT INT TERM HUP

# --- Launch claude as a child so cleanup() runs on exit ---------------------

CLAUDE_CONFIG_DIR="$CONFIG_DIR" claude "$@"
EXIT_CODE=$?
exit "$EXIT_CODE"
