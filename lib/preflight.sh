#!/bin/bash
# preflight.sh - check the assumptions before spending the run on them.
#
# An unattended job that fails halfway costs more than one that refuses to
# start, because the half-done state is now yours to reason about at 7am. The
# useful discipline is to prove every external dependency FIRST: the binary
# exists, the auth is live, the API answers, the path is writable. All of it is
# cheap, none of it is interesting, and skipping it is how a scheduled job
# spends thirty minutes discovering it was logged out.
#
# The second rule is that a failure message is a user interface. "Job failed" is
# a notification. "gh not authenticated: run gh auth login" is a fix. Every
# check here takes the remedy as an argument, because the moment you know what
# broke is the only moment you cheaply know what fixes it.
#
# Usage:
#   . lib/preflight.sh
#   need_cmd git   "install git"
#   need_cmd gh    "brew install gh"
#   need_ok  "gh auth status"  "gh not authenticated: run gh auth login"
#   need_writable "$HOME/out"  "create the output directory"
#   preflight_done || exit 1
#
# Every failed check prints and is remembered; preflight_done returns nonzero if
# any failed, so the caller gets the FULL list in one pass instead of fixing one
# thing per run.

PREFLIGHT_FAILURES=0

_pf_fail() {
  echo "preflight: $1" >&2
  [ -n "${2:-}" ] && echo "          fix: $2" >&2
  PREFLIGHT_FAILURES=$((PREFLIGHT_FAILURES + 1))
  return 1
}

# need_cmd <command> [remedy]
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || _pf_fail "missing command: $1" "${2:-}"
}

# need_ok <command line> [remedy]
# Runs the command, discards its output, checks only the exit status. For the
# checks whose answer is "does this still work" rather than "does this exist".
need_ok() {
  # shellcheck disable=SC2086
  sh -c "$1" >/dev/null 2>&1 || _pf_fail "check failed: $1" "${2:-}"
}

# need_file <path> [remedy]
need_file() {
  [ -f "$1" ] || _pf_fail "missing file: $1" "${2:-}"
}

# need_writable <dir> [remedy]
# Actually writes, rather than testing the permission bits. A directory can look
# writable and sit on a full or read-only volume, and the difference matters at
# exactly the wrong moment.
need_writable() {
  _pf_probe="$1/.preflight.$$"
  if ! (mkdir -p "$1" 2>/dev/null && touch "$_pf_probe" 2>/dev/null); then
    _pf_fail "not writable: $1" "${2:-}"
    return 1
  fi
  rm -f "$_pf_probe"
  return 0
}

# preflight_done
# Returns 0 if every check passed. Callers should exit nonzero on failure rather
# than continuing with a warning, which is the whole point.
preflight_done() {
  if [ "$PREFLIGHT_FAILURES" -gt 0 ]; then
    echo "preflight: $PREFLIGHT_FAILURES check(s) failed; refusing to start" >&2
    return 1
  fi
  echo "preflight: ok"
  return 0
}
