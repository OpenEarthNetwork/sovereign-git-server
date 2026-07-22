#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright 2026 VakeWorks AB
#
# ias-git-declassify.sh -- sovereign-git W4: turn a private, layered repo
# (L1 public + L2 shared-internal + L3 proprietary) into a HISTORY-SAFE,
# LEAK-GATED, L1-only PUBLIC snapshot, STAGED FOR REVIEW.
#
# It does NOT publish, push, create a remote, or touch any forge. It builds a
# fresh git repo in <staging-dir> containing ONLY the --allow'ed paths, with a
# deliberately DISTINCT (non-inherited) history so no L2/L3 bytes can leak from
# older commits (design §3). The output is staged for human + independent-agent
# leak-gate review; an op-gated publish + mirror + SHA-verify happens LATER via
# other tools (ias-git-mirror-setup.sh / ias-git-verify.sh).
#
# USAGE:
#   ias-git-declassify.sh <private-source> <staging-dir> --allow <glob> [--allow <glob>...] \
#                         [--deny <glob>...] [--method squash|filter] [--name <public-repo-name>] \
#                         [--deny-term <term>...] [--record]
#
# POSITIONALS:
#   <private-source>  local path OR git URL to the private repo (or a subtree dir).
#                     A local path is treated READ-ONLY (copied out, never mutated).
#   <staging-dir>     where the declassified PUBLIC snapshot is built. MUST NOT
#                     pre-exist. Becomes a FRESH single-commit (squash) git repo.
#
# OPTIONS:
#   --allow <glob>    L1 path glob to KEEP (relative to the source root). REPEATABLE.
#                     ALLOWLIST beats denylist. If OMITTED entirely -> ERROR (we
#                     NEVER default to "publish everything"). Globs are matched
#                     against paths relative to the source root; a directory glob
#                     (e.g. 'docs') keeps the whole subtree.
#   --deny <glob>     extra path glob to DROP even if under an --allow (belt-and-
#                     suspenders). REPEATABLE.
#   --method squash   (DEFAULT) build the allowlisted tree, then `git init` a
#                     fresh repo + ONE commit. History-safe by construction:
#                     no .git is copied from the source, so zero inherited history.
#   --method filter   use git-filter-repo to keep ONLY the --allow paths across
#                     the FULL history. Requires git-filter-repo on PATH; errors
#                     out telling you to use squash if it is missing.
#   --name <name>     public repo name recorded in the ledger (optional metadata).
#   --deny-term <t>   explicit secret marker to scan for in the staging history
#                     (REPEATABLE). These are the ONLY terms grepped over history:
#                     the broad confidentiality denylist is enforced over the tree
#                     by the canonical allowlist-aware tools (steps 4a/4b), NOT by
#                     a raw history grep (which would false-flag permitted public
#                     brand terms like "VakeWorks AB").
#   --record          after a clean gate, APPEND a staged (unpublished) entry to
#                     the ledger .ias/declassified-releases.json. Publish records
#                     are added LATER, op-gated.
#   --allow-unscanned (F1) proceed even if some staged files are of a type NEITHER
#                     leak scanner inspects (default: ABORT fail-closed). Use ONLY
#                     after human review of the printed --skipped manifest (e.g. a
#                     known-safe extensionless LICENSE). Prefer fixing at the root
#                     (scan-all-bytes scanners) over this override.
#   --leak-deny-file F (public/generic gate only) adopter confidential-terms file, one
#                     term per line, forwarded to ias-git-leakscan.sh --deny-file. In the
#                     public standalone bundle the leak-gate carries NO built-in terms;
#                     you supply your own here (absent -> the generic gate is inert and warns).
#   --leak-allow-lines-file F  allowed-LINES file forwarded to the leak-gate scanner: EXACT,
#                     human-vetted FULL lines that pass silently (whole-line match, un-gameable).
#                     The primary way to clear a recurring benign attribution (e.g. a CITATION.cff
#                     copyright line) without weakening the gate.
#   --ack-review      acknowledge inferred-attribution REVIEW items (scanner exit 3) so the gate
#                     proceeds. OP-GATED: only after the items were human-reviewed. Without it, an
#                     attribution-only result fails closed (exit 3 surfaced distinctly from a leak).
#   -h, --help        show this header and exit.
#
# PIPELINE (each step gated on the previous; ABORTS LOUDLY on any failure):
#   1. MATERIALISE  the private source into a temp workdir (clone if URL; copy if path).
#   2. SELECT L1    assemble ONLY (--allow minus --deny) paths into the staging tree.
#   3. HISTORY-SAFE squash = git init + ONE commit; filter = git-filter-repo allowlist.
#   4. LEAK-GATE    auto-detected: the private repo-wide scanners (check-confidentiality.sh
#                   + check-no-internal-leak.py) in the monorepo, OR the bundle-relative
#                   adopter-driven ias-git-leakscan.sh in a public standalone repo, over the
#                   tree (the AUTHORITATIVE, allowlist-aware confidentiality gate),
#                   PLUS a NARROW history object scan for the operator's explicit
#                   --deny-term secrets only. ABORT on any hit.
#   5. STAGE        leave the staging repo in place; print summary (files, commit sha,
#                   verdict) + next steps. NOTHING is published/pushed.
#
# EXIT: 0 = staged clean (ready for review). 1 = leak-gate / pipeline failure.
#       2 = usage / operational error.
#
# SAFETY: no publish, no push, no remote, no forge. Local path source is never
#         mutated. No eval, no curl|bash. Temp workdir removed on exit.
# requires bash >= 4.4 (empty-array expansion under set -u)
set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# tools/sovereign-git/bin/ -> tools/sovereign-git/ -> tools/ -> repo root.
# TOOLS_DIR is the monorepo tools/ dir: its presence (check-confidentiality.sh etc.)
# is how the leak-gate auto-detects INTERNAL (monorepo) vs GENERIC (public standalone,
# where SCRIPT_DIR/../.. has no such scanners -> bundled ias-git-leakscan.sh is used).
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLANS_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"

