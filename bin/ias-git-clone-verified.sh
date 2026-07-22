#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ias-git-clone-verified.sh -- clone a repo into the canonical local layout AND verify.
#
# The "SHA-confirming clone" for sovereign-git copy ops: does a FULL clone (all refs),
# then runs ias-git-verify.sh to prove every ref SHA in the local clone matches the
# remote. Reports VERIFIED only if the clone is a provably faithful copy.
#
# USAGE:
#   ias-git-clone-verified.sh <remote-url> <dest-dir> [--ignore-refs <glob> ...]
#
# It runs the verify in --clone-mode (a working clone keeps non-default branches under
# refs/remotes/origin/*) and auto-ignores the forge PR/MR ref namespaces (refs/pull/*,
# refs/merge-requests/*) which a clone never fetches -- so a faithful multi-branch clone
# VERIFIES rather than false-FAILing.
#
# OPTIONS (passed through to ias-git-verify.sh):
#   --ignore-refs <glob>   omit ADDITIONAL refs matching this glob from the comparison (repeatable).
#
# EXIT: 0 = cloned AND VERIFIED. 1 = clone succeeded but verification FAILED. 2 = usage/clone error.
#
# TOKENS: never printed. Auth goes to git via env / credential helper / ssh config.
# requires bash >= 4.4 (empty-array expansion under set -u)
set -uo pipefail

SELF="$(basename "$0")"
HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY="${HERE}/ias-git-verify.sh"

die() { echo "${SELF}: ERROR: $*" >&2; exit 2; }

[ -x "$VERIFY" ] || [ -f "$VERIFY" ] || die "cannot find ias-git-verify.sh next to this script (${VERIFY})"

REMOTE=""
DEST=""
PASSTHRU=()
POSN=()
while [ $# -gt 0 ]; do
  case "$1" in
    --ignore-refs) [ $# -ge 2 ] || die "--ignore-refs needs a glob"; PASSTHRU+=("--ignore-refs" "$2"); shift 2 ;;
    --ignore-refs=*) PASSTHRU+=("--ignore-refs" "${1#*=}"); shift ;;
    -h|--help) sed -n '7,25p' "$0"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do POSN+=("$1"); shift; done ;;
    -*) die "unknown option: $1" ;;
    *) POSN+=("$1"); shift ;;
  esac
done

[ "${#POSN[@]}" -ge 2 ] || die "usage: ${SELF} <remote-url> <dest-dir> [--ignore-refs <glob>]"
REMOTE="${POSN[0]}"
DEST="${POSN[1]}"

[ -e "$DEST" ] && die "dest-dir already exists: ${DEST} (refusing to overwrite)"

echo "== clone-verified: ${REMOTE} -> ${DEST} =="
echo "-- cloning (full, all refs) --"
if ! git clone "$REMOTE" "$DEST"; then
  die "git clone failed"
fi

echo "-- verifying clone against remote (comparing all ref SHAs) --"
# --clone-mode: dst is a working clone (non-default branches live under refs/remotes/origin/*).
# Auto-ignore the forge PR/MR ref namespaces (refs/pull/*, refs/merge-requests/*): these are
# server-side artifacts a `git clone` never fetches, so they are legitimately absent from the
# clone and must not count as divergence. User-supplied --ignore-refs are appended.
AUTO_IGNORE=(--ignore-refs "refs/pull/*" --ignore-refs "refs/merge-requests/*")
if bash "$VERIFY" "$REMOTE" "$DEST" --clone-mode "${AUTO_IGNORE[@]}" "${PASSTHRU[@]}"; then
  echo "VERIFIED: local clone at ${DEST} is a faithful (byte-identical) copy of ${REMOTE}"
  exit 0
else
  echo "FAIL: clone at ${DEST} does NOT match remote ${REMOTE} -- do NOT trust this copy"
  exit 1
fi
