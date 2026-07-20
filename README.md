# shell-fieldkit

Five small shell libraries for jobs that run when nobody is watching: locking,
timeouts, preflight checks, a fail-closed secret scan, and a status stream that
something else can read.

None of this is clever. All of it is the second version, written after the first
version failed quietly in production. The comments explain what broke, because
the failure is usually more useful than the fix.

## The failure mode this is about

An unattended job does not fail loudly. It fails at 7am on a Tuesday, reports
success, and keeps doing that until someone happens to look. Every library here
exists because of one of those:

| File | The bug it is the fix for |
|---|---|
| `lib/lockfile.sh` | A crashed run left its lock behind, so every later run exited "cleanly" believing a sibling was live. Weeks of successful-looking no-ops. |
| `lib/watchdog.sh` | The timeout `sleep` outlived the job it was guarding and held the caller's stdout open, so a finished job looked like a hung one. |
| `lib/preflight.sh` | A scheduled job spent its whole run discovering it had been logged out, then reported a failure that did not say how to fix it. |
| `lib/tripwire.sh` | A publish pipeline sanitized its output and trusted the sanitizer. The check has to run on the finished artifact, and it has to be able to refuse. |
| `lib/report.sh` | A broken job went unnoticed for four days, then, once fixed, kept being reported as broken because nothing marked it resolved. |

## Use it

Copy the files you want into your project. They are POSIX-ish shell with no
dependencies, they source cleanly into `bash` or `sh`, and each one is
independently useful.

```bash
. lib/lockfile.sh
. lib/watchdog.sh
. lib/preflight.sh
. lib/tripwire.sh
. lib/report.sh

# Refuse to start if the world is not how we assumed.
need_cmd git "install git"
need_cmd gh  "brew install gh"
need_ok  "gh auth status" "gh not authenticated: run gh auth login"
preflight_done || exit 1

# One instance at a time. A lock is stale only when its holder is provably gone.
lock_acquire /tmp/publish.lock || { echo "already running"; exit 0; }
trap 'lock_release /tmp/publish.lock' EXIT

# Bounded work, no orphan processes left behind.
run_with_timeout 600 ./build.sh
[ $? -eq 124 ] && { report_failure code "publish: build timed out"; exit 1; }

# Nothing leaves the machine until the finished tree is clean.
tripwire_scan ./out || exit 2

./push.sh && report_ok code publish "site shipped" "$(git rev-parse --short HEAD)"
```

## Notes worth the paragraph

**A lock is stale only when its holder is dead.** Age is a tiebreaker, never the
test. Clearing a lock on a timer alone means a slow but healthy run gets its lock
taken by the next fire, which is a worse bug than the one you were fixing.

**A wrapper and the worker it launches must not share a lock path.** If they do,
the worker finds the wrapper's own lock, decides a sibling is live, and exits
successfully having done nothing. This one is genuinely hard to see, because the
lock file is real and current and points at a running process.

**Kill children before parents.** Killing a watchdog subshell first reparents its
`sleep` to init, after which `pkill -P` finds no children and the orphan survives
for the full timeout.

**Exit codes are the interface.** `0` clean, `2` findings, `124` timed out, `1`
the tool itself failed. Keeping "found a problem" distinct from "I broke" is what
lets a caller trust the answer.

**A failure event is only current until something says otherwise.** Without
that, a fixed problem is reported as today's emergency forever, and people learn
to ignore the alarm. `report_open_failures` implements it: a failure row is open
only if it is recent and no later row about the same job disagrees.

**Portability is not theoretical.** `mktime` and `strftime` are gawk extensions.
On a stock macOS awk they abort the script, and in a monitoring function that
means it silently reports all-clear. `report.sh` does its date arithmetic with
Julian day numbers for that reason, and CI runs the suite on both awks.

## Tests

```bash
bash test/run.sh
```

26 assertions, no framework, one exit code. They cover the bug-shaped claims
specifically: that a lock held by a live process is refused and one held by a
dead process is reaped, that no orphan `sleep` survives a fast command, that the
tripwire fires on a planted credential, and that a resolved failure stops being
reported. If you delete a test, delete the claim it defends from this README in
the same commit.

## License

MIT. See [LICENSE](LICENSE).