CONF_TOOL="$TOOLS_DIR/check-confidentiality.sh"
LEAK_TOOL="$TOOLS_DIR/check-no-internal-leak.py"
SCRUB_TOOL="$SCRIPT_DIR/ias-git-scrub-provenance.sh"
# NOTE: the broad confidentiality denylist is NOT read directly here.
# CONF_TOOL / LEAK_TOOL own it and apply it allowlist-aware
# over the staging TREE (steps 4a/4b). This tool only greps history for the
# operator's explicit --deny-term secrets (step 4c).
LEDGER="$PLANS_ROOT/.ias/declassified-releases.json"

# Leak-gate auto-detect. In the MONOREPO the private repo-wide scanners are present at
# $TOOLS_DIR -> use them (our confidential denylist; unchanged behaviour). In a PUBLIC
# standalone repo those do not ship, so fall back to the BUNDLE-RELATIVE, adopter-driven
# generic scanner (zero hardcoded terms; reads the adopter's .leakscan-deny.txt).
LEAKSCAN_TOOL="$SCRIPT_DIR/ias-git-leakscan.sh"
if [ -f "$CONF_TOOL" ] && [ -f "$LEAK_TOOL" ]; then
  LEAKGATE_MODE="internal"
else
  LEAKGATE_MODE="generic"
fi

die() { echo "${SELF}: ERROR: $*" >&2; exit 2; }
fail() { echo "${SELF}: FAIL: $*" >&2; exit 1; }
say() { echo "== $* =="; }

# ---- arg parse ----
SRC=""
STAGING=""
METHOD="squash"
PUB_NAME=""
DO_RECORD=0
ALLOW_UNSCANNED=0   # F1: explicit operator override to proceed past unscanned-type files
LEAK_DENY_FILE=""   # generic gate: adopter confidential-terms file -> ias-git-leakscan.sh --deny-file
LEAK_ALLOW_LINES_FILE=""   # allowed-LINES file forwarded to the leak-gate scanner (--allow-lines-file)
ACK_REVIEW=0        # op-gated: ack inferred-attribution review items (forwarded to the scanner)
ALLOW=()
DENY=()
DENY_TERMS=()
POSN=()

