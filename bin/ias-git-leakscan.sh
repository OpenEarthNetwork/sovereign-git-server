#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright 2026 VakeWorks AB
#
# ias-git-leakscan.sh -- a generic, ADOPTER-CONFIGURED confidentiality leak-gate.
#
# WHAT IT IS: before you publish (or declassify) a repo, scan the tree for YOUR OWN
# confidential strings -- company-internal hostnames, client names, employee names,
# internal codenames, API endpoints, credential markers, etc. -- so none slip into a
# public release. It ships with EMPTY term lists on purpose: YOU populate them. There
# are NO built-in secrets or org-specific terms in this tool.
#
# HOW IT WORKS:
#   - You provide a DENY file: one confidential term per line (see examples/).
#   - Any text line under <path> that contains a deny term is a LEAK -> the scan FAILS.
#   - PRIMARY review mechanism -- an ALLOWED-LINES file: exact, human-vetted FULL lines. A deny
#     match on a line whose content EQUALS a vetted line passes SILENTLY (reviewed once, remembered).
#     Whole-line matching cannot be fooled by a broad allow substring overlapping a DIFFERENT
#     confidential substring on the same line -- it circumvents substring logic entirely. A vetted
#     line exempts ONLY that exact line; a different line carrying the same term is still a leak.
#   - You may also provide an ALLOW file of attribution TERMS (a demoted convenience): an allow term
#     flags a deny match for REVIEW ONLY when the allow term SUBSUMES it -- i.e. CONTAINS the deny
#     term as a substring (so allow "Copyright 2026 Your Org" covers deny "Your Org", but allow
#     "github.com/your-org" does NOT cover a co-located "your-org-private/secret"). Such a match is
#     NEVER silently dropped: it is surfaced as an INFERRED-ATTRIBUTION item for review.
#   - A scan whose only findings are attribution items BLOCKS (exit 3) until reviewed: interactively
#     (y = keep + append to allowed-LINES; n = LEAK abort) or headless via --ack-review.
#   - Matching is case-INSENSITIVE FIXED-STRING substring (grep -iIF); binary files are skipped.
#
# USAGE:
#   ias-git-leakscan.sh <path> [--deny-file F] [--allow-file F] [--allow-lines-file F] [--ack-review] [--quiet]
#
#   <path>              file or directory to scan (a repo, or a declassify staging tree).
#   --deny-file F       terms to flag (default: .leakscan-deny.txt next to <path> or in CWD).
#   --allow-file F      attribution TERMS, exempt-by-subsumption -> review (default: .leakscan-allow.txt).
#   --allow-lines-file F  vetted whole LINES, silent-pass (default: .leakscan-allow-lines.txt). PRIMARY.
#   --ack-review        proceed despite inferred-attribution items (you have reviewed them).
#
# EXIT: 0 = clean (or attribution acked); 1 = hard leak; 2 = usage/config error; 3 = attribution review needed.
#
# GET STARTED (copy the commented templates, then edit in YOUR terms):
#   cp examples/leakscan-deny.example.txt  .leakscan-deny.txt
#   cp examples/leakscan-allow.example.txt .leakscan-allow.txt
#   $EDITOR .leakscan-deny.txt          # add your confidential strings
#   ias-git-leakscan.sh ./my-repo
set -uo pipefail

SELF="$(basename "$0")"
QUIET=0
SCAN_PATH=""
DENY_FILE=""
ALLOW_FILE=""
ALLOW_LINES_FILE=""
ACK_REVIEW="${LEAKSCAN_ACK_REVIEW:-0}"   # ack that inferred-attribution items were manually reviewed

die() { echo "$SELF: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --deny-file)        DENY_FILE="${2:?--deny-file needs a path}"; shift 2 ;;
    --allow-file)       ALLOW_FILE="${2:?--allow-file needs a path}"; shift 2 ;;
    --allow-lines-file) ALLOW_LINES_FILE="${2:?--allow-lines-file needs a path}"; shift 2 ;;
    --ack-review) ACK_REVIEW=1; shift ;;
    --quiet)      QUIET=1; shift ;;
    -h|--help)    sed -n '8,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown option: $1" ;;
    *)            [ -z "$SCAN_PATH" ] && SCAN_PATH="$1" || die "unexpected arg: $1"; shift ;;
  esac
done

[ -n "$SCAN_PATH" ] || die "usage: $SELF <path> [--deny-file F] [--allow-file F]"
[ -e "$SCAN_PATH" ] || die "no such path: $SCAN_PATH"

