---
name: codex
description: Hand a self-contained coding or analysis task to the OpenAI Codex CLI and get its answer back. Use when the user says to ask/delegate to codex, wants a second opinion from another model, or wants work done in parallel by another agent. Also use for "get codex to ...", "have codex review ...", or /codex.
compatibility: Requires the `codex` CLI on PATH and an authenticated Codex session (`codex login status`).
---

# Delegating to Codex

Codex runs as a separate agent with its own context. It shares no memory with this session, so the task has to carry everything it needs. Say what to do, where to do it, and what to return.

The entry point is `{baseDir}/codex-run.sh`, where `{baseDir}` is the absolute directory containing this `SKILL.md`. Always invoke that absolute path.

## Usage

```bash
{baseDir}/codex-run.sh "<task>"                                       # read-only by default
{baseDir}/codex-run.sh --sandbox workspace-write "<task>"             # let it edit files
{baseDir}/codex-run.sh --worktree --sandbox workspace-write "<task>"  # edit in an isolated worktree
{baseDir}/codex-run.sh --cd ~/someproject "<task>"                    # set the working root
{baseDir}/codex-run.sh --schema shape.json "<task>"                   # force JSON-shaped output
{baseDir}/codex-run.sh --model gpt-6-astra "<task>"                   # model override
{baseDir}/codex-run.sh --quiet "<task>"                               # no progress trace
```

The final answer goes to stdout. A live progress trace goes to stderr. The exit code is
Codex's own, so non-zero means the run failed.

## Run it in the background and watch it

A Codex run takes minutes. In the foreground it is a frozen shell call that shows nothing
until it ends. Launch it with `run_in_background: true` instead, then poll `TaskOutput` and
relay what Codex is doing, the way a subagent reports in.

1. Start the run in the background.
2. Poll `TaskOutput` every 30 to 60 seconds.
3. Summarize each new stretch of trace for the user in a line or two: the commands it ran,
   the files it touched, what it is on now. Do not paste the raw trace.
4. On exit, the final message is the last thing on stdout.

The trace is one stamped line per event:

```
[00:01] ◆ session 01a0a8cf-8b5c-7830-966d-dfce90b8b901
[00:03]   ▸ I'll run the commands in order.
[00:03]   $ /usr/bin/bash -lc 'uname -r'
[00:03]     ↳ exit 0  7.2.5-1-cachyos
[00:12]   ✎ edit /home/you/project/src/main.rs
[00:21] ◆ done · 100832 in / 225 out tokens
```

`◆` session and turn boundaries, `▸` a message from Codex, `·` reasoning, `$` a shell
command with its `↳` result, `✎` file changes, `⚙` an MCP tool call, `⌕` a web search,
`☑` a todo update, `✗` an error. The clock is elapsed time, so a step that has stalled
looks stalled.

Pass `--quiet` when the trace has no reader, such as a scripted call that only wants
stdout. It also holds back Codex's own transcript, which Codex writes to stderr. A failed
run still gets that transcript, since it is the only diagnostic left. The trace needs
`jq`; without it the run is silent but otherwise unchanged.

## Choosing a sandbox

`read-only` is the default and suits reviews, audits, and questions. Escalate only when the task needs to write.

| mode | grants | use for |
|---|---|---|
| `read-only` | read files, no writes | reviews, explanations, "find the bug" |
| `workspace-write` | write inside the working root | implementing a change |
| `danger-full-access` | no sandbox | avoid, prefer `--worktree` plus `workspace-write` |

Pair `workspace-write` with `--worktree` whenever the caller's tree should stay untouched. Codex clones into its own worktree under `~/.codex/worktrees/`, writes only there, and `codex apply` brings the diff back. I checked this: a run that created a file left the original checkout unchanged.

## Writing the task

Codex sees none of this conversation. A task that assumes shared context will fail or invent its own.

- Name absolute paths, never "the file we just discussed"
- State the return shape, such as "reply with only the function body" or "list each finding on one line"
- Put the acceptance criteria in the prompt, because nothing downstream checks its work
- For machine-readable results, pass `--schema` with a JSON Schema file and parse stdout

## Cost

Every invocation pays a large fixed overhead. A prompt answered with one word still consumed about 15,900 tokens of Codex context. Batch related questions into one delegation instead of firing off several small ones.

## Continuing a session

`codex-run.sh` starts a fresh session each time. To continue or branch one, call the CLI directly.

```bash
codex exec resume --last "<follow-up>"   # continue the most recent session
codex exec fork <session-id> "<variant>" # branch an earlier session
```

## Do not point it at its own script

A `workspace-write` run that edits `codex-run.sh` corrupts the invocation that
launched it. Bash reads a script lazily, so rewriting the file mid-run makes the
running shell resume at a byte offset in the new text and die on a syntax error
it reports against a line that looks fine. This happened once. The agent's work
was complete and correct on disk, but the wrapper exited 2 before copying the
final message to `--out`.

Pass `--worktree` when the task touches this skill, or recover the answer from
`~/.codex/sessions/` afterwards.

## Verify the result

Codex reports its own success, which is a claim rather than proof. It once replied "DONE" for a file-creation task whose output took a second look to locate. Read the diff it produced, or run the tests yourself, before telling the user the work is done.

## Exit codes

Every exit code is Codex's own except these three, which the wrapper raises
itself:

