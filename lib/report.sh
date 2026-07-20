#!/bin/bash
# report.sh - make an unattended job report its own outcome, in a format a
# machine can close the loop on.
#
# The failure this prevents is specific and expensive: a scheduled job breaks,
# nothing is watching, and it keeps breaking daily for four days before a human
# notices. Logs do not solve it, because nobody reads a log that is usually
# fine. What works is a single append-only event stream that some other routine
# (a morning brief, a dashboard, a sync) reads and reacts to.
#
# The format is one line per event, pipe-delimited, newest last:
#
#   2026-07-20 09:00 | code | job-failure | drip: upload failed | | no
#   2026-07-20 09:42 | code | note        | drip: reauthorized  | | yes
#    timestamp       source  type          summary               ref verified
#
# Two properties make it work. It is append-only, so concurrent writers cannot
# corrupt each other's rows. And "verified" is a field, so the difference
# between "the tool returned success" and "I checked the artifact exists" is
# recorded rather than assumed.
#
# One rule for consumers, learned the hard way: a failure event is only current
# until a later event about the same job says otherwise. Without that, a fixed
# problem keeps being reported as today's emergency, and the alarm becomes
# something people learn to ignore.
#
# Usage:
#   . lib/report.sh
#   REPORT_FILE="$HOME/STATUS.md"
#   report_event code job-failure "backup: push rejected" "" no
#   report_ok    code backup      "mirror pushed" "$(git rev-parse --short HEAD)"

REPORT_FILE="${REPORT_FILE:-$HOME/STATUS.md}"

# report_event <source> <type> <summary> [ref] [verified]
report_event() {
  _rp_ts="$(date '+%Y-%m-%d %H:%M')"
  mkdir -p "$(dirname "$REPORT_FILE")" 2>/dev/null || true
  printf '%s | %s | %s | %s | %s | %s\n' \
    "$_rp_ts" "${1:-code}" "${2:-note}" "${3:-}" "${4:-}" "${5:-no}" >> "$REPORT_FILE"
}

# report_ok <source> <type> <summary> [ref]
# For outcomes you actually verified. If you did not check the artifact, use
# report_event with verified=no and be honest about it; a "yes" you did not earn
# is worse than a "no", because it is the row someone else will trust.
report_ok() {
  report_event "${1:-code}" "${2:-note}" "${3:-}" "${4:-}" yes
}

# report_failure <source> <summary> [ref]
# Also fires a desktop notification where one is available. A job that fails
# unattended should be loud once, not silent forever.
report_failure() {
  report_event "${1:-code}" job-failure "${2:-}" "${3:-}" no
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${2:-job failed}\" with title \"job FAILED\"" 2>/dev/null || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "job FAILED" "${2:-job failed}" 2>/dev/null || true
  fi
}

# report_open_failures [days]
# Prints failure rows that are still current: recent enough to matter, and with
# no later row about the same job. Job identity is the summary's prefix before
# the first colon, which is why the "job: detail" convention above is worth
# keeping. Prints nothing when all is well, so it composes with `if [ -z ... ]`.
report_open_failures() {
  _rp_days="${1:-3}"
  [ -f "$REPORT_FILE" ] || return 0
  awk -F'|' -v days="$_rp_days" -v today="$(date '+%Y-%m-%d')" '
    # Julian day number, by arithmetic only. mktime() and strftime() are gawk
    # extensions: on a BSD awk (every stock macOS) they abort the script, and
    # because this function is only reached for failure rows, the breakage
    # shows up as "no open failures" rather than as an error anyone notices.
    # A monitor that silently reports all-clear is worse than no monitor.
    function jdn(iso,   p, y, m, d, a, yy, mm) {
      split(iso, p, "-"); y = p[1] + 0; m = p[2] + 0; d = p[3] + 0
      a = int((14 - m) / 12); yy = y + 4800 - a; mm = m + 12 * a - 3
      return d + int((153 * mm + 2) / 5) + 365 * yy \
             + int(yy / 4) - int(yy / 100) + int(yy / 400) - 32045
    }
    function days_between(a, b) { return jdn(b) - jdn(a) }
    /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} \|/ {
      date = substr($1, 1, 10)
      type = $3; gsub(/^[ \t]+|[ \t]+$/, "", type)
      summary = $4; gsub(/^[ \t]+|[ \t]+$/, "", summary)
      split(summary, s, ":"); job = s[1]
      n++
      d[n] = date; t[n] = type; sm[n] = summary; jb[n] = job
    }
    END {
      for (i = 1; i <= n; i++) {
        if (t[i] != "job-failure") continue
        if (days_between(d[i], today) > days) continue
        resolved = 0
        for (j = i + 1; j <= n; j++)
          if (jb[j] == jb[i] && t[j] != "job-failure") { resolved = 1; break }
        if (!resolved) print d[i] " " sm[i]
      }
    }
  ' "$REPORT_FILE"
}
