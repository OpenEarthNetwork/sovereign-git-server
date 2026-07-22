#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ias-git-verify.sh -- prove two git endpoints are byte-identical by comparing ALL ref SHAs.
#
# A git ref SHA hashes the commit object AND its entire ancestry (tree + parents,
# recursively). So if every ref (branches + tags) on <src> resolves to the SAME SHA
# as on <dst>, the two repos are provably byte-identical copies. This is the integrity
# check that every sovereign-git copy op (migrate / mirror-sync / clone / backup-restore)
# should end with.
#
# USAGE:
#   ias-git-verify.sh <src-url-or-path> <dst-url-or-path> [options]
#
# OPTIONS:
#   --ignore-refs <glob>   omit refs matching this glob from BOTH sides before diffing
#                          (repeatable). e.g. --ignore-refs 'refs/pull/*' for a pull-mirror
#                          that does not carry PR refs. The glob MUST start with 'refs/'
#                          (anything else is rejected); '*' matches within one ref-name run.
#                          If an ignore strips every comparable ref from one side, verify
#                          FAILS (it will not report VERIFIED on HEAD alone).
#   --head-only            compare only HEAD / the default branch (the symref HEAD points to),
#                          not every ref.
#   --clone-mode           the dst is a working `git clone` (not a bare/mirror). A plain clone
#                          stores non-default branches under refs/remotes/origin/* -- this remaps
#                          them to refs/heads/* so a faithful multi-branch clone verifies instead
#                          of false-FAILing. Used by ias-git-clone-verified.sh.
#   --expect-sha <sha>     assert the dst HEAD resolves to exactly this SHA (e.g. a merge SHA
#                          after a PR merge). May be given with or without --head-only.
#
# EXIT: 0 = every compared ref SHA matches (faithful copy). 1 = mismatch (differing refs
#       printed). 2 = usage / operational error.
#
# TOKENS: never printed. Pass auth to git via the environment / git credential helper /
#         ssh config -- this script only ever runs `git ls-remote` and diffs the output.
# requires bash >= 4.4 (empty-array expansion under set -u)
set -uo pipefail

SELF="$(basename "$0")"

die() { echo "${SELF}: ERROR: $*" >&2; exit 2; }

SRC=""
DST=""
HEAD_ONLY=0
CLONE_MODE=0
EXPECT_SHA=""
IGNORE_GLOBS=()

# ---- arg parse ----
POSN=()
while [ $# -gt 0 ]; do
  case "$1" in
    --head-only) HEAD_ONLY=1; shift ;;
    --clone-mode) CLONE_MODE=1; shift ;;
    --expect-sha) [ $# -ge 2 ] || die "--expect-sha needs a value"; EXPECT_SHA="$2"; shift 2 ;;
    --ignore-refs) [ $# -ge 2 ] || die "--ignore-refs needs a glob"; IGNORE_GLOBS+=("$2"); shift 2 ;;
    --ignore-refs=*) IGNORE_GLOBS+=("${1#*=}"); shift ;;
    --expect-sha=*) EXPECT_SHA="${1#*=}"; shift ;;
    -h|--help) sed -n '7,40p' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do POSN+=("$1"); shift; done ;;
    -*) die "unknown option: $1" ;;
    *) POSN+=("$1"); shift ;;
  esac
done

[ "${#POSN[@]}" -ge 2 ] || die "usage: ${SELF} <src> <dst> [--ignore-refs <glob>] [--head-only] [--expect-sha <sha>]"
SRC="${POSN[0]}"
DST="${POSN[1]}"