# Default term-file discovery: next to the scan target, else CWD.
default_near() {
  local name="$1" base
  if [ -d "$SCAN_PATH" ]; then base="$SCAN_PATH"; else base="$(dirname "$SCAN_PATH")"; fi
  if [ -f "$base/$name" ]; then echo "$base/$name"; elif [ -f "./$name" ]; then echo "./$name"; fi
}
[ -n "$DENY_FILE" ]  || DENY_FILE="$(default_near .leakscan-deny.txt)"
[ -n "$ALLOW_FILE" ] || ALLOW_FILE="$(default_near .leakscan-allow.txt)"

# Read a term file: strip # comments + blank lines. (No terms -> empty.)
read_terms() {
  local f="$1"
  [ -n "$f" ] && [ -f "$f" ] || return 0
  sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' "$f" | grep -v '^[[:space:]]*$' || true
}

DENY_TERMS="$(read_terms "$DENY_FILE")"
ALLOW_TERMS="$(read_terms "$ALLOW_FILE")"

# --- allowed-LINES (PRIMARY review mechanism; red-team 2026-07-22) --------------------------------
# An allowed-LINES file lists EXACT, human-vetted FULL lines. A deny match on a line whose content
# equals a vetted line passes SILENTLY (reviewed once, remembered). Whole-line matching CANNOT be
# fooled by a broad allow substring overlapping a different confidential substring on the same line
# (the F-3/F-4/AF-1 failure mode) -- it circumvents substring logic entirely. Matching is
# case-SENSITIVE, trailing-whitespace-trimmed, whole-line exact. Interactive "y" appends the vetted
# line here so the next scan passes it silently. Hard leaks NEVER become interactively bypassable;
# to permanently vet a non-attribution line, a human edits this file directly.
[ -n "$ALLOW_LINES_FILE" ] || ALLOW_LINES_FILE="$(default_near .leakscan-allow-lines.txt)"
# Write target for interactive "y" append (used only if ALLOW_LINES_FILE was not found on disk).
if [ -n "$ALLOW_LINES_FILE" ]; then
  ALLOW_LINES_WRITE="$ALLOW_LINES_FILE"
elif [ -d "$SCAN_PATH" ]; then
  ALLOW_LINES_WRITE="$SCAN_PATH/.leakscan-allow-lines.txt"
else
  ALLOW_LINES_WRITE="./.leakscan-allow-lines.txt"
fi

# trailing-whitespace trim (bash builtin; no subprocess per line).
trim_trailing() { local s="$1"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Normalized set of vetted lines (one per line, comments/blanks stripped, trailing-trimmed).
ALLOWED_LINES="$(
  if [ -n "$ALLOW_LINES_FILE" ] && [ -f "$ALLOW_LINES_FILE" ]; then
    while IFS= read -r _l; do
      _l="$(trim_trailing "$_l")"
      case "$_l" in ''|'#'*) continue ;; esac
      printf '%s\n' "$_l"
    done < "$ALLOW_LINES_FILE"
  fi
)"

# Extract the file CONTENT from a grep match line. In -r (directory) mode grep prints
# "<path>:<content>"; strip the "<path>:" prefix (repo paths do not contain ':'). In single-file
# mode grep prints just the content. Returns the trailing-trimmed content.
line_content() {
  local ml="$1" c
  if [ -d "$SCAN_PATH" ]; then c="${ml#*:}"; else c="$ml"; fi
  trim_trailing "$c"
}

# Whole-line exact membership test against the vetted allowed-LINES set.
line_is_vetted() {
  [ -n "$ALLOWED_LINES" ] || return 1
  printf '%s\n' "$ALLOWED_LINES" | LC_ALL=C grep -Fxq -- "$1"
}

# Append a human-vetted whole line to the allowed-LINES file (interactive "y"). Records date + actor
# as a comment for auditability. Returns non-zero if the file cannot be written (caller keeps it
# vetted for THIS run only).
append_vetted_line() {
  local line="$1" dir
  dir="$(dirname "$ALLOW_LINES_WRITE")"
  [ -d "$dir" ] || return 1
  {
    printf '# vetted %s by %s (interactive y)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${USER:-unknown}"
    printf '%s\n' "$line"
  } >> "$ALLOW_LINES_WRITE" 2>/dev/null || return 1
  ALLOWED_LINES="${ALLOWED_LINES:+$ALLOWED_LINES$'\n'}$line"   # keep in-memory set current this run
  return 0
}

if [ -z "$DENY_TERMS" ]; then
  echo "$SELF: WARNING -- no deny terms configured (looked for '${DENY_FILE:-.leakscan-deny.txt}')." >&2
  echo "$SELF: the leak-gate is INERT until you populate your confidential strings." >&2
  echo "$SELF: copy examples/leakscan-deny.example.txt -> .leakscan-deny.txt and edit it." >&2
  echo "$SELF: (passing with an empty denylist -- nothing to check)."
  exit 0
