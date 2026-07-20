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
#
# The rule that avoids all three: a lock is stale only when its holder is
# provably gone. Age is a tiebreaker, never the test. And a wrapper gets its own
# lock path, never the worker's.
#
# Usage:
#   . lib/lockfile.sh
#   lock_acquire /tmp/myjob.lock || exit 0     # already held by a live process
#   trap 'lock_release /tmp/myjob.lock' EXIT
#
# Exit status of lock_acquire: 0 acquired, 1 held by a live process.

# lock_acquire <path> [max_age_minutes]
# Takes the lock, reaping it first if the recorded holder is dead.
lock_acquire() {
  lock_path="$1"
  max_age="${2:-120}"

  if [ -f "$lock_path" ]; then
    holder="$(cat "$lock_path" 2>/dev/null || echo)"

    # A live holder is authoritative regardless of age. A long-running job is
    # still a running job, and stealing its lock is how two publishers end up
    # writing at once.
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      return 1
    fi

    # No live holder. If the file is also older than max_age, it is a crash
    # leftover and safe to clear. The age check stays as a second opinion for
    # the window where a PID was written but the process has not started, and
    # for lock files holding something other than a PID.
    if [ -z "$(find "$lock_path" -mmin -"$max_age" 2>/dev/null)" ]; then
      rm -f "$lock_path"
    else
      return 1
    fi
  fi

  mkdir -p "$(dirname "$lock_path")" 2>/dev/null || true
  echo $$ > "$lock_path"
  return 0
}

# lock_release <path>
# Only removes a lock this process owns, so a reaped-and-retaken lock belonging
# to someone else survives our exit trap.
lock_release() {
  lock_path="$1"
  [ -f "$lock_path" ] || return 0
  owner="$(cat "$lock_path" 2>/dev/null || echo)"
  if [ "$owner" = "$$" ]; then
    rm -f "$lock_path"
  fi
  return 0
}

# lock_holder <path>
# Prints the recorded holder PID, or nothing. Useful in log lines: knowing which
# PID held a lock is the difference between debugging and guessing.
lock_holder() {
  [ -f "$1" ] || return 1
  cat "$1" 2>/dev/null
}
