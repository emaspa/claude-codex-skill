# Claude Codex skill

A Claude Code skill for handing a self-contained coding or analysis task to the Codex CLI and getting its answer back. Codex runs as a separate agent with its own context, so each task needs to say what to do, where to work, and what to return.

`codex-run.sh` wraps `codex exec` and streams a live progress trace to stderr instead of blocking silently. The final answer goes to stdout. The wrapper closes stdin to prevent Codex from waiting for input, handles the trusted-repository check and worktree feature flag, preserves Codex's status through the trace pipeline, and manages timeouts and process cleanup.

## Requirements

- Bash.
- The `codex` CLI on `PATH` and an authenticated session. Check with `codex login status`.
- `jq` for the live progress trace. Without it, the run still works but has no progress trace.

The wrapper also works on macOS without `timeout` or `setsid`, using a shell watchdog and a Perl `setpgrp` launcher. The source documentation records testing on macOS 26.6.2 with Bash 3.2. Perl must be available for that launcher.

## Installation

Clone into Claude Code's skills directory:

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/emaspa/claude-codex-skill.git ~/.claude/skills/codex
```

Or clone elsewhere and symlink it:

```bash
mkdir -p ~/src ~/.claude/skills
git clone https://github.com/emaspa/claude-codex-skill.git ~/src/claude-codex-skill
ln -s ~/src/claude-codex-skill ~/.claude/skills/codex
```

## Usage

In Claude Code, invoke `/codex` with a self-contained task, or ask it to delegate a task to Codex.

You can also run the wrapper from a terminal. This example reviews the current directory using the default `read-only` sandbox:

```bash
~/.claude/skills/codex/codex-run.sh --cd "$PWD" \
  "Review this project for bugs. Return findings with file paths and line numbers."
```

Use `--sandbox workspace-write` for tasks that need to edit files, and add `--worktree` to work in an isolated worktree. Use `--quiet` to suppress the progress trace.

## Exit codes

| Code | Meaning |
| --- | --- |
| `2` | Bad arguments to the wrapper. |
| `3` | Codex succeeded, but its answer could not be delivered. |
| `124` | The run timed out. |
| Otherwise | Codex's own exit status. |

See [SKILL.md](SKILL.md) for the full reference, background execution in Claude Code, platform notes, and known limitations. The wrapper's option list is also available with `~/.claude/skills/codex/codex-run.sh --help`.

## License

[MIT](LICENSE)