fi

# -F is LOAD-BEARING: deny terms are matched as FIXED strings, not regex. Without it a term
# containing a BRE metacharacter ([ ] \ { etc.) fails to match its own literal occurrence
# (fail-OPEN: the leak passes CLEAN). Red-team AF-1 (2026-07-22), proven with a probe.
GREP_FLAGS=(-iIF)
# AF-6 (red-team 2026-07-22): NEVER scan the gate's OWN config files. If a scan target holds its own
# .leakscan-*.txt (the default location default_near() looks in), grepping them would (a) self-match
# every deny term -> a false LEAK on a genuinely clean tree, and (b) worse -- if the adopter then
# PUBLISHES that tree, the config file ships their own confidential strings. Exclude the config
# basenames from the recursive grep; and WARN if a config file physically sits inside the scan tree.
if [ -d "$SCAN_PATH" ]; then
  GREP_FLAGS+=(-r --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv
              --exclude-dir=build --exclude-dir=dist --exclude-dir=__pycache__)
  for _cb in .leakscan-deny.txt .leakscan-allow.txt .leakscan-allow-lines.txt \
             "$(basename "${DENY_FILE:-x}")" "$(basename "${ALLOW_FILE:-x}")" "$(basename "${ALLOW_LINES_FILE:-x}")"; do
    GREP_FLAGS+=(--exclude="$_cb")
  done
  for _cb in .leakscan-deny.txt .leakscan-allow.txt .leakscan-allow-lines.txt; do
    if [ -n "$(find "$SCAN_PATH" -type f -name "$_cb" -print -quit 2>/dev/null)" ]; then
      echo "$SELF: WARNING -- '$_cb' is INSIDE the scan tree. It is excluded from scanning, but if you" >&2
      echo "$SELF:          PUBLISH this tree it ships YOUR confidential strings. Keep leak-gate config" >&2
      echo "$SELF:          OUTSIDE any tree you publish." >&2
    fi
  done
fi

hits=0
report=""
review_hits=0
review_report=""
review_content=""   # flat newline-list of vetted-candidate contents (for interactive "y" append)
# An allow term suppresses a deny term T on a line ONLY IF the allow term SUBSUMES T
# (contains T as a substring, case-insensitive). SECURITY FIX (2026-07-22 red-team): the
# previous logic suppressed a match if the line contained ANY allow term, so a broad allow
# token (e.g. "github.com/myorg") co-located with a DIFFERENT deny term (e.g.
# "myorg-private/secret") silently masked a real leak. Per-term subsumption closes that.
# Returns the subsuming allow term on stdout when suppressed, else non-zero.
allow_subsumes_term() {
  local line="$1" tl="$2" a al
  [ -n "$ALLOW_TERMS" ] || return 1
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    printf '%s' "$line" | LC_ALL=C grep -qiF -- "$a" 2>/dev/null || continue
    al="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')"
    case "$al" in
      *"$tl"*) printf '%s' "$a"; return 0 ;;
    esac
  done <<EOF
$ALLOW_TERMS
EOF
  return 1
}

while IFS= read -r term; do
  [ -n "$term" ] || continue
  # AF-3 (2026-07-22 red-team): distinguish grep's exit codes. 0 = match, 1 = no match,
  # >=2 = ERROR. The old `|| true` collapsed an error to "no match" -> fail-OPEN (an
  # unreadable file / bad invocation silently skipped that term). Fail CLOSED on error.
  if matches="$(LC_ALL=C grep "${GREP_FLAGS[@]}" -- "$term" "$SCAN_PATH" 2>/dev/null)"; then
    :   # rc 0: matches found
  else
    rc=$?
    if [ "$rc" -ge 2 ]; then
      echo "$SELF: ERROR -- grep failed (exit $rc) scanning term '$term'; failing closed." >&2
      exit 2
    fi
    continue   # rc 1: no match
  fi
  [ -n "$matches" ] || continue
  tl="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
  filtered=""
  attributed=""
  while IFS= read -r ml; do
    [ -n "$ml" ] || continue
    content="$(line_content "$ml")"
    # PRIMARY: a whole line vetted in the allowed-LINES file passes SILENTLY.
    if line_is_vetted "$content"; then
      continue
    fi
    if by="$(allow_subsumes_term "$ml" "$tl")"; then
      # Subsumed by an allow term -> REVIEW (never silently dropped). Carry the raw content so an
      # interactive "y" can append the exact vetted line to the allowed-LINES file.
      attributed+="[via allow '$by'] $ml"$'\n'
      review_content+="$content"$'\n'
    else
      filtered+="$ml"$'\n'
    fi
  done <<EOF