while [ $# -gt 0 ]; do
  case "$1" in
    --allow) [ $# -ge 2 ] || die "--allow needs a glob"; ALLOW+=("$2"); shift 2 ;;
    --allow=*) ALLOW+=("${1#*=}"); shift ;;
    --deny) [ $# -ge 2 ] || die "--deny needs a glob"; DENY+=("$2"); shift 2 ;;
    --deny=*) DENY+=("${1#*=}"); shift ;;
    --deny-term) [ $# -ge 2 ] || die "--deny-term needs a value"; DENY_TERMS+=("$2"); shift 2 ;;
    --deny-term=*) DENY_TERMS+=("${1#*=}"); shift ;;
    --method) [ $# -ge 2 ] || die "--method needs squash|filter"; METHOD="$2"; shift 2 ;;
    --method=*) METHOD="${1#*=}"; shift ;;
    --name) [ $# -ge 2 ] || die "--name needs a value"; PUB_NAME="$2"; shift 2 ;;
    --name=*) PUB_NAME="${1#*=}"; shift ;;
    --leak-deny-file) [ $# -ge 2 ] || die "--leak-deny-file needs a path"; LEAK_DENY_FILE="$2"; shift 2 ;;
    --leak-deny-file=*) LEAK_DENY_FILE="${1#*=}"; shift ;;
    --leak-allow-lines-file) [ $# -ge 2 ] || die "--leak-allow-lines-file needs a path"; LEAK_ALLOW_LINES_FILE="$2"; shift 2 ;;
    --leak-allow-lines-file=*) LEAK_ALLOW_LINES_FILE="${1#*=}"; shift ;;
    --ack-review) ACK_REVIEW=1; shift ;;
    --record) DO_RECORD=1; shift ;;
    --allow-unscanned) ALLOW_UNSCANNED=1; shift ;;
    -h|--help) sed -n '7,70p' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do POSN+=("$1"); shift; done ;;
    -*) die "unknown option: $1" ;;
    *) POSN+=("$1"); shift ;;
  esac
done

[ "${#POSN[@]}" -ge 2 ] || die "usage: ${SELF} <private-source> <staging-dir> --allow <glob> [--allow <glob>...] [--deny <glob>...] [--method squash|filter] [--name <name>]"
SRC="${POSN[0]}"
STAGING="${POSN[1]}"

case "$METHOD" in
  squash|filter) : ;;
  *) die "--method must be 'squash' or 'filter', got '${METHOD}'" ;;
esac

# ALLOWLIST IS MANDATORY -- never default to publishing everything.
if [ "${#ALLOW[@]}" -eq 0 ]; then
  die "no --allow globs given. W4 REFUSES to declassify without an explicit L1 allowlist (never 'publish everything'). Pass one or more --allow <glob>."
fi

# STAGING MUST NOT PRE-EXIST (we build a fresh repo; refusing avoids clobbering).
if [ -e "$STAGING" ]; then
  die "staging dir already exists: '${STAGING}'. Refusing to build into an existing path (pass a fresh path)."
fi

# leak-gate tool(s) must be present for the detected mode
if [ "$LEAKGATE_MODE" = "internal" ]; then
  [ -f "$CONF_TOOL" ] || die "leak-gate tool missing: $CONF_TOOL"
  [ -f "$LEAK_TOOL" ] || die "leak-gate tool missing: $LEAK_TOOL"
else
  [ -f "$LEAKSCAN_TOOL" ] || die "leak-gate tool missing: $LEAKSCAN_TOOL (bundle-relative generic scanner)"
fi

command -v git >/dev/null 2>&1 || die "git not found on PATH"

# ---- temp workdir + cleanup ----
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/ias-git-declassify.XXXXXX")" || die "mktemp failed"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

MATERIALISED="$TMPD/source"   # read-only working copy of the private source
mkdir -p "$MATERIALISED"

# ============================================================
# STEP 1 -- MATERIALISE
# ============================================================
say "STEP 1/5 MATERIALISE private source"
SRC_SHA=""
is_url=0
case "$SRC" in
  *://*|git@*) is_url=1 ;;
esac

if [ "$is_url" -eq 1 ]; then
  echo "  source is a git URL -> clone (full history)"
  # scrub any credential-in-URL from any error git prints
  if ! git clone --quiet "$SRC" "$MATERIALISED/repo" 2> "$TMPD/clone.err"; then
    sed -E 's#(://)[^@/]*@#\1***@#g' "$TMPD/clone.err" >&2 || true
    fail "git clone failed for source URL"
  fi
  SRC_ROOT="$MATERIALISED/repo"
  SRC_SHA="$(git -C "$SRC_ROOT" rev-parse --short HEAD 2>/dev/null || echo "")"
else
  [ -e "$SRC" ] || die "source path does not exist: '${SRC}'"
  echo "  source is a local path -> copy out READ-ONLY (source never mutated)"
  # copy the entire source tree (including any .git) into the temp workdir so we
  # never touch the original. Use cp -a to preserve modes/symlinks.
  cp -a "$SRC" "$MATERIALISED/repo"
  SRC_ROOT="$MATERIALISED/repo"
  # if the source (or its parent) is a git repo, record the source HEAD for the ledger.
  if git -C "$SRC" rev-parse --short HEAD >/dev/null 2>&1; then
    SRC_SHA="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo "")"
  fi
