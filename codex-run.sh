#!/usr/bin/env bash
# Delegate one task to the Codex CLI, non-interactively, and return its answer.
#
# Encodes the non-obvious parts of `codex exec` so callers cannot get them wrong:
#   - stdin MUST be closed, or codex blocks on "Reading additional input from stdin..."
#   - codex refuses to run unless the directory is a TRUSTED git repo
#   - --worktree is gated behind a feature flag and needs --enable worktrees
#   - piping codex into another command masks its real exit code
#   - macOS has no timeout(1) or gtimeout, so the cap needs a shell watchdog
#   - a long run with no output looks hung, so events are streamed as they arrive
#
# Usage: codex-run.sh [options] "<task>"
#   --sandbox MODE   read-only | workspace-write | danger-full-access (default: read-only)
#   --worktree       run in a managed git worktree, isolating the caller's tree
#   --cd DIR         working root for the agent (default: current directory)
#   --model NAME     model override
#   --schema FILE    JSON Schema the final response must conform to
#   --timeout SECS   wall-clock cap (default: 1800)
#   --out FILE       also copy the final message here
#   --quiet          suppress the live progress trace on stderr
#   --json           stream raw JSONL events to stderr for debugging
set -uo pipefail

SANDBOX="read-only"
WORKTREE=0
WORKDIR="$PWD"
MODEL=""
SCHEMA=""
TIMEOUT=1800
OUTFILE=""
JSONL=0
STREAM=1
KILL_GRACE=10

die() { echo "codex-run: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --sandbox|--cd|--model|--schema|--timeout|--out)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value" ;;
  esac
  case "$1" in
    --sandbox)  SANDBOX="${2:?--sandbox needs a value}"; shift 2 ;;
    --worktree) WORKTREE=1; shift ;;
    --cd)       WORKDIR="${2:?--cd needs a value}"; shift 2 ;;
    --model)    MODEL="${2:?--model needs a value}"; shift 2 ;;
    --schema)   SCHEMA="${2:?--schema needs a value}"; shift 2 ;;
    --timeout)  TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --out)      OUTFILE="${2:?--out needs a value}"; shift 2 ;;
    --quiet)    STREAM=0; shift ;;
    --json)     JSONL=1; STREAM=0; shift ;;
    -h|--help)  sed -n '2,21p' "$0"; exit 0 ;;
    --)         shift; break ;;
    -*)         die "unknown option: $1" ;;
    *)          break ;;
  esac
done

TASK="${1:-}"
[ -n "$TASK" ] || die "no task given. Usage: codex-run.sh [options] \"<task>\""
shift
# Options are parsed only before the task, so trailing ones would be silently
# dropped. Fail loudly instead of quietly ignoring them.
[ $# -eq 0 ] || die "unexpected argument(s) after the task: $*. Options must come BEFORE the task."
command -v codex >/dev/null 2>&1 || die "codex CLI not found on PATH"
[ -d "$WORKDIR" ] || die "--cd directory does not exist: $WORKDIR"

case "$SANDBOX" in
  read-only|workspace-write|danger-full-access) ;;
  *) die "invalid --sandbox: $SANDBOX" ;;
esac

# An unvalidated timeout reaches `sleep` and timeout(1), which disagree about
# what it means: GNU timeout treats 0 as "no limit", the shell watchdog treats
# it as "fire now", and a non-numeric value makes `sleep` fail instantly, which
# the watchdog cannot tell from an expiry.
case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be a whole number of seconds: $TIMEOUT" ;;
esac
# Strip leading zeroes before arithmetic, where Bash would interpret them as
# octal. Compare lengths first so even an arbitrarily long input cannot wrap.
TIMEOUT="${TIMEOUT#"${TIMEOUT%%[!0]*}"}"
TIMEOUT="${TIMEOUT:-0}"
max_timeout=$((9223372036854775807 / 1000 - KILL_GRACE))
if [ "${#TIMEOUT}" -gt "${#max_timeout}" ] ||
   { [ "${#TIMEOUT}" -eq "${#max_timeout}" ] && [ "$TIMEOUT" -gt "$max_timeout" ]; }; then
  die "--timeout must not exceed $max_timeout seconds"
