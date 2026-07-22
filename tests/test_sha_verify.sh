#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# test_sha_verify.sh -- LOCAL (no-network) test of the sovereign-git SHA-integrity tools.
# Uses local bare repos + clones only. Asserts:
#   1. identical src/dst          -> ias-git-verify PASSES (exit 0)
#   2. tampered dst (extra commit)-> ias-git-verify FAILS (exit 1)
#   3. --expect-sha correct sha   -> PASSES ; wrong sha -> FAILS
#   4. --ignore-refs hides a ref-only-on-one-side divergence -> PASSES
#   H3a. narrow ignore ('refs/pull/*') still VERIFIES a faithful pair (not HEAD-only)
#   H3b. over-broad ignore ('refs/*') FAILS instead of falsely VERIFYING (over-match guard)
#   H3c. a non-refs/ glob is REJECTED up front (exit 2)
#   H3d. an ERE metachar in a glob is treated literally, not as a regex
#   5. ias-git-clone-verified     -> clones + reports VERIFIED (exit 0)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SG="${HERE}/.."   # bundle-root-relative (test lives at <bundle>/tests/); works in monorepo + public
VERIFY="${SG}/bin/ias-git-verify.sh"
CLONEV="${SG}/bin/ias-git-clone-verified.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sha-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

echo "== setup: build a bare 'src' repo with 2 commits + a tag =="
SRCWORK="$WORK/srcwork"
git init -q "$SRCWORK"
(
  cd "$SRCWORK"
  git checkout -q -b main
  printf 'hello\n' > a.txt
  git add a.txt
  git commit -q -m "c1"
  printf 'world\n' >> a.txt
  git add a.txt
  git commit -q -m "c2"
  git tag v1
)
SRC="$WORK/src.git"
git clone -q --bare "$SRCWORK" "$SRC"
# a bare clone sets HEAD; ensure it points at main
git -C "$SRC" symbolic-ref HEAD refs/heads/main

echo "== test 1: identical dst (a faithful bare clone) -> VERIFY PASS =="
DST="$WORK/dst.git"
git clone -q --bare "$SRC" "$DST"
git -C "$DST" symbolic-ref HEAD refs/heads/main
if bash "$VERIFY" "$SRC" "$DST" >/dev/null 2>&1; then
  ok "identical src/dst verifies (exit 0)"
else
  bad "identical src/dst should verify but did not"
fi

echo "== test 2: tampered dst (extra commit on main) -> VERIFY FAIL (exit 1) =="
DSTT="$WORK/dst-tamper.git"
git clone -q --bare "$SRC" "$DSTT"
git -C "$DSTT" symbolic-ref HEAD refs/heads/main
# tamper: add a commit to main in the bare repo via a temp worktree
TW="$WORK/tamper-wt"
git clone -q "$DSTT" "$TW"
(
  cd "$TW"
  git checkout -q main
  printf 'tampered\n' >> a.txt
  git add a.txt
  git commit -q -m "evil"
  git push -q origin main
)
if bash "$VERIFY" "$SRC" "$DSTT" >/dev/null 2>&1; then
  bad "tampered dst should FAIL but verify returned 0"
else
  rc=$?
  if [ "$rc" -eq 1 ]; then
    ok "tampered dst fails with exit 1"
  else
    bad "tampered dst failed but with exit ${rc} (expected 1)"
  fi
fi

echo "== test 3a: --expect-sha with the CORRECT dst HEAD sha -> PASS =="
HEADSHA="$(git -C "$SRC" rev-parse refs/heads/main)"
if bash "$VERIFY" "$SRC" "$DST" --head-only --expect-sha "$HEADSHA" >/dev/null 2>&1; then
  ok "--expect-sha correct sha passes"
else
  bad "--expect-sha correct sha should pass"
fi

echo "== test 3b: --expect-sha with a WRONG sha -> FAIL (exit 1) =="
WRONG="0000000000000000000000000000000000000000"
if bash "$VERIFY" "$SRC" "$DST" --head-only --expect-sha "$WRONG" >/dev/null 2>&1; then
  bad "--expect-sha wrong sha should FAIL but passed"
else
  rc=$?
  if [ "$rc" -eq 1 ]; then
    ok "--expect-sha wrong sha fails with exit 1"
  else
    bad "--expect-sha wrong sha failed but with exit ${rc} (expected 1)"
  fi
fi

echo "== test 4: --ignore-refs hides an extra ref only on dst -> PASS =="
DSTX="$WORK/dst-extraref.git"
git clone -q --bare "$SRC" "$DSTX"
git -C "$DSTX" symbolic-ref HEAD refs/heads/main
# add an extra ref under refs/pull/* only on dst (simulating PR refs a pull-mirror lacks)
git -C "$DSTX" update-ref refs/pull/7/head "$HEADSHA"
# without ignore, must FAIL
if bash "$VERIFY" "$SRC" "$DSTX" >/dev/null 2>&1; then
  bad "extra refs/pull/* on dst should FAIL without --ignore-refs"