fi
[ -d "$SRC_ROOT" ] || die "materialised source root is not a directory: $SRC_ROOT"
echo "  materialised at (temp): $SRC_ROOT  source_sha=${SRC_SHA:-<none>}"

# ============================================================
# STEP 2 + 3 -- SELECT L1 + HISTORY-SAFE
# ============================================================

# path_denied <relpath>: 0 (true) if relpath matches ANY --deny glob.
path_denied() {
  local rel="$1" g
  for g in "${DENY[@]:-}"; do
    [ -z "$g" ] && continue
    # match either the full path or as a directory prefix
    case "$rel" in
      $g|$g/*) return 0 ;;
    esac
  done
  return 1
}

# enumerate the concrete files under the source that match a single --allow glob.
# We resolve globs against the materialised tree so directory-globs pull subtrees.
select_files() {
  local root="$1" g rel
  for g in "${ALLOW[@]}"; do
    # Expand the glob relative to root. Use a subshell + globstar for '**'-style
    # deep matches; also handle a plain dir name (keep the whole subtree).
    (
      cd "$root" || exit 0
      shopt -s nullglob dotglob globstar 2>/dev/null || true
      # If g names a directory, enumerate every file beneath it.
      # F2: a symlink (even to a dir) is NEVER selected -- cp -a would stage a
      # mode-120000 blob whose content is the (possibly internal) target path.
      # find -type f already excludes symlinks INSIDE a real dir subtree.
      if [ -L "$g" ]; then
        echo "  skip-symlink: $g (F2: symlinks are never declassified)" >&2
      elif [ -d "$g" ]; then
        find "$g" -type f -print
      else
        # glob expansion; each match may be a file or dir
        local m
        for m in $g; do
          if [ -L "$m" ]; then
            # F2: skip symlinks; [ -e ] used to accept them and cp -a staged a
            # mode-120000 blob leaking the internal target path. Reproduced.
            echo "  skip-symlink: $m (F2: symlinks are never declassified)" >&2
          elif [ -d "$m" ]; then
            find "$m" -type f -print
          elif [ -f "$m" ]; then
            printf '%s\n' "$m"
          fi
        done
      fi
    )
  done
}

say "STEP 2/5 SELECT L1 (allowlist minus denylist)"
mkdir -p "$STAGING"
SELECTED_LIST="$TMPD/selected.txt"
: > "$SELECTED_LIST"

# gather + de-dup selected relative paths, drop .git internals + denied paths
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  # never carry source .git internals or build caches into the L1 selection
  case "$rel" in
    .git|.git/*) continue ;;
    *__pycache__/*|*.pyc|*.pyo) continue ;;   # python bytecode cache is never source
  esac
  if path_denied "$rel"; then
    echo "  deny-drop: $rel" >&2
    continue
  fi
  printf '%s\n' "$rel"
done < <(select_files "$SRC_ROOT") | LC_ALL=C sort -u > "$SELECTED_LIST"

SEL_COUNT="$(wc -l < "$SELECTED_LIST" | tr -d ' ')"
[ "$SEL_COUNT" -gt 0 ] || fail "allowlist selected ZERO files -- check your --allow globs against the source layout"
echo "  selected ${SEL_COUNT} L1 file(s)"

if [ "$METHOD" = "squash" ]; then
  say "STEP 3/5 HISTORY-SAFE = squash (fresh git init + ONE commit)"
  # copy each selected file into staging, preserving its relative path
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    dest="$STAGING/$rel"
    mkdir -p "$(dirname "$dest")"
    cp -a "$SRC_ROOT/$rel" "$dest"
  done < "$SELECTED_LIST"

  # SCRUB provenance (WB-061 headers + agent-names) BEFORE the commit so the committed
  # snapshot itself is clean. The leak-gate below still backstops any miss (fail-closed).
  if [ -f "$SCRUB_TOOL" ]; then
    bash "$SCRUB_TOOL" "$STAGING" || fail "provenance scrub failed"
  else
    echo "  WARN: scrub tool missing ($SCRUB_TOOL); relying on leak-gate only" >&2
  fi

  # init on 'main' (modern default). -c init.defaultBranch handles git >=2.28; the post-commit
  # `branch -m main` below guarantees 'main' on ANY git version (older gits still init 'master').
  git -C "$STAGING" -c init.defaultBranch=main init --quiet
  # deterministic, identityless commit (do NOT inherit any config author)
  git -C "$STAGING" -c user.name="declassify" -c user.email="declassify@localhost" add -A
  git -C "$STAGING" -c user.name="declassify" -c user.email="declassify@localhost" \
    commit --quiet -m "Declassified release snapshot" \
    || fail "commit failed (nothing staged?)"
  git -C "$STAGING" branch -m main
  SNAP_SHA="$(git -C "$STAGING" rev-parse HEAD)"
  echo "  fresh single-commit repo built. snapshot HEAD=${SNAP_SHA}"
else
  say "STEP 3/5 HISTORY-SAFE = filter (git-filter-repo over allowlist)"
  if ! command -v git-filter-repo >/dev/null 2>&1; then
    die "--method filter requires 'git-filter-repo' on PATH, which is not installed. Use --method squash (the ratified default), or install git-filter-repo."
  fi
  git -C "$SRC_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || die "--method filter requires the source to be a git repo (has history to filter); this source has none. Use --method squash."
  # clone the materialised repo into staging, then filter to the allowlist paths.
  git clone --quiet --no-local "$SRC_ROOT" "$STAGING" 2> "$TMPD/fclone.err" \
    || { cat "$TMPD/fclone.err" >&2; fail "clone into staging failed"; }
  # build --path args (one per allow glob's concrete top-level entries)
  FR_ARGS=()
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    FR_ARGS+=(--path "$rel")
  done < "$SELECTED_LIST"
  ( cd "$STAGING" && git filter-repo --force "${FR_ARGS[@]}" ) 2> "$TMPD/fr.err" \
    || { cat "$TMPD/fr.err" >&2; fail "git filter-repo failed"; }
  SNAP_SHA="$(git -C "$STAGING" rev-parse HEAD 2>/dev/null || echo "")"
  [ -n "$SNAP_SHA" ] || fail "filter produced no commit"
  # SCRUB provenance in the WORKING TREE (leak-gate scans the tree). NOTE: filter RETAINS
  # history, so provenance may persist in OLDER commits' objects -- use --method squash for
  # a fully-clean public release. The F3 history-scan + leak-gate remain the guarantee.
  if [ -f "$SCRUB_TOOL" ]; then
    bash "$SCRUB_TOOL" "$STAGING" || fail "provenance scrub failed"
    echo "  WARN: --method filter retains history; provenance scrubbed in the working tree only -- older commits may still carry it. Use --method squash for a fully-clean public tree." >&2
  fi
  echo "  filtered repo built. snapshot HEAD=${SNAP_SHA}"
fi

# ---- F2 post-stage guard: NO SYMLINKS in the snapshot (mode 120000) ----
# Belt-and-braces over select_files' symlink skip: a symlink blob's *content* is
# its target path, so a staged symlink can leak an internal path even though the
# leak-gate scanners (text-based) would never look inside a 120000 object. Covers
# BOTH squash and filter methods (filter preserves history symlinks).
SYMLINKS_STAGED="$(git -C "$STAGING" ls-files -s | awk '$1 == "120000" { print $4 }')"
if [ -n "$SYMLINKS_STAGED" ]; then
  echo "${SELF}: FAIL (F2): symlink(s) staged in the snapshot (git mode 120000)." >&2
  echo "  A symlink's blob content is its target path and can leak an internal path. Offending entries:" >&2
  echo "$SYMLINKS_STAGED" | sed 's/^/       /' >&2
  fail "refusing to declassify a tree containing symlinks (F2)"
fi

# ============================================================
# STEP 4 -- LEAK-GATE
# ============================================================
say "STEP 4/5 LEAK-GATE (working tree + full-history object scan)"
GATE_OK=1

# ---- F1 residual guard: fail-closed on UNSCANNABLE (binary) files ----
# Mom's repo-wide F1-root (2026-07-21, main e97e3c96) made both leak scanners
# scan ALL text bytes (no extension allowlist), so a leaky .env/.csv/.conf or an
# extensionless README/LICENSE is now caught by 4a/4b directly. The RESIDUAL gap
# is BINARY files: the text scanners can only WARN on them (grep -I / null bytes),
# never prove them leak-free. We refuse to green-light a BINARY in a PUBLIC
# snapshot without explicit human review. This sits ON TOP of F1-root (both layers
# wanted): F1-root scans every text byte; this guard closes the binary residue.
echo "  4-pre. binary-file guard (F1 residual, fail-closed)"
BIN_LIST="$TMPD/binary-files.txt"; : > "$BIN_LIST"
TEXT_N=0; BIN_N=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  enc="$(file --mime-encoding -b -- "$STAGING/$f" 2>/dev/null || echo unknown)"
  case "$enc" in
    binary|unknown) BIN_N=$((BIN_N+1)); printf '%s\t(%s)\n' "$f" "$enc" >> "$BIN_LIST" ;;
    *)              TEXT_N=$((TEXT_N+1)) ;;
  esac
done < <(git -C "$STAGING" ls-files)
echo "     text-scannable: ${TEXT_N} file(s); binary/unscannable: ${BIN_N} file(s)"
if [ "$BIN_N" -gt 0 ]; then
  echo "     --skipped (binary; not text-scannable by the leak-gate):" >&2
  sed 's/^/       /' "$BIN_LIST" >&2
  if [ "$ALLOW_UNSCANNED" -eq 1 ]; then
    echo "     WARN (F1): --allow-unscanned set -> proceeding despite ${BIN_N} binary file(s). Operator takes responsibility for their content." >&2
  else
    GATE_OK=0
    echo "     FAIL (F1): ${BIN_N} staged binary file(s) cannot be text-scanned for leaks; refusing to green-light a public snapshot with unscannable content." >&2
    echo "     Remediate: --deny them, or pass --allow-unscanned after human review." >&2
  fi
fi

if [ "$LEAKGATE_MODE" = "internal" ]; then
echo "  4a. check-confidentiality.sh over staging working tree"
CONF_ARGS=()
[ -n "$LEAK_ALLOW_LINES_FILE" ] && CONF_ARGS+=(--allow-lines-file "$LEAK_ALLOW_LINES_FILE")
[ "$ACK_REVIEW" -eq 1 ] && CONF_ARGS+=(--ack-attribution)
# AF-4: run NONINTERACTIVE. declassify captures the scanner's output to a file, so its interactive
# /dev/tty y/n review would prompt invisibly and hang. Noninteractive -> deterministic exit code.
# rc capture is `|| rc=$?` (NOT a bare call + `rc=$?`): under `set -e` a bare non-zero scanner exit
# would abort declassify before the case ran. The `||` neutralizes -e and captures the real code.
rc=0
CONF_NONINTERACTIVE=1 bash "$CONF_TOOL" "${CONF_ARGS[@]}" "$STAGING" > "$TMPD/conf.out" 2>&1 || rc=$?
# AF-5: distinguish exit 3 (inferred-attribution REVIEW) from exit 1 (hard leak) / 2 (config/error).
case "$rc" in
  0) echo "     PASS (confidentiality)" ;;
  3) GATE_OK=0
     echo "     FAIL (confidentiality: inferred-attribution needs REVIEW, exit 3) -- see below" >&2
     echo "     Resolve: vet each line into the allowed-LINES file + re-run, or --ack-review after review." >&2
     cat "$TMPD/conf.out" >&2 ;;
  *) GATE_OK=0
     echo "     FAIL (confidentiality: hard leak / error, exit $rc) -- see below" >&2
     cat "$TMPD/conf.out" >&2 ;;
esac

echo "  4b. check-no-internal-leak.py over staging working tree"
if python3 "$LEAK_TOOL" "$STAGING" > "$TMPD/leak.out" 2>&1; then
  echo "     PASS (internal-leak)"
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "     WARN: internal-leak tool returned 2 (pdftotext/unzip missing); tree-text scan still applies" >&2
    cat "$TMPD/leak.out" >&2
  else
    GATE_OK=0
    echo "     FAIL (internal-leak) -- see below" >&2
    cat "$TMPD/leak.out" >&2
  fi
fi
else
  # PUBLIC standalone: bundle-relative, adopter-driven generic scanner (no hardcoded terms).
  echo "  4a. ias-git-leakscan.sh (adopter terms) over staging working tree"
  LS_ARGS=("$STAGING")
  [ -n "$LEAK_DENY_FILE" ] && LS_ARGS+=(--deny-file "$LEAK_DENY_FILE")
  [ -n "$LEAK_ALLOW_LINES_FILE" ] && LS_ARGS+=(--allow-lines-file "$LEAK_ALLOW_LINES_FILE")
  [ "$ACK_REVIEW" -eq 1 ] && LS_ARGS+=(--ack-review)
  # AF-4: run NONINTERACTIVE (declassify captures output; interactive /dev/tty review would hang).
  # `|| rc=$?` keeps it -e-safe (a bare non-zero exit would abort declassify before the case).
  rc=0
  LEAKSCAN_NONINTERACTIVE=1 bash "$LEAKSCAN_TOOL" "${LS_ARGS[@]}" > "$TMPD/leak.out" 2>&1 || rc=$?
  # AF-5: distinguish exit 3 (review) from exit 1 (leak) / 2 (config).
  case "$rc" in
    0) echo "     PASS (generic leak-gate)"
       cat "$TMPD/leak.out" ;;   # surfaces the loud WARNING when the adopter denylist is empty/absent
    3) GATE_OK=0
       echo "     FAIL (generic leak-gate: inferred-attribution needs REVIEW, exit 3) -- see below" >&2
       echo "     Resolve: vet each line into your --allow-lines-file + re-run, or --ack-review after review." >&2
       cat "$TMPD/leak.out" >&2 ;;
    2) GATE_OK=0
       echo "     FAIL (generic leak-gate: usage/config error, exit 2) -- see below" >&2
       cat "$TMPD/leak.out" >&2 ;;
    *) GATE_OK=0
       echo "     FAIL (generic leak-gate: leak found, exit $rc) -- see below" >&2
       cat "$TMPD/leak.out" >&2 ;;
  esac
fi

# 4c. FULL-HISTORY object scan -- NARROW, --deny-term ONLY.
#
# The AUTHORITATIVE confidentiality gate is 4a+4b (check-confidentiality.sh +
# check-no-internal-leak.py). Those tools are ALLOWLIST-AWARE: they know that
# public attribution terms like "VakeWorks AB" / "OpenEarth Network" are
# PERMITTED (allowed_public_terms), so they do NOT flag our public brand.
#
# This history scan MUST NOT re-run the broad confidentiality denylist here. A
# raw `git log -p | grep <confidential_terms>` is (a) redundant and (b) WRONG:
# it ignores the allowlist and would re-flag permitted public brand terms that
# 4a/4b correctly pass (e.g. the SPDX "VakeWorks AB" copyright line). That
# false-positive is the bug this step used to have.
#
# For --method squash the staging repo is a SINGLE fresh commit whose content
# == the working tree, so 4a/4b over the tree ALREADY cover the only commit;
# there is no extra history to scan. For --method filter (multi-commit) we do
# scan history, but ONLY for the operator's explicit --deny-term values: those
# are real named secrets the operator wants proven absent from EVERY commit.
# The broad brand/confidentiality denylist stays the canonical tools' job.
echo "  4c. history scan for explicit --deny-term secrets only (git log --all -p)"
TERMS_FILE="$TMPD/terms.txt"
: > "$TERMS_FILE"
for t in "${DENY_TERMS[@]:-}"; do
  [ -z "$t" ] && continue
  printf '%s\n' "$t" >> "$TERMS_FILE"
done

# count non-blank lines. NOTE: `grep -c` exits 1 (no match) on an empty file and
# STILL prints "0", so the old `grep -cve ... || echo 0` produced "0\n0" and broke
# the [ -eq ] test below whenever DENY_TERMS was empty. wc -l is exit-0 always and
# emits exactly one integer.
TERM_COUNT="$( { grep -ve '^$' "$TERMS_FILE" 2>/dev/null || true; } | wc -l | tr -d ' ')"
[ -n "$TERM_COUNT" ] || TERM_COUNT=0
if [ "$TERM_COUNT" -eq 0 ]; then
  if [ "$METHOD" = "filter" ]; then
    # F3: --method filter RETAINS full history; 4a/4b scanned only the current TREE,
    # so retained history is UNSCANNED for secrets when no --deny-term is given.
    # Fail-closed (squash, the default, has no such gap: its single commit == the tree).
    echo "     WARN (F3): --method filter retains full history but NO --deny-term was given -> retained history is NOT scanned for secrets (4a/4b covered only the current tree)." >&2
    echo "              Provide --deny-term for each named secret to prove it absent from EVERY commit, or use --method squash (default; single history-free commit)." >&2
    if [ "$ALLOW_UNSCANNED" -ne 1 ]; then
      GATE_OK=0
      echo "     FAIL (F3): refusing to stage a history-retaining declassification with unscanned history. Add --deny-term(s), use --method squash, or pass --allow-unscanned after review." >&2
    fi
  else
    echo "     SKIP (squash: single commit == tree, already covered by 4a/4b; confidentiality denylist enforced there, allowlist-aware)"
  fi
else
  echo "     scanning full history for ${TERM_COUNT} explicit --deny-term secret(s)"

  HIST_DUMP="$TMPD/history.dump"
  git -C "$STAGING" log --all -p --no-color > "$HIST_DUMP" 2>/dev/null || true

  HIST_HITS="$TMPD/history.hits"
  : > "$HIST_HITS"
  if [ -s "$HIST_DUMP" ]; then
    # grep the history dump for any explicit deny-term (fixed-string, case-insensitive).
    while IFS= read -r term; do
      [ -z "$term" ] && continue
      if grep -iFn -- "$term" "$HIST_DUMP" >> "$HIST_HITS" 2>/dev/null; then
        echo "     HIT: --deny-term secret found in staging history: '${term}'" >&2
      fi
    done < "$TERMS_FILE"
  fi

  if [ -s "$HIST_HITS" ]; then
    GATE_OK=0
    echo "     FAIL: explicit --deny-term secret(s) present in staging git history (object scan). First hits:" >&2
    head -20 "$HIST_HITS" | sed 's/^/       /' >&2
  else
    echo "     PASS (no --deny-term secret in any history object)"
  fi
fi

if [ "$GATE_OK" -ne 1 ]; then
  echo "" >&2
  echo "${SELF}: LEAK-GATE FAILED. Staging repo left at '${STAGING}' for inspection." >&2
  echo "  Remediate the source (or the --allow/--deny globs), delete the staging dir, and re-run." >&2
  exit 1
fi

# ============================================================
# STEP 5 -- STAGE FOR REVIEW (no publish)
# ============================================================
say "STEP 5/5 STAGE FOR REVIEW (nothing published)"

# ledger: create an EMPTY ledger if absent. This is the ADOPTER's own release ledger --
# it must start empty (never seeded with any upstream/example release data).
ensure_ledger() {
  [ -f "$LEDGER" ] && return 0
  mkdir -p "$(dirname "$LEDGER")"
  cat > "$LEDGER" <<'JSON'
{
  "schema": "ias-declassified-releases/v1",
  "note_top": "Declassified-release linkage ledger. One entry per PUBLIC release. Publish records are release-gated; staged (unpublished) entries carry \"released\": \"STAGED\".",
  "releases": []
}
JSON
  echo "  ledger created (empty): $LEDGER"
}
ensure_ledger

if [ "$DO_RECORD" -eq 1 ]; then
  # APPEND a STAGED (unpublished) entry. Publish fields left as placeholders --
  # they are filled at op-gated publish time by a later step, not here.
  REC_NAME="${PUB_NAME:-$(basename "$STAGING")}"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - "$LEDGER" "$REC_NAME" "$SRC" "${SRC_SHA:-}" "$SNAP_SHA" "$METHOD" "$NOW" <<'PY'
import json, sys
ledger, name, src, src_sha, snap_sha, method, now = sys.argv[1:8]
with open(ledger) as f:
    d = json.load(f)
d.setdefault("releases", []).append({
    "repo": name,
    "private_canonical": src,
    "public_canonical": "STAGED (not yet published; op-gated)",
    "mirrors": [],
    "declassify_method": method,
    "last_private_source_sha": src_sha or "<unknown>",
    "last_release_snapshot_sha": snap_sha,
    "released": "STAGED",
    "staged_at": now,
    "note": "staged for review by ias-git-declassify.sh --record; publish record added later, op-gated"
})
with open(ledger, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
print(f"  ledger: appended STAGED entry '{name}' (snapshot {snap_sha[:8]})")
PY
fi

echo ""
say "DECLASSIFY STAGED OK"
echo "  method            : ${METHOD}"
echo "  private source    : ${SRC}  (sha ${SRC_SHA:-<none>})"
echo "  staging repo      : ${STAGING}"
echo "  snapshot HEAD sha : ${SNAP_SHA}"
echo "  files included    : ${SEL_COUNT}"
echo "  leak-gate verdict : PASS (confidentiality + internal-leak + --deny-term history scan)"
echo "  public name       : ${PUB_NAME:-<unset>}"
echo ""
echo "  Files:"
git -C "$STAGING" ls-files | sed 's/^/    /'
echo ""
echo "  NEXT STEPS (nothing has been published/pushed; no forge touched):"
echo "    1. HUMAN review of ${STAGING} (confirm only intended L1 content is present)."
echo "    2. INDEPENDENT-AGENT leak-gate review (e.g. the contributor's G-E) over the staging tree."
echo "    3. On explicit op approval: publish to the PUBLIC canonical (OpenEarthNetwork),"
echo "       record the linkage in ${LEDGER}, then mirror out (W1) via"
echo "       ias-git-mirror-setup.sh and SHA-verify each mirror with ias-git-verify.sh."
echo ""
echo "  (This tool intentionally stops at 'staged'. It does not publish, push, create a"
echo "   remote, or contact any forge -- that is a separate, op-gated step.)"
exit 0
