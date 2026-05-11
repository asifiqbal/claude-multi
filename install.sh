#!/usr/bin/env bash
#
# install.sh
# ----------
# Sets up N Claude Code accounts that share ~/.claude as a single "brain"
# (memory, projects, skills, agents, commands, settings) while keeping
# credentials, hooks, and runtime state private per account.
#
# Each account dir is an "overlay" — every shared thing is a symlink back
# to ~/.claude. Private things (credentials, lock files, runtime state)
# live as real files inside each overlay.
#
# Also installs cc-launch.sh — a wrapper that enforces "only one account
# active at a time" via a shared lockfile, so two accounts can't race
# on the shared session-memory files.
#
# Usage:
#   ./install.sh             # installs 3 accounts (acct1, acct2, acct3)
#   ./install.sh 5           # installs 5 accounts (acct1..acct5)
#   ./install.sh --uninstall # removes overlays, aliases, and bin dir
#
# After running, in each new terminal:
#   cc1   /login   /exit    # authenticate account 1
#   cc2   /login   /exit    # authenticate account 2
#   ...

set -euo pipefail

# --- Config -----------------------------------------------------------------

SHARED="$HOME/.claude"
BIN_DIR="$HOME/.claude-shared-bin"
WRAPPER="$BIN_DIR/cc-launch.sh"
ZSHRC="${ZSHRC:-$HOME/.zshrc}"
NUM_ACCOUNTS="${1:-3}"

# Things that must stay PRIVATE to each account — never symlinked.
PRIVATE_NAMES=(
  ".credentials.json"   # Linux fallback (macOS uses Keychain)
  "hooks"               # per-account usage tracking
  ".lock"               # Claude's own internal lockfile
  "statsig"             # runtime feature-flag state
  "ide"                 # editor integration state
  "shell-snapshots"     # shell session state
  "todos"               # per-session todo state
)

MARKER_START="# >>> claude-multi-account >>>"
MARKER_END="# <<< claude-multi-account <<<"

# --- Helpers ----------------------------------------------------------------

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*" >&2; }

is_private() {
  local name="$1"
  for p in "${PRIVATE_NAMES[@]}"; do
    [[ "$name" == "$p" ]] && return 0
  done
  return 1
}

remove_zshrc_block() {
  if grep -q "$MARKER_START" "$ZSHRC" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -v s="$MARKER_START" -v e="$MARKER_END" '
      $0==s {skip=1; next}
      $0==e {skip=0; next}
      !skip
    ' "$ZSHRC" > "$tmp" && mv "$tmp" "$ZSHRC"
    return 0
  fi
  return 1
}

# --- Uninstall path ---------------------------------------------------------