else
  ok "extra refs/pull/* on dst fails without --ignore-refs"
fi
# with ignore, must PASS
if bash "$VERIFY" "$SRC" "$DSTX" --ignore-refs 'refs/pull/*' >/dev/null 2>&1; then
  ok "--ignore-refs 'refs/pull/*' hides the divergence and passes"
else
  bad "--ignore-refs 'refs/pull/*' should pass"
fi

# ---- H3 regression: --ignore-refs glob over-match (false VERIFIED) ----

echo "== test H3a: a narrow ignore ('refs/pull/*') still VERIFIES a FAITHFUL pair (behaviour preserved) =="
# faithful src/dst that both carry a refs/pull/* ref; ignoring pull refs must still VERIFY
# on the real heads/tags (NOT collapse to HEAD-only).
SRCP="$WORK/src-pull.git"
DSTP="$WORK/dst-pull.git"
git clone -q --bare "$SRC" "$SRCP"
git -C "$SRCP" symbolic-ref HEAD refs/heads/main
git clone -q --bare "$SRC" "$DSTP"
git -C "$DSTP" symbolic-ref HEAD refs/heads/main
# add an IDENTICAL refs/pull/* ref to BOTH sides (a PR ref a pull-mirror might diverge on)
git -C "$SRCP" update-ref refs/pull/9/head "$HEADSHA"
git -C "$DSTP" update-ref refs/pull/9/head "$HEADSHA"
if bash "$VERIFY" "$SRCP" "$DSTP" --ignore-refs 'refs/pull/*' >/dev/null 2>&1; then
  ok "narrow ignore still VERIFIES a faithful pair (real heads/tags compared, not HEAD-only)"
else
  bad "narrow ignore should still VERIFY a faithful pair"
fi

echo "== test H3b: an OVER-BROAD ignore ('refs/*') now FAILS instead of falsely VERIFYING =="
# dst diverges on main (extra commit), but 'refs/*' would eat every ref on both sides ->
# the OLD code collapsed to HEAD-only and printed VERIFIED. The over-match guard must FAIL.
if bash "$VERIFY" "$SRC" "$DSTT" --ignore-refs 'refs/*' >/dev/null 2>&1; then
  bad "over-broad 'refs/*' ignore FALSELY VERIFIED a divergent pair (H3 regression)"
else
  rc=$?
  if [ "$rc" -eq 1 ]; then
    ok "over-broad 'refs/*' ignore FAILS (exit 1) instead of falsely VERIFYING"
  else
    bad "over-broad 'refs/*' ignore failed but with exit ${rc} (expected 1)"
  fi
fi

echo "== test H3c: a non-refs/ glob is REJECTED up front (exit 2) =="
if bash "$VERIFY" "$SRC" "$DST" --ignore-refs '*' >/dev/null 2>&1; then
  bad "non-refs/ glob '*' should be REJECTED but was accepted"
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "non-refs/ glob '*' rejected with exit 2"
  else
    bad "non-refs/ glob '*' rejected but with exit ${rc} (expected 2)"
  fi
fi

echo "== test H3d: an ERE metachar in a glob is treated LITERALLY, not as a regex =="
# Two extra refs on dst: 'refs/heads/foo.bar' (real divergence) and 'refs/heads/fooXbar'
# (would ONLY be caught if '.' were a regex wildcard). Ignoring 'refs/heads/foo.bar'
# must remove ONLY the literal ref; 'refs/heads/fooXbar' must remain -> still FAIL.
DSTM="$WORK/dst-meta.git"
git clone -q --bare "$SRC" "$DSTM"
git -C "$DSTM" symbolic-ref HEAD refs/heads/main
git -C "$DSTM" update-ref refs/heads/foo.bar "$HEADSHA"
git -C "$DSTM" update-ref refs/heads/fooXbar "$HEADSHA"
if bash "$VERIFY" "$SRC" "$DSTM" --ignore-refs 'refs/heads/foo.bar' >/dev/null 2>&1; then
  bad "literal-'.' ignore should still FAIL (fooXbar remains) but VERIFIED -> '.' treated as regex"
else
  rc=$?
  if [ "$rc" -eq 1 ]; then
    # confirm the LITERAL ref really was ignored (i.e. it's not fooXbar being caught):
    # ignoring BOTH literal refs must now VERIFY.
    if bash "$VERIFY" "$SRC" "$DSTM" --ignore-refs 'refs/heads/foo.bar' --ignore-refs 'refs/heads/fooXbar' >/dev/null 2>&1; then
      ok "ERE metachar '.' treated literally (foo.bar ignored, fooXbar still diverges until also ignored)"
    else
      bad "ignoring both literal refs should VERIFY a faithful pair but did not"
    fi
  else
    bad "literal-'.' metachar test failed but with exit ${rc} (expected 1)"
  fi
fi

