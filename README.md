# claude-multi

Run multiple Claude Code accounts that share **one brain** (memory, projects, skills, agents, commands, settings) but keep **separate credentials**. Designed for users who want a few subscriptions as rate-limit failovers without losing context when they switch.

## What this gives you

```
~/.claude/                   ← your existing brain, untouched
    CLAUDE.md
    settings.json
    projects/                ← session memory + auto-memory
    skills/
    agents/
    commands/
    ...

~/.claude-acct1/             ← overlay for account 1
    hooks/                   (real, per-account)
    CLAUDE.md       → ~/.claude/CLAUDE.md
    projects        → ~/.claude/projects
    skills          → ~/.claude/skills
    ...                      (everything else symlinked back)

~/.claude-acct2/             (same shape, account 2)
~/.claude-acct3/             (same shape, account 3)
```

After install, you get aliases:

```bash
cc1   # launch as account 1
cc2   # launch as account 2
cc3   # launch as account 3
```

All three accounts read and write the same `~/.claude/projects/...` files, so when account 1 hits its rate limit, you switch to `cc2` and pick up exactly where you left off — same memory, same skills, same session history.

## How credentials stay separate

On macOS, Claude Code stores credentials in the **Keychain** under a service name derived from `CLAUDE_CONFIG_DIR` (sha256 prefix). Three different overlay dirs → three different keychain entries → three independently-authenticated accounts.

On Linux/Windows, credentials are in `<config-dir>/.credentials.json` (which the installer explicitly leaves out of the symlink set).

## Concurrency safety

Claude Code's session-memory writes are last-write-wins. Two accounts hitting the same `projects/` directory at the same time will clobber each other's summaries.

This tool installs a wrapper (`cc-launch.sh`) that uses a lockfile at `~/.claude-multi.lock` to enforce **only one account active at a time**. Trying to launch a second account prints a clear refusal message; stale locks (from crashed processes) are auto-detected and cleared.

## Install

```bash
git clone https://github.com/YOU/claude-multi.git
cd claude-multi
./install.sh
```

Default is 3 accounts. To install for a different count (1–9):

```bash
./install.sh 5
```

Then in any **new** terminal:

```bash
source ~/.zshrc
cc1     # /login as account 1, then /exit
cc2     # /login as account 2, then /exit
cc3     # /login as account 3, then /exit
```

After that, `cc1` / `cc2` / `cc3` are your daily switches.

## Verify it's working

```bash
# Inside cc1, run /status — note the email
# Inside cc2, run /status — should be a different email
```

Or from your shell:

```bash
# One keychain entry per account on macOS
security dump-keychain 2>/dev/null | grep "Claude Code-credentials-"

# Symlinks look right
ls -la ~/.claude-acct1
```

## Important: remove `CLAUDE_CODE_OAUTH_TOKEN`

If you ever ran `claude setup-token`, you have `export CLAUDE_CODE_OAUTH_TOKEN=...` somewhere in your shell config. **This env var overrides the keychain** — all three accounts will silently use the same token. Remove it before relying on the failover.

```bash
# Find it
grep -n "CLAUDE_CODE_OAUTH_TOKEN" ~/.zshrc ~/.zshenv ~/.zprofile 2>/dev/null

# Delete the line, then in current shell:
unset CLAUDE_CODE_OAUTH_TOKEN
```

## Uninstall

```bash
./install.sh --uninstall
```

Removes the overlay dirs (only if they look untampered), the wrapper, and the alias block. **Does not touch `~/.claude`** or your keychain entries. Keychain cleanup commands are printed at the end if you want them.

## Tests

```bash
bash test/run-all.sh
```

Runs two suites (no real Claude Code install needed — uses a fake `claude` on PATH):

- `test-install.sh` — install/symlink behavior, idempotency, write-through, uninstall
- `test-lock.sh` — lockfile acquire/release, blocking, nested invocations, stale-lock recovery, signal handling, exit-code propagation

## Layout

```
.
├── README.md
├── install.sh              # install / uninstall driver
├── bin/
│   └── cc-launch.sh        # lock wrapper (installed to ~/.claude-shared-bin/)
├── test/
│   ├── run-all.sh
│   ├── test-install.sh
│   └── test-lock.sh
└── docs/
    └── DESIGN.md           # why it's built this way
```

## FAQ

**Q: Why not just copy `~/.claude` into each account dir?**
Then they wouldn't share a brain. The point is one source of truth for memory and skills, with multiple credentials pointing at it.

**Q: Why symlink instead of `mount --bind` or overlayfs?**
macOS lacks both. Symlinks are universal, portable, and trivially reversible. The tradeoff is that the lockfile is needed to prevent concurrent-write races.

**Q: Can I run two accounts at the same time?**
Not against the same project. The wrapper refuses by design. If you really need parallel work, use git worktrees so each account is operating on a different directory — then the lockfile is what you'd want to disable (edit the wrapper).

**Q: Does this violate Anthropic's terms?**
Check Anthropic's usage policy. The general practice of running multiple subscriptions is grey-ish; this tool doesn't do anything beyond what `CLAUDE_CONFIG_DIR` already enables natively.

**Q: zsh only?**
The aliases are written into `~/.zshrc`. For bash, set `ZSHRC=~/.bashrc ./install.sh`. For fish, you'd need to adapt the alias syntax — open an issue.

## License

MIT.