if [[ "${1:-}" == "--uninstall" ]]; then
  bold "==> Uninstalling claude-multi"

  # Remove overlay dirs (only if they look like our overlays — symlinks + hooks)
  for d in "$HOME"/.claude-acct*; do
    [[ -d "$d" ]] || continue
    # Safety: only remove if every non-private entry is a symlink
    safe=1
    for entry in "$d"/*; do
      [[ -e "$entry" ]] || continue
      name="$(basename "$entry")"
      if is_private "$name"; then continue; fi
      if [[ ! -L "$entry" ]]; then safe=0; break; fi
    done
    if [[ "$safe" == "1" ]]; then
      rm -rf "$d"
      green "  removed $d"
    else
      yellow "  skipped $d (contains non-symlink content)"
    fi
  done

  # Remove bin dir
  if [[ -d "$BIN_DIR" ]]; then
    rm -rf "$BIN_DIR"
    green "  removed $BIN_DIR"
  fi

  # Remove aliases block
  if remove_zshrc_block; then
    green "  removed alias block from $ZSHRC"
  fi

  echo
  bold "Done. ~/.claude was not touched."
  echo "If you also want to remove keychain entries (macOS), run:"
  echo "  security dump-keychain | grep 'Claude Code-credentials-'"
  echo "  security delete-generic-password -s 'Claude Code-credentials-XXXXXXXX'"
  exit 0
fi

# --- Install path -----------------------------------------------------------

bold "==> Installing claude-multi for $NUM_ACCOUNTS accounts"
echo

# Validate
if ! [[ "$NUM_ACCOUNTS" =~ ^[0-9]+$ ]] || [[ "$NUM_ACCOUNTS" -lt 1 ]] || [[ "$NUM_ACCOUNTS" -gt 9 ]]; then
  red "  NUM_ACCOUNTS must be an integer between 1 and 9 (got '$NUM_ACCOUNTS')"
  exit 1
fi

if [[ ! -d "$SHARED" ]]; then
  red "  $SHARED does not exist."
  red "  Run 'claude' at least once to initialize it, then re-run install."
  exit 1
fi

# Resolve where the wrapper source lives (next to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SRC="$SCRIPT_DIR/bin/cc-launch.sh"
if [[ ! -f "$WRAPPER_SRC" ]]; then
  red "  cannot find $WRAPPER_SRC — run install.sh from the repo root"
  exit 1
fi

# --- 1. Install the wrapper ------------------------------------------------

bold "Step 1: Installing wrapper to $WRAPPER"
mkdir -p "$BIN_DIR"
cp "$WRAPPER_SRC" "$WRAPPER"
chmod +x "$WRAPPER"
green "  installed."
echo

# --- 2. Create overlay dirs -------------------------------------------------

bold "Step 2: Creating $NUM_ACCOUNTS overlay account directories"

ACCOUNTS=()
for i in $(seq 1 "$NUM_ACCOUNTS"); do
  ACCOUNTS+=("$HOME/.claude-acct$i")
done

for acct in "${ACCOUNTS[@]}"; do
  if [[ "$acct" == "$SHARED" ]]; then
    red "  Account dir collides with shared dir: $acct"
    exit 1
  fi

  mkdir -p "$acct"
  mkdir -p "$acct/hooks"

  shopt -s dotglob nullglob
  for src in "$SHARED"/*; do
    name="$(basename "$src")"
    is_private "$name" && continue

    target="$acct/$name"

    if [[ -L "$target" ]]; then
      rm -f "$target"
    elif [[ -e "$target" ]]; then
      if [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]]; then
        red "  REFUSING to replace non-empty real dir $target"
        red "  Move it aside manually, then re-run."
        exit 1
      fi
      if [[ -f "$target" && -s "$target" ]]; then
        red "  REFUSING to replace non-empty real file $target"
        red "  Move it aside manually, then re-run."
        exit 1
      fi
      rm -rf "$target"
    fi

    ln -s "$src" "$target"
  done
  shopt -u dotglob nullglob

  green "  $acct ready"
done
echo

# --- 3. Write zsh aliases ---------------------------------------------------

bold "Step 3: Writing aliases to $ZSHRC"

if remove_zshrc_block; then
  yellow "  removed previous block, will rewrite."
fi

{
  echo ""
  echo "$MARKER_START"
  echo "# Generated by claude-multi install.sh"
  for i in $(seq 1 "$NUM_ACCOUNTS"); do
    echo "alias cc$i='$WRAPPER acct$i $HOME/.claude-acct$i'"
  done
  echo "$MARKER_END"
} >> "$ZSHRC"

green "  aliases written."
echo

# --- 4. Summary -------------------------------------------------------------

bold "==> Done."
cat <<EOF

Layout:
  Shared brain:    $SHARED   (untouched)
  Wrapper:         $WRAPPER
  Account dirs:    ${ACCOUNTS[*]}

Next steps:

  1. Reload your shell:
       source ~/.zshrc

  2. Authenticate each account (open a new terminal for each if you prefer):
EOF
for i in $(seq 1 "$NUM_ACCOUNTS"); do
  echo "       cc$i      # then run /login inside Claude, then /exit"
done
cat <<EOF

  3. Use cc1, cc2, ... interchangeably. Memory, projects, skills, agents,
     and commands are shared. Only credentials and hooks/ are per-account.

Concurrency:
  Only one account can run at a time (enforced by $HOME/.claude-multi.lock).
  Trying to launch a second account will print which account is busy.

Uninstall: ./install.sh --uninstall

EOF