# VALIDATE each --ignore-refs glob up front: it MUST be anchored at refs/. An unanchored
# glob (e.g. '*' or 'foo*') could translate into an over-broad ERE that eats every ref
# from BOTH sides, collapsing verify to a HEAD-only comparison and reporting a FALSE
# VERIFIED. Reject anything not starting with the literal prefix "refs/".
for _g in "${IGNORE_GLOBS[@]}"; do
  case "$_g" in
    refs/*) : ;;
    *) die "--ignore-refs glob must start with 'refs/': got '${_g}' (refusing over-broad pattern)" ;;
  esac
done

# glob_to_ere <glob>: translate a ref glob into an ERE anchored at the start of the ref name.
# Escape EVERY ERE metachar EXCEPT '*', then map glob '*' -> '[^ ]*' (one path segment run,
# never a space, since our normalised lines are "<ref> <sha>"). Escaping only '.'/'[' (the
# old behaviour) let metachars like '+ ( ) { } ^ $ | ? \' act as regex operators, and left
# an unescaped-except-'*' path that could over-match -- the H3 bug.
glob_to_ere() {
  local g="$1" out="" i ch
  for (( i=0; i<${#g}; i++ )); do
    ch="${g:i:1}"
    case "$ch" in
      '*') out+='[^ ]*' ;;                       # glob wildcard -> one ref-name segment run
      '.'|'['|']'|'^'|'$'|'('|')'|'{'|'}'|'+'|'?'|'|'|'\') out+="\\${ch}" ;;  # ERE metachars -> literal
      *) out+="$ch" ;;
    esac
  done
  printf '%s' "$out"
}

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/ias-git-verify.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMPD"' EXIT

# ls_remote <endpoint> <outfile>: run git ls-remote, capture "sha<TAB>ref" lines.
# Fails (exit 2) if the endpoint is unreachable, so we never silently "match" two empties.
ls_remote() {
  local ep="$1" out="$2" errf="$3"
  if ! git ls-remote "$ep" > "$out" 2> "$errf"; then
    echo "${SELF}: ERROR: git ls-remote failed for endpoint (see below)" >&2
    # scrub any credential-in-URL from git's own error before showing it
    sed -E 's#(://)[^@/]*@#\1***@#g' "$errf" >&2
    return 2
  fi
  return 0
}

# normalise <infile>: sorts by ref name, applies --head-only / --ignore-refs filtering.
# Emits "ref<SP>sha" lines. HEAD symref line (has no ref name diff) handled explicitly.
#
# refs/remotes/* is ALWAYS dropped: those are a working clone's client-side tracking
# bookkeeping (e.g. refs/remotes/origin/main), not repo content. A bare canonical repo
# has no refs/remotes/*, so a faithful non-bare clone would spuriously "diverge" without
# this. The content refs that prove a byte-identical copy are refs/heads/*, refs/tags/*
# and HEAD -- those are what we compare.
normalise() {
  local in="$1" side="$2" clone="$3"
  # git ls-remote lines: "<sha>\t<ref>"
  # CLONE_MODE (dst is a working `git clone`): a plain clone materialises ONLY the default
  # branch under refs/heads/*; every OTHER branch lives under refs/remotes/origin/*. So to
  # verify a working clone against its source we remap the clone's refs/remotes/origin/<X>
  # -> refs/heads/<X> (dropping the origin/HEAD symref and the local refs/heads/* subset,
  # which the remote-tracking refs already cover) and compare THAT to the source's heads.
  # Tags + HEAD compare directly. Without this, a faithful multi-branch clone false-FAILs.
  awk -v clone="$clone" -v side="$side" '
    {
      sha=$1; ref=$2;
      if (ref=="") next;
      if (clone=="1" && side=="dst") {
        if (ref=="refs/remotes/origin/HEAD") next;                 # symref, not content
        if (ref ~ /^refs\/remotes\/origin\//) {                    # branch content -> heads/*
          sub(/^refs\/remotes\/origin\//, "refs/heads/", ref); print ref" "sha; next;
        }
        if (ref ~ /^refs\/heads\//) next;                          # local heads = subset; use remote-tracking
        if (ref ~ /^refs\/remotes\//) next;                        # other remotes bookkeeping
        print ref" "sha; next;                                     # tags, HEAD
      }
      if (ref ~ /^refs\/remotes\//) next;
      print ref" "sha;
    }
  ' "$in" | {
    if [ "$HEAD_ONLY" -eq 1 ]; then
      grep -E '^HEAD ' || true
    else
      cat
    fi
  } | LC_ALL=C sort
}

# count_nonhead <normfile>: number of comparable non-HEAD refs (heads/tags/etc). Used by
# the over-match guard: if ignores strip one side to ZERO non-HEAD refs while the other
# still has some, we MUST NOT report VERIFIED on HEAD alone.
count_nonhead() {
  # grep -c returns exit 1 when count is 0 but still prints the count; capture and echo it.
  local n
  n="$(grep -cvE '^HEAD ' "$1" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}

# drop_glob <glob> <in-normfile> <out-normfile>: remove lines whose ref matches <glob>
# (translated to an anchored ERE). Echoes the number of lines removed on stdout.
drop_glob() {
  local g="$1" in="$2" out="$3" ere before after
  ere="$(glob_to_ere "$g")"
  before="$(wc -l < "$in" | tr -d ' ')"
  grep -vE "^${ere} " "$in" > "$out" || true
  after="$(wc -l < "$out" | tr -d ' ')"
  printf '%s' "$(( before - after ))"
}

SRC_RAW="$TMPD/src.raw"; DST_RAW="$TMPD/dst.raw"
SRC_ERR="$TMPD/src.err"; DST_ERR="$TMPD/dst.err"

ls_remote "$SRC" "$SRC_RAW" "$SRC_ERR" || exit 2
ls_remote "$DST" "$DST_RAW" "$DST_ERR" || exit 2

# --expect-sha assertion on dst HEAD (default-branch tip)
if [ -n "$EXPECT_SHA" ]; then
  DST_HEAD="$(awk '$2=="HEAD"{print $1; exit}' "$DST_RAW")"
  if [ -z "$DST_HEAD" ]; then
    # fall back to the branch HEAD points to is not resolvable from ls-remote alone;
    # HEAD row is present for normal remotes. If truly absent, report.
    echo "FAIL: dst has no HEAD ref to compare against --expect-sha" >&2
    exit 1
  fi
  if [ "$DST_HEAD" != "$EXPECT_SHA" ]; then
    echo "FAIL: dst HEAD ${DST_HEAD} != expected ${EXPECT_SHA}"
    exit 1
  fi
  echo "OK: dst HEAD == expected ${EXPECT_SHA}"
fi

SRC_N="$TMPD/src.norm"; DST_N="$TMPD/dst.norm"
# --clone-mode only makes sense for a NON-bare working clone (branches under
# refs/remotes/origin/*). If --clone-mode was given but the dst has no such refs (a bare
# repo / server mirror), fall back to normal comparison so a faithful bare dst does not
# false-FAIL (the contributor review 2026-07-21, edge case 5).
DST_CLONE="$CLONE_MODE"
if [ "$CLONE_MODE" -eq 1 ] && ! grep -q 'refs/remotes/origin/' "$DST_RAW"; then
  DST_CLONE=0
  echo "note: --clone-mode ignored for dst (no refs/remotes/origin/* -> treating dst as a bare/normal repo)" >&2
fi
normalise "$SRC_RAW" "src" 0 > "$SRC_N"
normalise "$DST_RAW" "dst" "$DST_CLONE" > "$DST_N"

# ---- apply --ignore-refs (with transparency + over-match guard) ----
if [ "${#IGNORE_GLOBS[@]}" -gt 0 ]; then
  # non-HEAD ref counts BEFORE any ignore is applied (baseline for the guard)
  SRC_NONHEAD_BEFORE="$(count_nonhead "$SRC_N")"
  DST_NONHEAD_BEFORE="$(count_nonhead "$DST_N")"

  echo "-- applying ${#IGNORE_GLOBS[@]} --ignore-refs glob(s) --" >&2
  for g in "${IGNORE_GLOBS[@]}"; do
    src_rm="$(drop_glob "$g" "$SRC_N" "$SRC_N.ig")"; mv "$SRC_N.ig" "$SRC_N"
    dst_rm="$(drop_glob "$g" "$DST_N" "$DST_N.ig")"; mv "$DST_N.ig" "$DST_N"
    echo "  ignore '${g}' removed ${src_rm} src / ${dst_rm} dst refs" >&2
  done

  # OVER-MATCH GUARD: if the ignores stripped ONE side to zero comparable non-HEAD refs
  # while the other side still has >=1, refuse to report VERIFIED on HEAD alone -- an
  # over-broad ignore (the H3 failure mode) would otherwise hide real branch/tag divergence.
  SRC_NONHEAD_AFTER="$(count_nonhead "$SRC_N")"
  DST_NONHEAD_AFTER="$(count_nonhead "$DST_N")"
  if [ "$SRC_NONHEAD_BEFORE" -gt 0 ] || [ "$DST_NONHEAD_BEFORE" -gt 0 ]; then
    if { [ "$SRC_NONHEAD_AFTER" -eq 0 ] && [ "$DST_NONHEAD_AFTER" -gt 0 ]; } || \
       { [ "$DST_NONHEAD_AFTER" -eq 0 ] && [ "$SRC_NONHEAD_AFTER" -gt 0 ]; }; then
      echo "FAIL: ignore-refs removed all comparable refs on one side -- refusing to report VERIFIED on HEAD alone" >&2
      echo "  (src non-HEAD refs after ignore: ${SRC_NONHEAD_AFTER}, dst: ${DST_NONHEAD_AFTER})" >&2
      exit 1
    fi
  fi
fi

SRC_COUNT="$(wc -l < "$SRC_N" | tr -d ' ')"
DST_COUNT="$(wc -l < "$DST_N" | tr -d ' ')"

if [ "$SRC_COUNT" -eq 0 ] && [ "$DST_COUNT" -eq 0 ] && [ -z "$EXPECT_SHA" ]; then
  echo "FAIL: no comparable refs on either side (nothing verified)"
  exit 1
fi

if diff -u "$SRC_N" "$DST_N" > "$TMPD/diff.out" 2>&1; then
  echo "VERIFIED: all ${SRC_COUNT} compared ref SHAs match (faithful copy)."
  exit 0
else
  echo "FAIL: ref SHA mismatch between src and dst. Differing refs:"
  # show only the differing lines (strip diff header noise); '<' = src-only, '>' = dst-only
  grep -E '^[<>] ' "$TMPD/diff.out" | sed -e 's/^< /  src-only : /' -e 's/^> /  dst-only : /'
  echo "  (src refs: ${SRC_COUNT}, dst refs: ${DST_COUNT})"
  exit 1
fi
