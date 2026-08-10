#!/bin/bash
# run.sh - the whole test suite. No framework, no dependencies, one exit code.
#
# Every claim the READMEs make is asserted here, including the bug-shaped ones:
# a lock held by a dead process is reaped, a lock held by a live one is not, a
# watchdog leaves no orphan sleep, a tripwire fires on a planted secret, and a
# resolved failure stops being reported. If a test here is deleted, the claim it
# defends should be deleted from the docs in the same commit.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { echo "  ok   $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL $1" >&2; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

. "$ROOT/lib/lockfile.sh"
. "$ROOT/lib/watchdog.sh"
. "$ROOT/lib/tripwire.sh"
. "$ROOT/lib/preflight.sh"
. "$ROOT/lib/report.sh"

echo "== lockfile =="
L="$TMP/a.lock"
lock_acquire "$L"; check "acquires a free lock" "$?" "0"
check "records our pid" "$(lock_holder "$L")" "$$"

# A lock whose holder is alive must be refused, no matter how old it looks.
echo 1 > "$L"                       # pid 1 is always running
lock_acquire "$L"; check "refuses a lock held by a live process" "$?" "1"

# A lock whose holder is gone is a crash leftover, and must be reaped. 99999 is
# chosen to be above the default pid_max on the platforms this targets.
echo 99999 > "$L"
touch -t 200001010000 "$L"          # and old enough to clear the age check
lock_acquire "$L"; check "reaps a lock whose holder is dead" "$?" "0"

# Release only removes OUR lock, so a lock retaken by another process survives.
echo 4242 > "$L"
lock_release "$L"
check "release leaves another process's lock alone" "$([ -f "$L" ] && echo present)" "present"
echo $$ > "$L"; lock_release "$L"
check "release removes our own lock" "$([ -f "$L" ] || echo gone)" "gone"

echo "== watchdog =="
run_with_timeout 5 true;  check "passes through a success exit" "$?" "0"
run_with_timeout 5 false; check "passes through a failure exit" "$?" "1"

# Count matching processes portably. `pgrep -c` is not usable here: on Linux it
# prints "0" AND exits nonzero when nothing matches, so the usual `|| echo 0`
# fallback appends a second zero and the comparison sees "0\n0". BSD pgrep does
# not, so this passes locally on macOS and fails only in CI. Counting lines
# ourselves behaves the same everywhere.
procs() { pgrep -f "$1" 2>/dev/null | wc -l | tr -d ' '; }

before="$(procs 'sleep 9')"
run_with_timeout 1 sleep 9
check "reports 124 when the timeout fires" "$?" "124"
sleep 1
check "kills the timed-out command" "$(procs 'sleep 9')" "$before"

# The orphan bug: after a FAST command, the watchdog's own sleep must be gone
# too, not left running for the full timeout holding stdout open.
run_with_timeout 30 true
sleep 1
check "leaves no orphan watchdog sleep" "$(procs 'sleep 30')" "0"

# The escalation: a command that ignores TERM must still be stopped, by a KILL
# after the grace period. A fifo with no writer blocks the process in-place, in
# ONE process, so there is no child to muddy the check; `trap "" TERM` makes it
# decline the polite signal. Without escalation this returns the job's own exit
# and leaves it running; with it, 124 and gone.
FIFO="$TMP/wd.fifo"
mkfifo "$FIFO"
WATCHDOG_KILL_AFTER=1 run_with_timeout 1 bash -c 'trap "" TERM; read _ < '"$FIFO"
check "reports 124 for a command that ignores SIGTERM" "$?" "124"
sleep 1
check "escalates to SIGKILL when TERM is ignored" "$(procs "read _ < $FIFO")" "0"

echo "== tripwire =="
mkdir -p "$TMP/tree/nested"
echo "just some ordinary config" > "$TMP/tree/clean.txt"
tripwire_scan "$TMP/tree" >/dev/null; check "passes a clean tree" "$?" "0"

printf 'aws_key = AKIA%s\n' "0123456789ABCDEF" > "$TMP/tree/nested/leak.txt"
tripwire_scan "$TMP/tree" >/dev/null 2>&1; check "fires on a planted credential" "$?" "2"
rm -f "$TMP/tree/nested/leak.txt"

echo 'internal.example.com' > "$TMP/tree/extra.txt"
tripwire_scan "$TMP/tree" 'internal\.example\.com' >/dev/null 2>&1
check "fires on a caller-supplied pattern" "$?" "2"
rm -f "$TMP/tree/extra.txt"

# The byline exception: the literal alone is fine, the literal sharing a line
# with denied content is not.
echo 'Copyright (c) Example Author' > "$TMP/tree/LICENSE"
tripwire_allow_line "$TMP/tree" "Example Author" 'secret|internal'
check "allows a clean byline line" "$?" "0"
echo 'Example Author <internal>' > "$TMP/tree/BAD"
tripwire_allow_line "$TMP/tree" "Example Author" 'secret|internal' >/dev/null 2>&1
check "rejects a byline line carrying denied content" "$?" "2"
rm -f "$TMP/tree/BAD"

echo "== preflight =="
PREFLIGHT_FAILURES=0
need_cmd sh "install a shell"
preflight_done >/dev/null; check "passes when dependencies exist" "$?" "0"

PREFLIGHT_FAILURES=0
need_cmd definitely-not-a-real-binary "install the thing" 2>/dev/null
preflight_done >/dev/null 2>&1; check "fails on a missing command" "$?" "1"

PREFLIGHT_FAILURES=0
need_ok "false" "make it true" 2>/dev/null
need_cmd another-fake-binary "install it" 2>/dev/null
check "collects every failure, not just the first" "$PREFLIGHT_FAILURES" "2"

PREFLIGHT_FAILURES=0
need_writable "$TMP/newdir" "check the volume"
preflight_done >/dev/null; check "creates and verifies a writable dir" "$?" "0"

echo "== report =="
REPORT_FILE="$TMP/STATUS.md"
report_event code note "widget: started" "" no
report_ok code backup "widget: mirrored" "abc1234"
check "appends one line per event" "$(wc -l < "$REPORT_FILE" | tr -d ' ')" "2"
check "marks verified rows" "$(tail -1 "$REPORT_FILE" | awk -F'|' '{gsub(/ /,"",$6); print $6}')" "yes"

: > "$REPORT_FILE"
report_event code job-failure "drip: upload failed" "" no
check "reports an open failure" "$(report_open_failures | wc -l | tr -d ' ')" "1"

report_event code note "drip: reauthorized" "" yes
check "stops reporting a resolved failure" "$(report_open_failures | wc -l | tr -d ' ')" "0"

: > "$REPORT_FILE"
report_event code job-failure "alpha: broke" "" no
report_event code note "beta: unrelated" "" yes
check "an unrelated later event does not resolve it" "$(report_open_failures | wc -l | tr -d ' ')" "1"

: > "$REPORT_FILE"
printf '2000-01-01 09:00 | code | job-failure | ancient: broke |  | no\n' > "$REPORT_FILE"
check "ages out an old failure" "$(report_open_failures 3 | wc -l | tr -d ' ')" "0"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL PASS"
