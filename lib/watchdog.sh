#!/bin/bash
# watchdog.sh - run a command with a wall-clock timeout, leaving nothing behind.
#
# `timeout(1)` is not installed everywhere (notably a stock macOS), so unattended
# scripts tend to grow a hand-rolled version: launch the job, launch a `sleep`
# that kills it, move on. That version has two bugs that only show up later.
#
#   1. The sleep outlives the job. The job finishes in 20 seconds, the watchdog
#      sleeps for its full 30 minutes, and because it inherited the script's
#      stdout, whatever is reading that pipe waits for it. The symptom is a job
#      that "hangs" long after its work is done.
#   2. Killing the watchdog subshell reparents its sleep to init instead of
#      killing it. Children have to die first, or the orphan survives anyway.
#
# So: redirect the watchdog's output away from the caller's, and reap children
# before the parent, on every exit path.
#
# Usage:
#   . lib/watchdog.sh
#   run_with_timeout 300 ./slow-thing.sh --flag
#   echo "exit was $?"
#
# Exit status: the command's own status, or 124 if the timeout fired (matching
# GNU timeout's convention, so callers can tell "failed" from "took too long").

run_with_timeout() {
  _wd_timeout="$1"; shift
  [ -n "${1:-}" ] || { echo "run_with_timeout: no command given" >&2; return 2; }

  "$@" &
  _wd_pid=$!

  # Redirected so the watchdog never holds the caller's stdout open.
  ( sleep "$_wd_timeout"; kill -0 "$_wd_pid" 2>/dev/null && kill -TERM "$_wd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  _wd_dog=$!

  wait "$_wd_pid" 2>/dev/null
  _wd_rc=$?

  # If the job outlived the watchdog's patience, the kill above is why it
  # stopped. Report 124 rather than the signal status, so the caller can tell a
  # timeout apart from a genuine failure.
  if ! kill -0 "$_wd_dog" 2>/dev/null; then
    _wd_rc=124
  fi

  watchdog_stop "$_wd_dog"
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
