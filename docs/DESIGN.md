# Design

Background on why claude-multi is shaped the way it is. Skip if you just want to use it.

## The problem

Claude Code stores everything for one account under one directory (`~/.claude` by default). One directory means one account. People with multiple subscriptions (work, personal, client; or just two seats for rate-limit failover) end up with parallel `~/.claude-work` / `~/.claude-personal` setups that quickly drift out of sync — skills added to one don't appear in the other, memory accumulates separately, CLAUDE.md has to be hand-mirrored.

The goal: **one accumulated brain, multiple credentials**.

## The two mechanisms Claude Code already exposes

1. `CLAUDE_CONFIG_DIR` env var — relocates the config directory.
2. On macOS, credentials live in the Keychain under a service name `Claude Code-credentials-<sha256-prefix-of-config-dir>`. Different config dirs → different keychain entries automatically.

Together these mean: if I have three different config dirs, I get three independently-authenticated accounts for free. The remaining question is just how to share the *contents* of those config dirs.

## Why symlink overlays

Three approaches considered:

1. **Copy** `~/.claude` into each account dir.
   Rejected: drift. Every memory write, every new skill, every project would diverge across accounts immediately. Defeats the whole purpose.

2. **Bind-mount / overlayfs** the shared dir into each account dir.
   Rejected: macOS support is bad-to-nonexistent. Even on Linux it requires root, and reverting is painful.

3. **Symlink** each top-level entry from `~/.claude` into each account dir.
   Chosen: universal, no privileges, trivially reversible (delete the symlinks).

The overlay pattern lets us pick *which* paths are shared vs. private at install time:

- **Shared**: `CLAUDE.md`, `settings.json`, `projects/`, `skills/`, `agents/`, `commands/`, and anything else top-level we don't explicitly know to be private. This means new top-level entries created by future Claude Code versions are shared by default — fail-open in the direction of sharing.

- **Private (real files/dirs in each overlay)**: `.credentials.json` (Linux), `hooks/`, `.lock`, `statsig/`, `ide/`, `shell-snapshots/`, `todos/`. These are either auth (must not be shared) or runtime state (sharing would cause lock fights and stale-state bugs).

The PRIVATE_NAMES list is the most likely thing to need updating as Claude Code evolves. If a future version writes a new auth-y or stateful file at the top level, add it to the list.

## Why a lockfile

Per the Claude Code session-memory docs, summaries are written every ~5k tokens or every 3 tool calls. Writes are last-write-wins. If account 1 and account 2 are both editing the same project at the same time:

- Both load the same starting summary
- Both write back at different points
- The later writer overwrites the earlier writer's progress

For a failover use case (use cc1 until rate limit, switch to cc2) this never happens — you exit one before starting the other. But the wrapper is cheap insurance against accidentally double-launching.

The lock holds the account label + PID. `kill -0 <pid>` checks liveness without sending an actual signal. Stale locks (PID dead) are detected and cleared.

Nested invocations (same account, launched again in another tab) are allowed and don't release the outer lock on inner exit — this matches user expectation that running `cc1` twice should "just work" while still blocking `cc2`.

## Why we don't `exec claude`

First draft used `exec claude` so the wrapper would be replaced by the actual process. Problem: `exec` replaces the wrapper, so the trap for lock cleanup never fires. The lock would leak on every clean exit.

Switched to `claude "$@"; exit $?` — the wrapper stays alive as parent, the trap fires on any exit path (clean exit, SIGINT, SIGTERM, SIGHUP), the lock is released. Slight cost: one extra process in the tree. Worth it.

## Why the install script is idempotent

Users will re-run it. They'll add new top-level files to `~/.claude` and want overlays to pick them up. They'll bump the account count from 3 to 5. They'll edit the wrapper and need it reinstalled.

So the script:
- Refreshes symlinks (removes existing, creates fresh — handles new top-level entries automatically)
- Removes any prior alias block before writing a new one (no duplicates)
- Refuses to clobber non-empty real files or directories (defensive — if you put something real in an overlay path, the script bails loudly instead of silently destroying it)

## Why testing uses a fake `claude`

Tests can't assume Claude Code is installed in CI. The test harness drops a tiny bash script named `claude` onto a fake `PATH` and exercises the wrapper end-to-end. That covers the wrapper's lifecycle (acquire, hold, release, signal handling, exit-code propagation) without needing real auth.

The install tests use a fake `$HOME` so the real filesystem is never touched.

## Known limitations

- **macOS keychain prompts.** Re-authenticating an overlay may prompt for keychain access permission once. After that it's silent. SSH sessions can't access the keychain at all — that's an upstream Claude Code limitation.
- **Cross-machine sync.** The project hash is derived from the absolute config-dir path. If you sync `~/.claude` across two machines with different usernames, the project subdirs won't line up. Out of scope for this tool; use Syncthing/git with matching paths if you need it.
- **Bash only, zsh aliases.** The aliases assume `~/.zshrc`. Bash users can pass `ZSHRC=~/.bashrc`. Fish needs adapted alias syntax.
- **No Windows.** The install script is bash; symlinks on Windows have their own permission issues. Workaround: run under WSL, which works fine.

## What I'd change if I rewrote this

- Make the lockfile use `flock` on Linux for atomic locking — the current PID check has a small TOCTOU window between checking and writing. In practice it doesn't matter (you're not racing two `cc1` invocations within a millisecond), but it would be cleaner.
- Generate aliases for fish and bash too, not just zsh.
- Add a `cc-status` command that reads the lockfile and reports who holds it, instead of relying on `/status` inside Claude.