$matches
EOF
  filtered="${filtered%$'\n'}"
  attributed="${attributed%$'\n'}"
  if [ -n "$filtered" ]; then
    hits=$((hits + 1))
    report+="-- '$term' --"$'\n'"$filtered"$'\n'
  fi
  if [ -n "$attributed" ]; then
    review_hits=$((review_hits + 1))
    review_report+="-- inferred attribution for '$term' (confirm not a leak) --"$'\n'"$attributed"$'\n'
  fi
done <<EOF
$DENY_TERMS
EOF

# outcome 1: hard leak -> always block
if [ "$hits" -gt 0 ]; then
  {
    echo "$SELF: LEAK -- $hits configured term(s) found in $SCAN_PATH:"
    echo ""
    printf '%s\n' "$report"
    if [ "$review_hits" -gt 0 ]; then
      echo "Also $review_hits inferred-attribution item(s) need manual review:"
      printf '%s\n' "$review_report"
    fi
    echo "Remediate: remove/genericise the flagged strings, OR (if intentionally public,"
    echo "e.g. your own org name) add a phrase that CONTAINS the flagged term to your --allow-file."
  } >&2
  exit 1
fi

# outcome 2: only inferred-attribution, no hard leaks
if [ "$review_hits" -gt 0 ]; then
  # (a) blanket ack -> proceed
  if [ "$ACK_REVIEW" = "1" ]; then
    [ "$QUIET" -eq 1 ] || echo "$SELF: CLEAN -- no hard leaks; $review_hits inferred-attribution item(s) acknowledged"
    exit 0
  fi
  # (b) INTERACTIVE per-line y/n when a controlling terminal is available. Iterate the flat,
  # de-duplicated candidate CONTENTS (whole vetted lines), so a "y" appends the EXACT line to the
  # allowed-LINES file (remembered, silent next scan) -- the primary review mechanism.
  if [ "${LEAKSCAN_NONINTERACTIVE:-0}" != "1" ] && [ -r /dev/tty ]; then
    marked_leak=0
    appended=0
    seen_review=""
    echo "$SELF: MANUAL REVIEW -- decide per line (y = genuine attribution, keep + remember; n/Enter = LEAK abort):" >&2
    while IFS= read -r content; do
      [ -n "$content" ] || continue
      printf '%s\n' "$seen_review" | LC_ALL=C grep -Fxq -- "$content" 2>/dev/null && continue
      seen_review+="$content"$'\n'
      printf '\n   %s\n   genuine attribution? [y/N] ' "$content" >&2
      IFS= read -r ans < /dev/tty || ans=""
      case "$ans" in
        y|Y|yes|YES)
          if append_vetted_line "$content"; then
            appended=$((appended + 1)); printf '     -> vetted; remembered in %s\n' "$ALLOW_LINES_WRITE" >&2
          else
            printf '     -> vetted for this run (could NOT persist to %s)\n' "$ALLOW_LINES_WRITE" >&2
          fi ;;
        *) marked_leak=1; printf '     -> marked LEAK\n' >&2 ;;
      esac
    done <<EOF
$review_content
EOF
    if [ "$marked_leak" -eq 1 ]; then
      echo "" >&2; echo "$SELF: operator marked >=1 item as a LEAK -- ABORT. Remediate the flagged file(s)." >&2
      exit 1
    fi
    echo "" >&2; echo "$SELF: all inferred-attribution item(s) confirmed genuine by operator ($appended remembered)" >&2
    exit 0
  fi
  # (c) headless, not acked -> block for out-of-band review
  {
    echo "$SELF: MANUAL REVIEW -- $review_hits inferred-attribution item(s) in $SCAN_PATH (no hard leaks):"
    echo ""
    printf '%s\n' "$review_report"
    echo "Each matched a deny term but sits on a line whose --allow-file term SUBSUMES it"
    echo "(declared-attribution context). Resolve by EITHER: run in a terminal for the interactive"
    echo "y/n review (a 'y' appends the vetted whole line to the allowed-LINES file); OR add each"
    echo "exact vetted line to your --allow-lines-file; OR (once reviewed) re-run with --ack-review"
    echo "(or LEAKSCAN_ACK_REVIEW=1)."
  } >&2
  exit 3
fi

[ "$QUIET" -eq 1 ] || echo "$SELF: CLEAN -- no configured confidential terms found in $SCAN_PATH"
exit 0
