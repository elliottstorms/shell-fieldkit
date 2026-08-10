#!/bin/bash
# watchdog.sh - run a command with a wall-clock timeout, leaving nothing behind.
#
# `timeout(1)` is not installed everywhere (notably a stock macOS), so unattended
# scripts tend to grow a hand-rolled version: launch the job, launch a `sleep`
# that kills it, move on. That version has three bugs that only show up later.
#
#   1. The sleep outlives the job. The job finishes in 20 seconds, the watchdog
#      sleeps for its full 30 minutes, and because it inherited the script's
#      stdout, whatever is reading that pipe waits for it. The symptom is a job
#      that "hangs" long after its work is done.
#   2. Killing the watchdog subshell reparents its sleep to init instead of
#      killing it. Children have to die first, or the orphan survives anyway.
#   3. The watchdog sends TERM and trusts it. A job with a cleanup trap on TERM,
#      or one that catches it for a graceful shutdown and then wedges, ignores
#      the signal and keeps running. The timeout that was meant to bound the run
#      does not, and the hung job it was guarding against comes back wearing a
#      signal handler. TERM is a request; only KILL is a guarantee.
#
# So: redirect the watchdog's output away from the caller's, reap children
# before the parent on every exit path, and escalate TERM to KILL after a short
# grace period so a job cannot decline to stop.
#
# Usage:
#   . lib/watchdog.sh
#   run_with_timeout 300 ./slow-thing.sh --flag
#   echo "exit was $?"
#
#   # A job that legitimately needs longer to flush on TERM can widen the grace:
#   WATCHDOG_KILL_AFTER=30 run_with_timeout 300 ./drains-slowly.sh
#
# Exit status: the command's own status, or 124 if the timeout fired (matching
# GNU timeout's convention, so callers can tell "failed" from "took too long").

# Seconds to wait after TERM before escalating to KILL. A grace period, not a
# negotiation: it is how long a well-behaved job gets to clean up, after which
# it stops whether it agreed to or not.
WATCHDOG_KILL_AFTER="${WATCHDOG_KILL_AFTER:-5}"

run_with_timeout() {
  _wd_timeout="$1"; shift
  [ -n "${1:-}" ] || { echo "run_with_timeout: no command given" >&2; return 2; }
  _wd_grace="${WATCHDOG_KILL_AFTER:-5}"

  # The dog records that it fired by creating this flag, immediately before it
  # sends TERM. Detecting a timeout by "has the dog exited yet" no longer works
  # now that the dog outlives its TERM by the grace period: when a well-behaved
  # job dies on TERM, the dog is still alive counting down to KILL, and the
  # caller would misread that as the job's own exit. The flag is unambiguous.
  _wd_flag="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/watchdog.$$.flag")"
  rm -f "$_wd_flag"

  "$@" &
  _wd_pid=$!

  # Redirected so the watchdog never holds the caller's stdout open.
  ( sleep "$_wd_timeout"
    kill -0 "$_wd_pid" 2>/dev/null || exit 0    # job already finished on its own
    : > "$_wd_flag"                             # record that the timeout fired
    kill -TERM "$_wd_pid" 2>/dev/null
    sleep "$_wd_grace"
    kill -0 "$_wd_pid" 2>/dev/null && kill -KILL "$_wd_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  _wd_dog=$!

  wait "$_wd_pid" 2>/dev/null
  _wd_rc=$?

  # If the dog left its flag, the job stopped because the timeout fired, whether
  # it took the TERM or had to be KILLed. Report 124 rather than the signal
  # status, so the caller can tell a timeout apart from a genuine failure.
  if [ -f "$_wd_flag" ]; then
    _wd_rc=124
  fi

  watchdog_stop "$_wd_dog"
  rm -f "$_wd_flag"
  return "$_wd_rc"
}

# watchdog_stop <pid>
# Children first: killing the subshell first reparents its sleep, after which
# -P finds no children and the sleep survives to haunt the process table.
watchdog_stop() {
  _wd_target="${1:-}"
  [ -n "$_wd_target" ] || return 0
  pkill -P "$_wd_target" 2>/dev/null || true
  kill "$_wd_target" 2>/dev/null || true
  wait "$_wd_target" 2>/dev/null || true   # absorbs the "Terminated" notice
  return 0
}
