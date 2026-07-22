#!/usr/bin/env bash
# Regression tests for the sovereign-git red-team closure (findings F1-F7).
# F1 + F2 are FUNCTIONAL (build a tree, run declassify, assert behaviour); F3/F4/F5/F7
# are STATIC (assert the hardening pattern is present) matching test_sovereign_git_security.sh idiom.
# F1-root (repo-wide scan-all-bytes) is covered by tools/tests/test_f1root_scan_all_bytes.sh (maintainer).
set -uo pipefail
# bundle-root-relative: test lives at <bundle>/tests/, so .. is the bundle root
# (works in both the monorepo at tools/sovereign-git/ and the public standalone repo).
SG="$(cd "$(dirname "$0")/.." && pwd)"
DECL="$SG/bin/ias-git-declassify.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sovgit-f1f7.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok() { echo "ok   - $1"; PASS=$((PASS+1)); }
no() { echo "FAIL - $1"; FAIL=$((FAIL+1)); }
chk() { if [ "$1" = "$2" ]; then ok "$3"; else no "$3 (want '$2' got '$1')"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else no "$3"; fi; }
hasnt() { if grep -qE "$2" "$1"; then no "$3"; else ok "$3"; fi; }

# ===== F2 (functional): symlinks never staged =====
S2="$WORK/s2"; mkdir -p "$S2"; printf 'x\n' > "$S2/a.md"; ln -s /etc/hostname "$S2/lnk"
bash "$DECL" "$S2" "$WORK/st2" --allow 'a.md' --allow 'lnk' > "$WORK/f2.out" 2>&1
chk "$?" "0" "F2: declassify ok with a symlink present (skipped, not fatal)"
if [ -d "$WORK/st2/.git" ]; then
  if [ -z "$(git -C "$WORK/st2" ls-files -s | awk '$1=="120000"')" ]; then ok "F2: no 120000 symlink blob staged"; else no "F2: symlink blob staged"; fi
else no "F2: staging built"; fi

# ===== F1 (functional): binary file fails closed; --allow-unscanned overrides =====
S1="$WORK/s1"; mkdir -p "$S1"; printf 'ok\n' > "$S1/b.md"; printf 'PK\003\004\000\000bin\000\377' > "$S1/x.bin"
bash "$DECL" "$S1" "$WORK/st1" --allow 'b.md' --allow 'x.bin' > "$WORK/f1.out" 2>&1
chk "$?" "1" "F1: declassify ABORTS fail-closed on a binary file"
has "$WORK/f1.out" "FAIL \(F1\)" "F1: emits FAIL (F1)"
bash "$DECL" "$S1" "$WORK/st1b" --allow 'b.md' --allow 'x.bin' --allow-unscanned > "$WORK/f1b.out" 2>&1
chk "$?" "0" "F1: --allow-unscanned override proceeds"
has "$WORK/f1b.out" "WARN \(F1\)" "F1: override emits WARN"

# ===== F1 negative: clean text of any extension passes (F1-root scans it) =====
S3="$WORK/s3"; mkdir -p "$S3"; printf 'no secret\n' > "$S3/n.env"
bash "$DECL" "$S3" "$WORK/st3" --allow 'n.env' > "$WORK/f3.out" 2>&1
chk "$?" "0" "F1: clean text .env passes (scanned by F1-root, not tripped)"

# ===== F3 (static): filter+no-deny-term fails closed / warns hard =====
has "$DECL" "FAIL \(F3\)" "F3: filter-without-deny-term fail-closed present"
has "$DECL" "WARN \(F3\)" "F3: filter history warn present"

# ===== F4 (static): https guard + --proto on both mirror scripts =====
has "$SG/bin/ias-git-mirror-sync.sh"  "refusing non-https" "F4: mirror-sync https guard"
has "$SG/bin/ias-git-mirror-sync.sh"  "proto '=https'"     "F4: mirror-sync curl --proto"
has "$SG/bin/ias-git-mirror-setup.sh" "refusing non-https" "F4: mirror-setup https guard"
has "$SG/bin/ias-git-mirror-setup.sh" "proto '=https'"     "F4: mirror-setup curl --proto"

# ===== F5 (static): gpg_verify bound to pinned fpr, not bare GOODSIG =====
has "$SG/bin/ias-git-server-update.sh" "VALIDSIG .\*" "F5: gpg_verify binds VALIDSIG to pinned fpr"
hasnt "$SG/bin/ias-git-server-update.sh" "GNUPG:\] \(VALIDSIG\|GOODSIG\)'" "F5: bare (VALIDSIG|GOODSIG) accept removed"

# ===== F7 (static): dead ** glob dropped in backup =====
hasnt "$SG/bin/ias-git-backup.sh" '/\*\*/forgejo-dump' "F7: dead ** glob removed from backup"

echo ""
echo "SOVGIT F1-F7 HARDENING: ${PASS} pass, ${FAIL} fail"
[ "$FAIL" -eq 0 ]
