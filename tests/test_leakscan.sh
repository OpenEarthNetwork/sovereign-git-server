#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright 2026 VakeWorks AB
#
# Regression test for ias-git-leakscan.sh — the adopter-configured generic leak-gate.
# Covers the 2026-07-22 red-team hardening: F-3/F-4 per-term subsumption, AF-1 fixed-string
# matching, AF-3 fail-closed-on-error, and the allowed-LINES review model.
set -uo pipefail
SG="$(cd "$(dirname "$0")/.." && pwd)"        # bundle root (works in monorepo AND public layout)
TOOL="$SG/bin/ias-git-leakscan.sh"
pass=0; fail=0
ok()  { echo "  ok   - $1"; pass=$((pass+1)); }
bad() { echo "  FAIL - $1"; fail=$((fail+1)); }
# run NONINTERACTIVE so attribution items deterministically return exit 3 (no /dev/tty prompt).
run() { set +e; LEAKSCAN_NONINTERACTIVE=1 "$@" >/dev/null 2>&1; rc=$?; set -e; }

echo "== leakscan: bundled examples exist =="
[ -f "$SG/examples/leakscan-deny.example.txt" ]  && ok "deny example ships"  || bad "deny example missing"
[ -f "$SG/examples/leakscan-allow.example.txt" ] && ok "allow example ships" || bad "allow example missing"
[ -f "$SG/examples/leakscan-allow-lines.example.txt" ] && ok "allow-lines example ships" || bad "allow-lines example missing"

D="$(mktemp -d)"
mkdir -p "$D/repo"
printf 'server = git.internal.acme.example\n' > "$D/repo/config.env"
printf 'just public docs\n'                    > "$D/repo/README.md"
printf 'git.internal.acme.example\n'           > "$D/deny.txt"

echo "== leak present + no allow -> FAIL (rc=1) =="
run "$TOOL" "$D/repo" --deny-file "$D/deny.txt"
[ "$rc" -eq 1 ] && ok "flagged the configured term (rc=1)" || bad "expected rc=1, got $rc"

echo "== F-3/F-4: broad allow co-located with a DIFFERENT deny term is NOT suppressed (rc=1) =="
# The allow phrase 'Copyright 2026 Acme Inc' does NOT subsume deny 'git.internal.acme.example',
# so the old blanket-suppression bug (whole-line drop) must NOT hide this real leak.
rm -f "$D/repo/config.env"
printf '# Copyright 2026 Acme Inc - git.internal.acme.example is our mirror\n' > "$D/repo/README.md"
printf 'Copyright 2026 Acme Inc\n' > "$D/allow.txt"
run "$TOOL" "$D/repo" --deny-file "$D/deny.txt" --allow-file "$D/allow.txt"
[ "$rc" -eq 1 ] && ok "co-located non-subsuming allow does NOT mask the leak (rc=1)" || bad "expected rc=1, got $rc"

echo "== subsumption: allow phrase that CONTAINS the deny term -> REVIEW (rc=3 headless) =="
# deny 'Acme Inc' IS subsumed by allow 'Copyright 2026 Acme Inc' -> inferred attribution, not silent.
printf 'Acme Inc\n' > "$D/deny2.txt"
printf 'Copyright 2026 Acme Inc\n' > "$D/repo/README.md"
run "$TOOL" "$D/repo" --deny-file "$D/deny2.txt" --allow-file "$D/allow.txt"
[ "$rc" -eq 3 ] && ok "subsumed match -> attribution review, never silent (rc=3)" || bad "expected rc=3, got $rc"

echo "== AF-1: a deny term with regex metacharacters matches its LITERAL (rc=1) =="
# Without grep -F, 'secret[db]tok' would be a BRE class and miss the literal -> fail-OPEN.
mkdir -p "$D/af1"; printf 'key: secret[db]tok present\n' > "$D/af1/x.txt"
printf 'secret[db]tok\n' > "$D/deny3.txt"
run "$TOOL" "$D/af1" --deny-file "$D/deny3.txt"
[ "$rc" -eq 1 ] && ok "metachar term caught as fixed string (rc=1)" || bad "expected rc=1, got $rc (AF-1 regression!)"

echo "== allowed-LINES: exact vetted whole line passes silently; different line same token still caught =="
mkdir -p "$D/al"
printf 'doc_example = TOKEN-XYZ   # placeholder\n' > "$D/al/a.txt"
printf 'live leak: TOKEN-XYZ here\n'              > "$D/al/b.txt"
printf 'TOKEN-XYZ\n' > "$D/deny4.txt"
printf 'doc_example = TOKEN-XYZ   # placeholder\n' > "$D/allowlines.txt"
run "$TOOL" "$D/al" --deny-file "$D/deny4.txt" --allow-lines-file "$D/allowlines.txt"
[ "$rc" -eq 1 ] && ok "vetted line silent, DIFFERENT line same token still a leak (rc=1)" || bad "expected rc=1, got $rc"

echo "== allowed-LINES: ALL matching lines vetted -> clean (rc=0) =="
printf 'live leak: TOKEN-XYZ here\n' >> "$D/allowlines.txt"
run "$TOOL" "$D/al" --deny-file "$D/deny4.txt" --allow-lines-file "$D/allowlines.txt"
[ "$rc" -eq 0 ] && ok "all whole lines vetted -> clean (rc=0)" || bad "expected rc=0, got $rc"

echo "== AF-6: the gate's OWN in-tree config is excluded + does NOT self-match (clean tree -> rc 0) =="
# A clean tree that holds its own .leakscan-deny.txt (the default discovery location). The deny
# terms appear ONLY inside that config file; excluding it must leave the tree clean (not a false leak).
mkdir -p "$D/af6"
printf 'just clean public docs, nothing secret here\n' > "$D/af6/README.md"
printf 'git.internal.acme.example\nacme-secret/private\n'  > "$D/af6/.leakscan-deny.txt"
run "$TOOL" "$D/af6"   # default discovery picks up the in-tree .leakscan-deny.txt
[ "$rc" -eq 0 ] && ok "in-tree config excluded, no self-match on a clean tree (rc=0)" || bad "expected rc=0, got $rc (AF-6 regression!)"

echo "== a DIFFERENT deny term with no allow still fails =="
printf 'jane.doe\n' >> "$D/deny.txt"
printf 'author: jane.doe\n' > "$D/repo/AUTHORS"
printf 'just docs\n' > "$D/repo/README.md"
run "$TOOL" "$D/repo" --deny-file "$D/deny.txt" --allow-file "$D/allow.txt"
[ "$rc" -eq 1 ] && ok "unrelated deny term still flagged (rc=1)" || bad "expected rc=1, got $rc"

echo "== no deny file configured -> WARN + pass (rc=0), gate inert =="
E="$(mktemp -d)"; printf 'anything\n' > "$E/x.txt"
run "$TOOL" "$E" --deny-file "$E/none.txt"
[ "$rc" -eq 0 ] && ok "empty/absent denylist warns + passes (rc=0)" || bad "expected rc=0, got $rc"

rm -rf "$D" "$E"
echo
echo "RESULT: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
