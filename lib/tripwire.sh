#!/bin/bash
# tripwire.sh - fail-closed secret scan for anything about to become public.
#
# The premise is that the author of a publish pipeline is one of its threats.
# Not maliciously: you generate a tree, you sanitize it, you trust the sanitizer,
# and one day the sanitizer misses. A tripwire that runs after the build and
# refuses to publish on any hit is the cheap insurance, and it has to be
# fail-closed. An advisory warning in a log nobody reads is not a control.
#
# Two design choices worth stating, because both are load-bearing:
#
#   1. It scans the FINISHED tree, not the source. Sanitizing is a transform and
#      transforms have bugs; the only thing worth checking is the artifact that
#      is actually about to leave the machine.
#   2. It uses no word boundaries. `grep -E` with \b is not portable between GNU
#      and BSD, and a scanner that silently matches nothing on the maintainer's
#      laptop is worse than no scanner.
#
# Usage:
#   . lib/tripwire.sh
#   tripwire_scan ./build || exit 2          # default credential patterns
#   DENY='internal\.example\.com|staging-key' tripwire_scan ./build || exit 2
#
# Exit status: 0 clean, 2 findings (matching the convention that 1 means the
# tool itself failed, so a broken scanner is never mistaken for a clean tree).

# Credential shapes, not credential values. Extend via $DENY rather than editing
# here, so an updated fieldkit does not stomp your local additions.
TRIPWIRE_PATTERNS='client_secret|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}|api[_-]?key["'"'"']?[[:space:]]*[:=]'

# tripwire_scan <tree> [extra_pattern]
tripwire_scan() {
  _tw_tree="${1:?tripwire_scan: no tree given}"
  _tw_extra="${2:-${DENY:-}}"

  [ -d "$_tw_tree" ] || { echo "tripwire: not a directory: $_tw_tree" >&2; return 1; }

  _tw_pat="$TRIPWIRE_PATTERNS"
  [ -n "$_tw_extra" ] && _tw_pat="$_tw_pat|$_tw_extra"

  _tw_hits="$(grep -rInE "$_tw_pat" "$_tw_tree" --exclude-dir=.git 2>/dev/null || true)"

  if [ -n "$_tw_hits" ]; then
    echo "TRIPWIRE FIRED - not publishing. Findings:" >&2
    echo "$_tw_hits" | head -40 >&2
    return 2
  fi

  echo "tripwire: clean ($(find "$_tw_tree" -type f ! -path '*/.git/*' | wc -l | tr -d ' ') files)"
  return 0
}

# tripwire_allow_line <tree> <literal> <other_patterns>
# The exception that does not become a hole. Sometimes one exact string is
# legitimately public (an author byline, a sample key from a vendor's own docs).
# Allowing it wholesale would also allow a real leak that happens to share the
# line, so: permit the literal, then re-check that its lines carry nothing else
# denied. Paths are matched relative to the tree, because scanning with absolute
# paths makes every result contain the home directory and match your own
# username pattern. That false positive is not hypothetical.
tripwire_allow_line() {
  _tw_tree="${1:?}"; _tw_literal="${2:?}"; _tw_others="${3:?}"
  _tw_mix="$(cd "$_tw_tree" && grep -rInF "$_tw_literal" . --exclude-dir=.git 2>/dev/null \
    | grep -iE "$_tw_others" || true)"
  if [ -n "$_tw_mix" ]; then
    echo "TRIPWIRE FIRED - allowed literal shares a line with denied content:" >&2
    echo "$_tw_mix" | head -10 >&2
    return 2
  fi
  return 0
}