| code | meaning |
|---|---|
| 2 | bad arguments to `codex-run.sh` |
| 3 | Codex succeeded but its answer could not be delivered, such as a failed `--out` copy or an empty final message |
| 124 | the run hit `--timeout` |

`124` is reported only when the cap actually fired. A Codex process killed by an
unrelated SIGTERM keeps its own `143`.

## Gotchas already handled

`codex-run.sh` covers the things that each break a hand-rolled `codex exec`:

- stdin is closed. Codex otherwise blocks on reading it.
- `--skip-git-repo-check` is always passed. Codex refuses to run in any directory that is not a *trusted* git repo, not merely any directory that is not a git repo.
- `--enable worktrees` goes alongside `--worktree`, which is gated behind that feature flag.
- The task comes after `--`, so a prompt opening with a dash is not read as a Codex option.
- The exit code comes from `PIPESTATUS`, so the formatter does not mask Codex's own.
- `--timeout` escalates from TERM to KILL. A process that ignores TERM still stops.
- The watchdog checks the whole process group rather than the leader, so a descendant that outlives its parent is still stopped at the cap instead of holding the pipe open.
- macOS has no `timeout(1)`, so the script falls back to a shell watchdog there instead of exiting 127.
- That watchdog is kept off the caller's descriptors. Otherwise its `sleep` would hold the output pipe open for the full timeout after a fast run had already finished.
- In that fallback the child runs in its own process group, via `setsid` or perl's `setpgrp`, so the kill reaches descendants that would otherwise outlive it and keep the pipe open. Job control is turned off first, because `setsid` forks rather than execs when it is already a group leader.
- `124` is reported only when the run lasted the full cap plus the kill grace, timed in milliseconds. An OOM kill or any other outside SIGKILL keeps its own status.
- Every field in the trace filter is coerced, so an event carrying an array where a string was expected is still rendered instead of dropped.
- The bogus "Reading additional input from stdin..." notice Codex prints anyway is swallowed. It is matched as a whole line, so a real error quoting it survives.
- Descendants that outlive Codex itself are stopped once it exits, on both timeout paths. `timeout(1)` exits with its child and cancels its timer, so a server the agent left running with `&` would otherwise hold the trace pipe open with nothing left to kill it. Measured: a 1s cap, a leftover `sleep 30`, and the wrapper still waiting at 12s.
- A TERM or HUP to the wrapper stops Codex's process group before the temp files are removed. Left alone, Codex kept running and recreated its `-o` file after the cleanup had deleted it.
- The transcript filter reads with `grep -a`, so a NUL byte in Codex's stderr does not replace the diagnostic with "binary file matches".

## Finding the codex binary over ssh

Package managers put the CLI somewhere a login shell searches and a
non-interactive shell does not. A plain `ssh host 'codex-run.sh ...'` then exits
2 with `codex-run: codex CLI not found on PATH`. Seen with a Homebrew cask in
`/opt/homebrew/bin` on macOS and with an npm global prefix in
`~/.npm-global/bin` on Ubuntu. Export the directory first when driving the
wrapper over ssh.

## Platforms

Both have been run against a real Codex, and neither needs configuration.

**Linux** takes the primary path and asks nothing of you. `timeout(1)` caps the
run and `setsid` puts the child in its own process group. Verified on Ubuntu
26.04, x86_64, bash 5.3, Codex 0.144.4. One caveat belongs to this path rather
than to the platform: the cap overshoot in the limitations below is twice as
large here as on macOS.

**macOS** takes the fallback throughout, because Apple ships neither
`timeout(1)` nor `setsid`, and `/bin/bash` is 3.2. The perl `setpgrp` launcher
starts the child instead, and `now_ms` reads `date +%s%N` rather than
`EPOCHREALTIME`, which bash 3.2 does not define. Both work: a descendant left
running was stopped in 153ms, and a 1-second sleep measured 1016ms. Verified on
macOS 26.6.2, arm64, Codex 0.154.0. Perl is required; it ships with the system.

## Known limitations

Four defects are documented rather than fixed.

- With `timeout(1)`, `gtimeout`, `setsid` and perl all absent, the watchdog can signal only the direct child. A descendant that child leaves behind can outlive the cap and hold the output pipe open. The script prints `codex-run: no setsid or perl; --timeout cannot reach grandchild processes` on stderr at startup and continues.
- Bash has no monotonic clock. On the `timeout(1)` path the `124` versus `137` decision reads the wall clock, so a clock adjustment mid-run skews it. A backward step can leave a real timeout reported as `137`.
- A timed-out run overshoots its cap by a fixed amount, because the kill grace is spent in series rather than shared. On the `timeout(1)` path `timeout -k` waits `KILL_GRACE` for the leader and the group cleanup then waits `KILL_GRACE` again for anything still alive, so the wrapper returns after roughly `TIMEOUT + 2 x KILL_GRACE`. Measured on Ubuntu with the default 10s grace: a 2s cap returned 124 after 22.4s and a 5s cap after 25.4s, a constant 20.4s tail. The fallback path spends the grace once, so macOS measured a 2s cap at 13.4s. At the default 1800s cap this is under 2%; at a cap of a few seconds it dominates.
- A SIGINT to the wrapper does not cancel the run. Bash holds the signal while the foreground pipeline runs, so Codex finishes and the wrapper exits with its code as if nothing happened. Send TERM to cancel.
