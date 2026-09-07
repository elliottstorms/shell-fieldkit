#!/bin/bash
# lockfile.sh - single-instance locks for unattended jobs, with honest staleness.
#
# The problem this solves is not "two jobs ran at once." It is the three ways a
# naive lock file quietly breaks a scheduled job, each of which was found in
# production rather than in theory:
#
#   1. A crashed run leaves its lock behind, and every future run exits cleanly
#      believing a sibling is live. The job reports success forever while doing
#      nothing.
#   2. A wrapper and the worker it launches share one lock path, so the worker
#      finds the wrapper's own lock and immediately self-aborts. Same silent
#      no-op, harder to see, because the lock is real and current.
#   3. The lock is cleared on a timer alone, so a slow-but-healthy run gets its
#      lock yanked mid-write by the next fire.
#   4. The holder crashes and its PID is later handed to an unrelated process, so
#      a bare `kill -0 <pid>` still succeeds and the lock reads live forever. A
#      PID is not an identity: it is a small integer the kernel recycles, and on
#      a busy machine it recycles fast. This is failure 1 wearing a disguise, and
#      a liveness check that trusts the PID alone cannot see it.
#
# The rule that avoids all four: a lock is stale only when its holder is provably
# gone, and "the same PID is alive" is not that proof unless it is the same
# PROCESS. So the lock records the holder's start time next to its PID, and a
# live PID whose start time no longer matches is treated as gone. Age is a
# tiebreaker, never the test. And a wrapper gets its own lock path, never the
# worker's.
#
# Usage:
#   . lib/lockfile.sh
#   lock_acquire /tmp/myjob.lock || exit 0     # already held by a live process
#   trap 'lock_release /tmp/myjob.lock' EXIT
#
# Exit status of lock_acquire: 0 acquired, 1 held by a live process.

# _lock_proc_start <pid>
# Prints the start time of a running PID, or nothing if it cannot be read.
# `ps -o lstart=` gives a whole-date string ("Mon Sep  7 09:00:00 2026") on both
# GNU (procps) and BSD (macOS) ps, which is the only pair that has to agree; the
# value is never compared across machines, only against itself. Whitespace is
# squeezed so the stored and re-read forms match exactly.
_lock_proc_start() {
  ps -p "$1" -o lstart= 2>/dev/null | tr -s ' ' ' ' | sed 's/^ //;s/ $//'
}

# _lock_same_process <pid> <recorded_start>
# True when the live PID is the SAME process that wrote the lock, not merely some
# process that inherited a recycled PID. If no start time was recorded (a legacy
# lock, or one written by hand holding just a PID) there is nothing to compare
# against, so fall back to the old rule and trust the PID. If the start time
# cannot be read at all, do NOT reap: an unreadable time is not proof of anything,
# and stealing a live lock is the worse failure.
_lock_same_process() {
  _ls_recorded="$2"
  [ -z "$_ls_recorded" ] && return 0            # legacy PID-only lock
  _ls_now="$(_lock_proc_start "$1")"
  [ -z "$_ls_now" ] && return 0                 # cannot read; refuse to steal
  [ "$_ls_now" = "$_ls_recorded" ]
}

# lock_acquire <path> [max_age_minutes]
# Takes the lock, reaping it first if the recorded holder is provably gone.
lock_acquire() {
  lock_path="$1"
  max_age="${2:-120}"

  if [ -f "$lock_path" ]; then
    record="$(cat "$lock_path" 2>/dev/null || echo)"
    holder="${record%% *}"                      # first field is the PID
    holder_start=""
    [ "$record" != "$holder" ] && holder_start="${record#* }"

    # A live holder is authoritative regardless of age, but "live" has to mean
    # the same process: a recycled PID belonging to something unrelated is not
    # the holder, and treating it as one is how a crashed run's lock becomes
    # immortal. A long-running job is still a running job, and stealing its lock
    # is how two publishers end up writing at once, so the start-time check is
    # deliberately conservative: it only reaps on a proven MISMATCH.
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null \
        && _lock_same_process "$holder" "$holder_start"; then
      return 1
    fi

    # No live holder (dead, or the PID was recycled by an unrelated process). If
    # the file is also older than max_age, it is a crash leftover and safe to
    # clear. The age check stays as a second opinion for the window where a PID
    # was written but the process has not started, and for lock files holding
    # something other than a PID.
    if [ -z "$(find "$lock_path" -mmin -"$max_age" 2>/dev/null)" ]; then
      rm -f "$lock_path"
    else
      return 1
    fi
  fi

  mkdir -p "$(dirname "$lock_path")" 2>/dev/null || true
  printf '%s %s\n' "$$" "$(_lock_proc_start "$$")" > "$lock_path"
  return 0
}

# lock_release <path>
# Only removes a lock this process owns, so a reaped-and-retaken lock belonging
# to someone else survives our exit trap.
lock_release() {
  lock_path="$1"
  [ -f "$lock_path" ] || return 0
  owner="$(cat "$lock_path" 2>/dev/null || echo)"
  owner="${owner%% *}"                          # first field is the PID
  if [ "$owner" = "$$" ]; then
    rm -f "$lock_path"
  fi
  return 0
}

# lock_holder <path>
# Prints the recorded holder PID, or nothing. Useful in log lines: knowing which
# PID held a lock is the difference between debugging and guessing. The lock file
# now also stores the holder's start time, so return just the PID field.
lock_holder() {
  [ -f "$1" ] || return 1
  _lh="$(cat "$1" 2>/dev/null)"
  printf '%s\n' "${_lh%% *}"
}
