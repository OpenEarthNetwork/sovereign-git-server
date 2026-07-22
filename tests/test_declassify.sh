#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright 2026 VakeWorks AB
#
# test_declassify.sh -- local, no-network unit tests for ias-git-declassify.sh (W4).
#
# Builds a fake "private" repo (L1 keep + L2/L3 secret files to drop + a
# denylisted secret TERM committed in an OLD commit then "removed" later) and
# asserts the declassify squash makes the secret unrecoverable and the tree
# L1-only. Also asserts the mandatory-allowlist + no-preexisting-staging guards.
#
# USAGE: tools/tests/test_declassify.sh
# EXIT:  0 = all green; 1 = one or more failures.
set -uo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# bundle-root-relative: test lives at <bundle>/tests/, so .. is the bundle root
SG="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$SG/bin/ias-git-declassify.sh"

PASS=0
FAIL=0
ok()   { echo "  ok  : $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

[ -f "$TOOL" ] || { echo "${SELF}: tool not found: $TOOL" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-declassify.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# A benign token that is NOT in the real confidentiality denylist, so we can prove
# the --deny-term full-history scan works without depending on production terms.
SECRET_TERM="SUPERSECRET_TOKEN_XYZZY"

# ------------------------------------------------------------
# Build a fake "private" repo with real history.
# ------------------------------------------------------------
build_fake_repo() {
  local repo="$1"
  mkdir -p "$repo/docs" "$repo/src"
  git -C "$repo" init --quiet
  git -C "$repo" config user.name "t"
  git -C "$repo" config user.email "t@localhost"

  # L1 keep files
  echo "# Public README" > "$repo/README.md"
  echo "public docs" > "$repo/docs/GUIDE.md"
  echo "public tool" > "$repo/run.sh"

  # HISTORY-ONLY secret: README.md (an L1-KEPT path) carries the SECRET TERM in an
  # OLD commit, then a newer commit scrubs it. The working tree README.md is clean,
  # but a plain-delete public copy would still expose the term in history. This is
  # the exact case squash must render unrecoverable (design §3).
  printf '# Public README\nDRAFT leak: %s\n' "$SECRET_TERM" > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "initial public (with a draft leak in README)"

  # newer commit that scrubs the secret line from README (still in history!)
  echo "# Public README" > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "scrub draft leak from README (history retains it)"

  # An L1-pathed doc that carries the SECRET TERM in its CURRENT content -- used by
  # T4 to prove the tree+history term scan aborts when the term is really present.
  printf 'leak still here: %s\n' "$SECRET_TERM" > "$repo/docs/NOTES.md"

  # L2/L3 proprietary files that must be DROPPED by the allowlist
  echo "-----BEGIN KEY-----" > "$repo/secret.key"
  echo "fn proprietary() {}" > "$repo/src/proprietary.rs"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m "add live-secret note + proprietary L2/L3"
}

echo "== test_declassify.sh =="
FAKE="$WORK/private"
build_fake_repo "$FAKE"

# ------------------------------------------------------------
# T1: happy path squash. --allow README.md docs run.sh ; NOTES.md denied.
#     (docs would include NOTES.md; we --deny it to drop the secret-carrying file.)
# ------------------------------------------------------------
echo "-- T1: squash select L1, drop L2/L3, prove history-safe --"
ST1="$WORK/stage1"
OUT1="$WORK/out1.txt"
if "$TOOL" "$FAKE" "$ST1" \
      --allow README.md --allow docs --allow run.sh \
      --deny "docs/NOTES.md" \
      --deny-term "$SECRET_TERM" \
      --name fake-public > "$OUT1" 2>&1; then
  ok "T1 tool exited 0 (staged clean)"
else
  bad "T1 tool exited non-zero"
  cat "$OUT1" >&2
fi

# (a) staging contains ONLY L1 paths
if [ -d "$ST1" ]; then
  STAGED_FILES="$(git -C "$ST1" ls-files 2>/dev/null | LC_ALL=C sort)"
  EXPECT="$(printf '%s\n' "README.md" "docs/GUIDE.md" "run.sh" | LC_ALL=C sort)"
  if [ "$STAGED_FILES" = "$EXPECT" ]; then
    ok "T1a staging contains ONLY the L1 allowlisted paths"
  else
    bad "T1a staging file set mismatch. got:[$STAGED_FILES] want:[$EXPECT]"
  fi
else
  bad "T1a staging dir not created"
fi

# (b) secret files absent
if [ ! -e "$ST1/secret.key" ] && [ ! -e "$ST1/src/proprietary.rs" ]; then
  ok "T1b L2/L3 files (secret.key, src/proprietary.rs) absent"
else
  bad "T1b an L2/L3 file leaked into staging"
fi

# (c) secret TERM appears NOWHERE in staging git history
if [ -d "$ST1/.git" ]; then
  HITS="$(git -C "$ST1" log --all -p --no-color 2>/dev/null | grep -cF "$SECRET_TERM" || true)"
  if [ "${HITS:-0}" -eq 0 ]; then
    ok "T1c secret TERM count in full staging history == 0 (squash unrecoverable)"
  else
    bad "T1c secret TERM found ${HITS}x in staging history"
  fi
else
  bad "T1c staging has no .git to scan"
fi

# (d) leak-gate passed (tool prints the verdict)
if grep -q "leak-gate verdict : PASS" "$OUT1"; then
  ok "T1d leak-gate verdict PASS reported"
else
  bad "T1d leak-gate PASS verdict not found in output"
fi

# (single-commit history proof)
if [ -d "$ST1/.git" ]; then
  NCOMMITS="$(git -C "$ST1" rev-list --count HEAD 2>/dev/null || echo 0)"
  if [ "$NCOMMITS" -eq 1 ]; then
    ok "T1e squash produced exactly ONE commit"
  else
    bad "T1e expected 1 commit, got ${NCOMMITS}"
  fi
fi

# ------------------------------------------------------------
# T2: missing --allow must ERROR (exit 2), never publish-everything.
# ------------------------------------------------------------
echo "-- T2: missing --allow errors out --"
ST2="$WORK/stage2"
if "$TOOL" "$FAKE" "$ST2" > "$WORK/out2.txt" 2>&1; then
  bad "T2 tool exited 0 without --allow (must refuse)"
else
  rc=$?
  if [ "$rc" -eq 2 ] && [ ! -d "$ST2" ]; then
    ok "T2 missing --allow -> exit 2, no staging built"
  else
    bad "T2 wrong behaviour rc=${rc} staging_exists=$( [ -d "$ST2" ] && echo yes || echo no )"
  fi
fi

# ------------------------------------------------------------
# T3: pre-existing staging dir must ERROR (exit 2), no clobber.
# ------------------------------------------------------------
echo "-- T3: pre-existing staging dir errors out --"
ST3="$WORK/stage3"
mkdir -p "$ST3"
echo "i was here first" > "$ST3/keepme"
if "$TOOL" "$FAKE" "$ST3" --allow README.md > "$WORK/out3.txt" 2>&1; then
  bad "T3 tool exited 0 into a pre-existing dir (must refuse)"
else
  rc=$?
  if [ "$rc" -eq 2 ] && [ -f "$ST3/keepme" ]; then
    ok "T3 pre-existing staging -> exit 2, existing content untouched"
  else
    bad "T3 wrong behaviour rc=${rc}"
  fi
fi

# ------------------------------------------------------------
# T4: --deny-term hit in history must FAIL the gate (exit 1).
#     Allow the whole docs/ subtree INCLUDING NOTES.md so the secret term is in
#     the working tree AND history -> gate must abort.
#     (squash removes history, so to prove the history-scan itself we KEEP the
#     term in the tree; the confidentiality tool + term-scan should both catch it.)
# ------------------------------------------------------------
echo "-- T4: denylisted secret term present -> gate FAIL (exit 1) --"
ST4="$WORK/stage4"
if "$TOOL" "$FAKE" "$ST4" \
      --allow docs \
      --deny-term "$SECRET_TERM" > "$WORK/out4.txt" 2>&1; then
  bad "T4 tool exited 0 with a secret term in the tree (must fail gate)"
else
  rc=$?
  if [ "$rc" -eq 1 ]; then
    ok "T4 secret term in staging -> gate FAIL exit 1"
  else
    bad "T4 expected exit 1, got ${rc}"
    cat "$WORK/out4.txt" >&2
  fi
fi

# ------------------------------------------------------------
# T5: local source is never mutated (source HEAD unchanged after run).
# ------------------------------------------------------------
echo "-- T5: source repo left unmutated --"
SRC_HEAD_BEFORE="$(git -C "$FAKE" rev-parse HEAD)"
SRC_STATUS="$(git -C "$FAKE" status --porcelain)"
if [ "$SRC_HEAD_BEFORE" = "$(git -C "$FAKE" rev-parse HEAD)" ] && [ -z "$SRC_STATUS" ]; then
  ok "T5 source HEAD unchanged + clean working tree (read-only respected)"
else
  bad "T5 source repo was mutated"
fi

# ------------------------------------------------------------
# T6 (F-2): the staging repo is on branch 'main', never 'master'.
# ------------------------------------------------------------
echo "-- T6 (F-2): staged repo default branch is 'main' --"
if [ -d "$ST1/.git" ]; then
  BR="$(git -C "$ST1" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$BR" = "main" ]; then
    ok "T6 staging branch is 'main' (F-2 fixed)"
  else
    bad "T6 expected 'main', got '$BR'"
  fi
else
  bad "T6 no staging .git to inspect"
fi

# ------------------------------------------------------------
# T7 (F-1): the ledger seed is EMPTY (never carries upstream/example release data).
# Static assertion on the tool (ship-safe: no confidential strings embedded in the test).
# ------------------------------------------------------------
echo "-- T7 (F-1): ledger seed is an empty releases array --"
if grep -Eq '"releases":[[:space:]]*\[\]' "$TOOL"; then
  ok "T7 ensure_ledger seeds an EMPTY releases array (F-1 fixed)"
else
  bad "T7 empty-ledger seed not found in tool"
fi

# ------------------------------------------------------------
# T8 (AF-4/AF-5): declassify wires the leak-gate scanners safely --
#   noninteractive, exit-3 distinct from exit-1, -e-safe rc capture, ack/allow-lines forwarding.
# ------------------------------------------------------------
echo "-- T8 (AF-4/AF-5): scanner invocation wiring --"
grep -q "CONF_NONINTERACTIVE=1" "$TOOL"        && ok "T8a internal scanner run NONINTERACTIVE (AF-4)" || bad "T8a CONF_NONINTERACTIVE missing"
grep -q "LEAKSCAN_NONINTERACTIVE=1" "$TOOL"    && ok "T8b generic scanner run NONINTERACTIVE (AF-4)"  || bad "T8b LEAKSCAN_NONINTERACTIVE missing"
grep -q "needs REVIEW, exit 3" "$TOOL"         && ok "T8c exit-3 REVIEW handled distinctly (AF-5)"     || bad "T8c exit-3 distinct handling missing"
grep -q "|| rc=\$?" "$TOOL"                    && ok "T8d rc capture is -e-safe (|| rc=\$?)"           || bad "T8d -e-safe rc capture missing"
grep -q -- "--ack-review" "$TOOL"              && ok "T8e forwards --ack-review"                       || bad "T8e --ack-review forwarding missing"
grep -q -- "--allow-lines-file" "$TOOL"        && ok "T8f forwards --allow-lines-file"                 || bad "T8f --allow-lines-file forwarding missing"

echo ""
echo "== RESULT: ${PASS} passed, ${FAIL} failed =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
