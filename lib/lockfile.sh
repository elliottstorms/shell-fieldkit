#!/bin/bash
# lockfile.sh - single-instance locks for unattended jobs, with honest staleness.
#
# Two things have to hold. Acquisition is atomic, so two jobs starting from no
# lock in the same instant cannot both take it (a check-then-write cannot promise
# that, and that race is handled in _lock_try_create below). And staleness is
# honest, which is the subtler part and the reason most of this file exists: the
# four ways a naive lock file quietly breaks a scheduled job, each found in
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

# _lock_try_create <path>
# Creates the lock file and writes "<pid> <start>" ONLY if it does not already
# exist, and says whether this process is the one that created it. The create is
# atomic: `set -C` (noclobber) makes the `>` redirection fail, without touching
# the file, when the path is already present, so of two processes racing from no
# lock exactly one redirection succeeds and the other is turned away. A plain
# `[ -f ] || printf > file` cannot promise that: both racers read "absent" in the
# gap before either writes, and both then write and both believe they hold it.
# The subshell keeps noclobber from leaking into the caller's shell, and `$$`
# inside it is still this process's PID, not the subshell's, so the recorded
# holder is correct.
_lock_try_create() {
  ( set -C; printf '%s %s\n' "$$" "$(_lock_proc_start "$$")" > "$1" ) 2>/dev/null
}

# lock_acquire <path> [max_age_minutes]
# Takes the lock, reaping it first if the recorded holder is provably gone.
# Acquisition is atomic: two jobs starting from no lock in the same instant
# cannot both take it, which is the "one instance at a time" the README promises.
lock_acquire() {
  lock_path="$1"
  max_age="${2:-120}"
  mkdir -p "$(dirname "$lock_path")" 2>/dev/null || true

  # Win it outright if no lock is present. This is the common path and the one
  # the old check-then-write got wrong: it is a single atomic step, so a
  # simultaneous cold start by a sibling loses the race here instead of also
  # succeeding.
  if _lock_try_create "$lock_path"; then
    return 0
  fi

  # A lock already exists. Decide whether its holder is provably gone (reap and
  # retake) or live (yield). "Live" has to mean the same PROCESS: a recycled PID
  # belonging to something unrelated is not the holder, and treating it as one is
  # how a crashed run's lock becomes immortal. A long-running job is still a
  # running job, and stealing its lock is how two publishers end up writing at
  # once, so the identity check is deliberately conservative and reaps only on a
  # proven MISMATCH.
  record="$(cat "$lock_path" 2>/dev/null || echo)"
  holder="${record%% *}"                        # first field is the PID
  holder_start=""
  [ "$record" != "$holder" ] && holder_start="${record#* }"

  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    if _lock_same_process "$holder" "$holder_start"; then
      return 1                                  # genuinely the same live process
    fi
    # Alive, but the recorded start time proves this is a DIFFERENT process: the
    # holder crashed and its PID was reused. That is positive proof the holder is
    # gone. Deferring to the age check here was the gap the start-time record was
    # added to close: a FRESH recycled-PID lock (a crash seconds ago, a busy
    # machine handing the PID out fast, the exact case this defends) is younger
    # than max_age, so an age-only branch would read it as held and freeze the
    # lock for up to max_age. Proof of death outranks age. Fall through to reap.
    :
  elif [ -n "$(find "$lock_path" -mmin -"$max_age" 2>/dev/null)" ]; then
    # No live process holds this PID, but the file is still fresh: either a PID
    # written just before its process was established, or a legacy PID-only lock
    # too young to call a crash leftover. Too ambiguous to steal.
    return 1
  fi
  # Reap: the holder is a recycled PID (proven dead), or dead-and-not-reused and
  # older than max_age.

  # Claim the stale file atomically before recreating it. `mv` of a path that
  # exists exactly once succeeds for exactly one racer; a sibling reaping the
  # same lock finds the source already gone and its `mv` fails, so it yields
  # rather than deleting the fresh lock the winner just wrote. Without this, two
  # processes could both `rm` the stale lock and both recreate, reintroducing the
  # double-acquire on the reap path that the cold-start fix closes on the common
  # one.
  _lock_stolen="${lock_path}.stale.$$"
  if mv "$lock_path" "$_lock_stolen" 2>/dev/null; then
    rm -f "$_lock_stolen"
    _lock_try_create "$lock_path" && return 0
  fi
  return 1
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