echo "== test 5: ias-git-clone-verified clones + reports VERIFIED =="
CDEST="$WORK/cloned-verified"
OUT="$WORK/clonev.out"
if bash "$CLONEV" "$SRC" "$CDEST" > "$OUT" 2>&1; then
  if grep -q "VERIFIED" "$OUT"; then
    ok "ias-git-clone-verified clones and reports VERIFIED (exit 0)"
  else
    bad "clone-verified exited 0 but no VERIFIED line"
  fi
else
  bad "ias-git-clone-verified should exit 0 (see $OUT)"
  cat "$OUT"
fi

echo "== test 6: MULTI-BRANCH working clone -> --clone-mode VERIFIES (refs/remotes/origin/* trap) =="
# A plain `git clone` materialises ONLY the default branch under refs/heads/*; the other
# branches live under refs/remotes/origin/*. Without --clone-mode a faithful multi-branch
# clone false-FAILs (the GenJSONnotebookGrader dogfood, 2026-07-21).
MBWORK="$WORK/mbwork"
git init -q "$MBWORK"
(
  cd "$MBWORK"
  git checkout -q -b main
  printf 'm\n' > f.txt; git add f.txt; git commit -q -m "m1"
  git checkout -q -b featA
  printf 'a\n' >> f.txt; git add f.txt; git commit -q -m "a1"
  git checkout -q -b featB main
  printf 'b\n' >> f.txt; git add f.txt; git commit -q -m "b1"
  git checkout -q main
  git tag v2
)
MBSRC="$WORK/mbsrc.git"
git clone -q --bare "$MBWORK" "$MBSRC"
git -C "$MBSRC" symbolic-ref HEAD refs/heads/main
MBCLONE="$WORK/mbclone"          # a WORKING (non-bare) clone: featA/featB under refs/remotes/origin/*
git clone -q "$MBSRC" "$MBCLONE"
# (a) WITHOUT --clone-mode -> must FAIL (heads featA/featB are only remote-tracking on the clone)
if bash "$VERIFY" "$MBSRC" "$MBCLONE" >/dev/null 2>&1; then
  bad "multi-branch working clone should NOT verify without --clone-mode"
else
  ok "multi-branch working clone FAILS without --clone-mode (remotes/origin/* not counted)"
fi
# (b) WITH --clone-mode -> must VERIFY (origin/* remapped to heads/*)
if bash "$VERIFY" "$MBSRC" "$MBCLONE" --clone-mode >/dev/null 2>&1; then
  ok "multi-branch working clone VERIFIES with --clone-mode"
else
  bad "multi-branch working clone should VERIFY with --clone-mode but did not"
fi

echo "== test 7: ias-git-clone-verified auto-uses --clone-mode on a MULTI-BRANCH source -> VERIFIED =="
CDESTMB="$WORK/cloned-verified-mb"
OUTMB="$WORK/clonevmb.out"
if bash "$CLONEV" "$MBSRC" "$CDESTMB" > "$OUTMB" 2>&1; then
  if grep -q "VERIFIED" "$OUTMB"; then
    ok "clone-verified VERIFIES a multi-branch source (auto --clone-mode)"
  else
    bad "clone-verified (multi-branch) exited 0 but no VERIFIED line"
  fi
else
  bad "clone-verified (multi-branch) should exit 0 (see $OUTMB)"; cat "$OUTMB"
fi

echo "== test 8: --clone-mode against a BARE dst falls back (the contributor edge case 5) -> VERIFIES =="
# A bare mirror has heads under refs/heads/* and NO refs/remotes/origin/*. --clone-mode must
# NOT drop those heads; it falls back to a normal compare so a faithful bare dst VERIFIES.
if bash "$VERIFY" "$SRC" "$DST" --clone-mode >/dev/null 2>&1; then
  ok "--clone-mode on a faithful BARE dst VERIFIES (bare-dst fallback, no false-FAIL)"
else
  bad "--clone-mode on a faithful BARE dst should VERIFY (fallback) but did not"
fi

echo "== test 9: annotated tag under --clone-mode (working clone) -> VERIFIES =="
ATWORK="$WORK/atwork"
git init -q "$ATWORK"
(
  cd "$ATWORK"
  git checkout -q -b main
  printf 'x\n' > g.txt; git add g.txt; git commit -q -m "x1"
  git tag -a -m "annotated" av1          # annotated tag -> ls-remote emits av1 AND av1^{}
)
ATSRC="$WORK/atsrc.git"
git clone -q --bare "$ATWORK" "$ATSRC"
git -C "$ATSRC" symbolic-ref HEAD refs/heads/main
ATCLONE="$WORK/atclone"
git clone -q "$ATSRC" "$ATCLONE"
if bash "$VERIFY" "$ATSRC" "$ATCLONE" --clone-mode >/dev/null 2>&1; then
  ok "annotated tag verifies under --clone-mode (peeled ^{} refs compare on both sides)"
else
  bad "annotated tag should VERIFY under --clone-mode but did not"
fi

echo ""
echo "==================================="
echo "RESULT: ${PASS} passed, ${FAIL} failed"
echo "==================================="
[ "$FAIL" -eq 0 ]