fi
TIMEOUT=$((10#$TIMEOUT))
[ "$TIMEOUT" -gt 0 ] || die "--timeout must be greater than 0"

# TERM a process group, escalate to KILL after the grace period, and return
# once nothing in it is left. Used for descendants that outlive the run and for
# the whole group when the wrapper itself is signalled.
#
# The body is a subshell, which starts with an empty job table. Bash's `kill`
# builtin resolves `-<pid>` through the job table first, and when the shell
# inherited job control (SHELLOPTS=monitor) it signals the job's recorded
# process group, which is the caller's own pipeline. Measured: a wrapper
# started under monitor exited 143 from the TERM it had sent to codex's group
# after codex had already finished. A forked shell knows no jobs and signals
# the group it was asked to.
stop_group() (
  local g=$1 waited=0
  kill -0 -"$g" 2>/dev/null || return 0
  kill -TERM -"$g" 2>/dev/null
  while [ "$waited" -lt "$((KILL_GRACE * 10))" ]; do
    kill -0 -"$g" 2>/dev/null || return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -KILL -"$g" 2>/dev/null
)

# The trap is armed before any allocation, with all names already defined, so
# no path between the mktemps can exit without cleanup. Empty names make
# `rm -f` a no-op, so arming it early is safe.
#
# Bash runs the EXIT trap on an untrapped TERM or INT too, while codex is
# still running. Left alone, codex would outlive the wrapper and recreate the
# final-message file after it was removed. GROUP holds the live process group
# id, written by run_with_timeout and blanked once the group is gone, so the
# trap stops the run first and never signals a recycled group id.
LAST=""
ERRLOG=""
GROUP=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  local g
  g=$(cat "$GROUP" 2>/dev/null)
  [ -n "$g" ] && stop_group "$g"
  rm -f "$LAST" "$ERRLOG" "$GROUP"
}
trap cleanup EXIT
LAST="$(mktemp -t codex-last.XXXXXX)" || die "could not create a temp file for the final message"
ERRLOG="$(mktemp -t codex-err.XXXXXX)" || die "could not create a temp file for stderr"
GROUP="$(mktemp -t codex-group.XXXXXX)" || die "could not create a temp file for the process group"

ARGS=(exec --sandbox "$SANDBOX" --cd "$WORKDIR" -o "$LAST" --color never)

# Codex refuses to run unless the directory is a TRUSTED git repo, so being in a
# git repo is not enough: an untrusted one fails with "Not inside a trusted
# directory". Always pass the flag. It only skips that gate; --sandbox still
# governs what the agent may touch.
ARGS+=(--skip-git-repo-check)

# --worktree is gated behind a feature flag; without --enable it errors out.
[ "$WORKTREE" -eq 1 ] && ARGS+=(--enable worktrees --worktree)
[ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
{ [ "$JSONL" -eq 1 ] || [ "$STREAM" -eq 1 ]; } && ARGS+=(--json)
if [ -n "$SCHEMA" ]; then
  [ -f "$SCHEMA" ] || die "--schema file not found: $SCHEMA"
  ARGS+=(--output-schema "$SCHEMA")
fi

# The task goes last, after `--`, so one that opens with a dash is read as the
# prompt rather than as a codex option.
ARGS+=(-- "$TASK")

# macOS ships neither timeout(1) nor gtimeout, so a hardcoded `timeout` call
# exits 127 there and the run looks like a codex failure. Fall back to a shell
# watchdog. Either way a TERM that the child ignores is escalated to KILL.
# The watchdog records expiry explicitly; timeout(1) needs precise timing to
# distinguish escalation from an early outside SIGKILL.
# Milliseconds since the epoch. $SECONDS is a whole-second counter, so a run
# killed 0.31s in could read as a full second elapsed and be misfiled as a
# timeout. EPOCHREALTIME carries microseconds; its decimal separator follows the
# locale, hence the comma. Older Bash can use date's nanoseconds if supported;
# a seconds-only clock cannot distinguish an early external kill from escalation.
# Both sources follow the wall clock, so a clock adjustment mid-run can still
# skew the reading.
now_ms() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then
    t="${EPOCHREALTIME/,/.}"
    echo $(( ${t%%.*} * 1000 + 10#${t#*.} / 1000 ))
  else
    t=$(date +%s%N) || return 1
    [[ "$t" =~ ^[0-9]{19}$ ]] || return 1
    echo $((10#$t / 1000000))
  fi
}

run_with_timeout() (
  local rc started ended elapsed pid
  # Job control off, for both paths: see the setsid note below. The function's
  # subshell keeps this change out of the caller's shell.
  set +m
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    local runner=timeout
    command -v timeout >/dev/null 2>&1 || runner=gtimeout
    started=$(now_ms) || started=""
    # Backgrounded so its pid is known. timeout(1) makes itself the leader of a
    # new process group, so that pid is also the group id. It exits as soon as
    # codex does and cancels its timer, so a descendant codex left behind, such
    # as a server started with `&`, would hold the output pipe open forever
    # with nothing left to kill it. Measured: a 1s cap, a leftover `sleep 30`,
    # and the wrapper still running at 12s. Stop whatever outlived the leader.
    "$runner" -k "$KILL_GRACE" "$TIMEOUT" "$@" &
    pid=$!
    printf '%s' "$pid" > "$GROUP"
    { wait "$pid"; } 2>/dev/null; rc=$?
    stop_group "$pid"
    : > "$GROUP"
    # timeout(1) returns 124 for the TERM it sent, and 137 once it escalates to
    # KILL, which is indistinguishable from an OOM kill or any other outside
    # SIGKILL. Its own escalation cannot land before the cap plus the grace
    # period, so anything earlier than that keeps its 137.
    if [ "$rc" -eq 137 ] && [ -n "$started" ] && ended=$(now_ms); then
      elapsed=$((ended - started))
      if [ "$elapsed" -ge $(( (TIMEOUT + KILL_GRACE) * 1000 )) ]; then
        rc=124
      fi
    fi
    return "$rc"
  fi

  # A file, not a variable: the watchdog runs in a subshell, so an expiry it
  # records in a variable would never be visible here. Without it, a child that
  # traps TERM and exits 0 reports success for a run that was cut short, and an
  # unrelated SIGTERM is misreported as a timeout.
  local flag; flag="$(mktemp -t codex-timeout.XXXXXX)" || return 125
  rm -f "$flag"

  # Start the child in its own process group where the platform offers a way,
  # so the kill reaches its descendants too. Without this the fallback signals
  # only the immediate PID, and a surviving grandchild keeps the output pipe
  # open past the cap. `setsid` covers Linux; macOS has no setsid(1) but does
  # ship perl, whose setpgrp does the same job.
  #
  # Job control has to be off first. setsid(1) execs in place only when it is
  # not already a process-group leader, and job control makes every background
  # job exactly that, so it forks instead: $! would then name a launcher that
  # exits at once, `wait` would return 0 immediately, and the real task would run
  # on past its cap. Measured hanging with an inherited SHELLOPTS=monitor.
  local group=0
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" &
    group=1
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'setpgrp; exec @ARGV; print STDERR "codex-run: cannot execute $ARGV[0]: $!\n"; exit 127' -- "$@" &
    group=1
  else
    # Neither helper: only the direct child can be signalled, so a descendant it
    # leaves behind outlives the cap and holds the output pipe open.
    "$@" &
  fi
  pid=$!
  [ "$group" -eq 1 ] && printf '%s' "$pid" > "$GROUP"

  alive() {
    # The group can survive its leader, and the launcher can briefly exist
    # before establishing the group. Either one still needs supervision.
    { [ "$group" -eq 1 ] && kill -0 -"$pid" 2>/dev/null; } ||
      kill -0 "$pid" 2>/dev/null
  }

  (
    # Detached from the caller's descriptors. A watchdog that inherited the
    # pipeline's write end would hold that pipe open for the whole timeout, so
    # the reader would sit there long after the child had exited.
    exec >/dev/null 2>&1 </dev/null
    local waited=0
    while [ "$waited" -lt "$((TIMEOUT * 10))" ]; do
      alive || exit 0
      sleep 0.1
      waited=$((waited + 1))
    done
    alive || exit 0
    : > "$flag"
    [ "$group" -eq 1 ] && kill -TERM -"$pid" 2>/dev/null
    kill -TERM "$pid" 2>/dev/null
    local grace=0
    while [ "$grace" -lt "$((KILL_GRACE * 10))" ]; do
      alive || break
      sleep 0.1
      grace=$((grace + 1))
    done
    # The group is signalled even once the leader is gone, since a descendant
    # that outlives it still holds the pipe.
    [ "$group" -eq 1 ] && kill -KILL -"$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
    exit 0
  ) &
  local watchdog=$!

  # Braces with stderr dropped: when the watchdog kills the child, bash otherwise
  # announces the job death ("Killed  setsid ...") on the caller's stderr. The
  # exit status survives the redirection.
  { wait "$pid"; } 2>/dev/null; rc=$?
  # Descendants that outlived the leader would hold the output pipe open until
  # the cap. Stop them now, as on the timeout(1) path.
  [ "$group" -eq 1 ] && stop_group "$pid"
  : > "$GROUP"
  # The watchdog sees the group gone on its next poll and exits. Waiting for it
  # rather than killing it keeps its sleep from being orphaned.
  wait "$watchdog" 2>/dev/null

  [ -e "$flag" ] && rc=124
  rm -f "$flag"
  return "$rc"
)

# Turns the JSONL event stream into one readable line per thing that happened,
# so a caller watching stderr sees the run progress instead of a silent wait.
# jq is optional: without it the trace is simply skipped.
#
# Every field is coerced through `s`, and the whole per-record transform sits in
# a try/catch. Parsing was already safe, but the formatting was not: an event
# whose `text` arrived as an array, or a bare `42` on its own line, threw and
# took that event out of the trace.
STREAM_FILTER='
def s: if . == null then "" elif type == "string" then . else tostring end;
def clip($n): s | if (. | length) > $n then (.[0:$n] + "…") else . end;
def flat: s | gsub("\\s+"; " ") | sub("^ +"; "") | sub(" +$"; "");
(try fromjson catch null) as $e
| if ($e | type) != "object" then empty else
  try (
  $e.type as $t
  | if   $t == "thread.started" then "◆ session \($e.thread_id | s)"
    elif $t == "turn.completed" then "◆ done · \($e.usage.input_tokens // 0) in / \($e.usage.output_tokens // 0) out tokens"
    elif $t == "turn.failed"    then "✗ turn failed: \($e.error.message // "unknown" | flat)"
    elif $t == "error"          then "✗ \($e.message // ($e | tostring) | flat)"
    elif ($t == "item.started" or $t == "item.completed") then
      $e.item as $i
      | if ($i | type) != "object" then empty else
        $i.type as $k
        | if $k == "command_execution" then
            if $t == "item.started"
            then "  $ \($i.command | flat | clip(140))"
            else "    ↳ exit \($i.exit_code // "?" | s)" +
                 (($i.aggregated_output | flat | clip(120)) as $o
                  | if $o == "" then "" else "  \($o)" end)
            end
          elif $k == "agent_message" then
            if $t == "item.completed" then "  ▸ \($i.text | flat | clip(400))" else empty end
          elif $k == "reasoning" then
            if $t == "item.completed" then "  · \(($i.text // $i.summary) | flat | clip(240))" else empty end
          elif $k == "file_change" then
            if $t == "item.completed"
            then "  ✎ " + ([$i.changes[]? | "\(.kind // "edit" | s) \(.path | s)"] | join(", ") | clip(240))
            else empty end
          elif $k == "mcp_tool_call" then
            if $t == "item.started" then "  ⚙ \($i.server // "mcp" | s).\($i.tool // "?" | s)" else empty end
          elif $k == "web_search" then
            if $t == "item.started"
            then (($i.query // $i.action.query // $i.text) | flat | clip(140)) as $q
                 | if $q == "" then "  ⌕ web search" else "  ⌕ \($q)" end
            else empty end
          elif $k == "todo_list" then
            if $t == "item.completed"
            then "  ☑ " + ([$i.items[]? | "[\(if .completed then "x" else " " end)] \(.text | s)"] | join("  ") | clip(240))
            else empty end
          else empty end
        end
    else empty end
  ) catch "  ? unrenderable event"
  end'

# Elapsed-time prefix, so a stalled step is visible as a stalled step.
stamp() {
  local line
  while IFS= read -r line; do
    printf '[%02d:%02d] %s\n' $((SECONDS / 60)) $((SECONDS % 60)) "$line"
  done
}

# Codex stderr goes to a file rather than through a `2> >(grep ...)` process
# substitution. Bash does not wait for those, so a diagnostic written as codex
# exits could be lost, and a second independent writer on stderr could interleave
# mid-line with the trace. Buffered to a file, it is emitted once, in order.
# Wrapper warnings must bypass the Codex stderr buffer, including on successful
# quiet runs where that buffer is deliberately discarded.
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1 &&
   ! command -v setsid >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
  echo "codex-run: no setsid or perl; --timeout cannot reach grandchild processes" >&2
fi
SECONDS=0
if [ "$JSONL" -eq 1 ]; then
  # Order matters: stdout must be duplicated from the caller's stderr BEFORE
  # stderr is redirected to the file, or the JSONL stream lands in the file too.
  run_with_timeout codex "${ARGS[@]}" < /dev/null >&2 2>"$ERRLOG"
  rc=$?
elif [ "$STREAM" -eq 1 ] && command -v jq >/dev/null 2>&1; then
  run_with_timeout codex "${ARGS[@]}" < /dev/null 2>"$ERRLOG" \
    | jq --unbuffered -Rr "$STREAM_FILTER" \
    | stamp >&2
  rc=${PIPESTATUS[0]}
else
  run_with_timeout codex "${ARGS[@]}" < /dev/null > /dev/null 2>"$ERRLOG"
  rc=$?
fi

# In quiet mode codex still writes its whole human-readable transcript to stderr,
# which is exactly the chatter --quiet asks to be rid of. Hold it back unless the
# run failed, where it is the only diagnostic the caller gets.
#
# The noise line codex prints even with stdin closed, which it always is here, is
# matched as a whole line, so a real diagnostic quoting the phrase survives.
if [ -s "$ERRLOG" ] && { [ "$STREAM" -eq 1 ] || [ "$JSONL" -eq 1 ] || [ "$rc" -ne 0 ]; }; then
  # -a: a NUL byte in the transcript would otherwise turn the whole diagnostic
  # into a "binary file matches" notice.
  grep -a -v '^Reading additional input from stdin\.\.\.$' "$ERRLOG" >&2
fi

if [ "$rc" -eq 124 ]; then
  echo "codex-run: TIMEOUT after ${TIMEOUT}s" >&2
  exit 124
fi

# A caller that gets exit 0 is entitled to the answer on stdout. If codex
# succeeded but the result cannot be delivered, that is a wrapper failure and
# has to be reported as one. A prior Codex failure keeps its original status.
if [ -s "$LAST" ]; then
  if ! cat "$LAST"; then
    echo "codex-run: could not write the final message to stdout" >&2
    [ "$rc" -eq 0 ] && rc=3
    exit "$rc"
  fi
  if [ -n "$OUTFILE" ] && ! cp -- "$LAST" "$OUTFILE"; then
    echo "codex-run: could not copy the final message to $OUTFILE" >&2
    [ "$rc" -eq 0 ] && rc=3
    exit "$rc"
  fi
else
  echo "codex-run: codex produced no final message (exit $rc). Re-run with --json to see events." >&2
  [ "$rc" -eq 0 ] && rc=3
fi

exit "$rc"
