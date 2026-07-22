#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# test_server_update.sh -- LOCAL (no-network, no-server) test of ias-git-server-update.sh.
#
# This NEVER connects to any real Forgejo host and NEVER modifies a system binary or systemd.
# It exercises the offline-decidable logic by:
#   1. delegating to the tool's own built-in --self-test (version-compare, sha256 gate, argparse)
#   2. driving the real pipeline with a FAKE forgejo binary + a PATH-shadowed `curl` that serves
#      local fixture files, so we can assert:
#         - --check idempotent no-op when installed == target (exit 0)
#         - --check reports update-available when target > installed (exit 10)
#         - dry-run (no --apply) verifies but makes NO changes (fake binary untouched)
#         - a TAMPERED checksum causes a non-zero abort (no swap)
#         - argparse rejects an unknown option (exit 2)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SG="${HERE}/.."   # bundle-root-relative (test lives at <bundle>/tests/); works in monorepo + public
UPD="${SG}/bin/ias-git-server-update.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-server-update.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---- fixtures: a fake forgejo binary + a fake release "server" served by a shadowed curl ----
BINDIR="$WORK/bin"        # holds fake system tools (forgejo, curl) on PATH
SRV="$WORK/srv"           # local "download server" root (files served by fake curl)
mkdir -p "$BINDIR" "$SRV"

# fake forgejo binary: prints a version we control via FAKE_FORGEJO_VERSION
cat > "$BINDIR/forgejo" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  echo "Forgejo version ${FAKE_FORGEJO_VERSION:-9.0.2}+gitea-1.22.0 built with go1.22"
  exit 0
fi
exit 0
EOF
chmod +x "$BINDIR/forgejo"

# fake curl: maps an https URL to a file under $SRV by stripping the scheme+host.
# Supports the subset of flags the tool passes (--fail --location --proto ... --output <f> -- <url>).
# Returns non-zero (like curl --fail) when the mapped fixture file does not exist.
cat > "$BINDIR/curl" <<EOF
#!/usr/bin/env bash
SRV_ROOT="$SRV"
out=""
url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --output) out="\$2"; shift 2 ;;
    -o) out="\$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --) shift; url="\$1"; shift ;;
    http*://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
# strip scheme://host/ -> path under SRV_ROOT
path="\${url#*://}"
path="\${path#*/}"
src="\${SRV_ROOT}/\${path}"
if [ ! -e "\$src" ]; then
  echo "fake-curl: 404 \$url" >&2
  exit 22
fi
if [ -n "\$out" ]; then cp "\$src" "\$out"; else cat "\$src"; fi
exit 0
EOF
chmod +x "$BINDIR/curl"

# build a fake release tree at version 9.0.3 for linux-amd64 (arch may differ; we pin --to + set arch via fixture)
ARCH="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
mkrelease() {
  local ver="$1"
  local d="$SRV/forgejo/$ver"
  mkdir -p "$d"
  printf 'FAKE-FORGEJO-BINARY-%s\n' "$ver" > "$d/forgejo-${ver}-linux-${ARCH}"
  # good sha256
  ( cd "$d" && sha256sum "forgejo-${ver}-linux-${ARCH}" > "forgejo-${ver}-linux-${ARCH}.sha256" )
  # placeholder .asc (GPG is mocked off in these tests via dry-run stopping before gpg on sha-fail path;
  # for the dry-run-success path we do not have a real signature, so those tests target --check + tamper)
  printf 'FAKE-ASC\n' > "$d/forgejo-${ver}-linux-${ARCH}.asc"
}
mkrelease 9.0.3
# base dir listing (for resolve_latest_stable) -- our fake curl serves the dir index file if present
printf '9.0.2\n9.0.3\n' > "$SRV/forgejo/index.html"
# resolve_latest_stable fetches FORGEJO_DL_BASE + "/" ; map that to the index file
mkdir -p "$SRV/forgejo"
cp "$SRV/forgejo/index.html" "$SRV/forgejo/" 2>/dev/null || true

export PATH="$BINDIR:$PATH"
export FORGEJO_BIN="$BINDIR/forgejo"
export FORGEJO_DL_BASE="https://dl.example.invalid/forgejo"
export FORGEJO_SERVICE="nonexistent-forgejo-test.service"
export BACKUP_SCRIPT=""   # never run a real backup

echo "== test 0: tool's own --self-test (pure logic) =="
if bash "$UPD" --self-test > "$WORK/selftest.out" 2>&1; then
  n="$(grep -oE '[0-9]+ passed' "$WORK/selftest.out" | head -1)"
  ok "built-in --self-test all green (${n})"
else
  bad "built-in --self-test failed"; cat "$WORK/selftest.out"
fi

echo "== test 1: --check idempotent no-op when installed == target -> exit 0 =="
FAKE_FORGEJO_VERSION=9.0.3 bash "$UPD" --check --to 9.0.3 > "$WORK/c1.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q "already up to date" "$WORK/c1.out"; then
  ok "installed==target reports up-to-date (exit 0)"
else
  bad "expected up-to-date exit 0 (got rc=$rc)"; cat "$WORK/c1.out"
fi

echo "== test 2: --check update-available when target > installed -> exit 10 =="
FAKE_FORGEJO_VERSION=9.0.2 bash "$UPD" --check --to 9.0.3 > "$WORK/c2.out" 2>&1
rc=$?
if [ "$rc" -eq 10 ] && grep -q "UPDATE AVAILABLE" "$WORK/c2.out"; then
  ok "target>installed reports update-available (exit 10)"
else
  bad "expected update-available exit 10 (got rc=$rc)"; cat "$WORK/c2.out"
fi

echo "== test 3: dry-run (no --apply) makes NO changes to the installed binary =="
before="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
# dry-run will download + sha-check + attempt gpg; gpg will fail on the fake .asc, but that is AFTER
# sha256 passed and BEFORE any swap -> still zero changes to the binary. Assert binary is untouched
# and the run never reached an --apply swap.
FAKE_FORGEJO_VERSION=9.0.2 bash "$UPD" --to 9.0.3 > "$WORK/d3.out" 2>&1 || true
after="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
if [ "$before" = "$after" ]; then
  ok "dry-run left the installed binary byte-identical (no swap)"
else
  bad "dry-run MODIFIED the installed binary -- must never happen"
fi
if ! grep -q "UPDATE COMPLETE" "$WORK/d3.out"; then
  ok "dry-run never reported a completed swap"
else
  bad "dry-run reported UPDATE COMPLETE -- must require --apply"
fi

echo "== test 4: TAMPERED checksum causes non-zero abort (no swap) =="
# corrupt the published .sha256 so the downloaded binary will not match
badver=9.0.3
echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  forgejo-${badver}-linux-${ARCH}" \
  > "$SRV/forgejo/${badver}/forgejo-${badver}-linux-${ARCH}.sha256"
before="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
FAKE_FORGEJO_VERSION=9.0.2 bash "$UPD" --to "$badver" --apply > "$WORK/t4.out" 2>&1
rc=$?
after="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
if [ "$rc" -ne 0 ] && grep -qi "sha256 MISMATCH" "$WORK/t4.out"; then
  ok "tampered checksum aborts non-zero with sha256 MISMATCH"
else
  bad "tampered checksum should abort with sha256 MISMATCH (got rc=$rc)"; cat "$WORK/t4.out"
fi
if [ "$before" = "$after" ]; then
  ok "tampered checksum: installed binary left untouched (no swap)"
else
  bad "tampered checksum: binary was modified -- HARD GATE FAILURE"
fi
# restore good sha for hygiene
( cd "$SRV/forgejo/${badver}" && sha256sum "forgejo-${badver}-linux-${ARCH}" > "forgejo-${badver}-linux-${ARCH}.sha256" )

echo "== test 5: argparse rejects an unknown option -> exit 2 =="
bash "$UPD" --frobnicate > "$WORK/a5.out" 2>&1
rc=$?
if [ "$rc" -eq 2 ] && grep -qi "unknown option" "$WORK/a5.out"; then
  ok "unknown option rejected with exit 2"
else
  bad "unknown option should exit 2 (got rc=$rc)"; cat "$WORK/a5.out"
fi

echo "== test 6: --print-units emits both systemd unit + timer text =="
bash "$UPD" --print-units > "$WORK/u6.out" 2>&1
if grep -q "forgejo-update.service" "$WORK/u6.out" && grep -q "forgejo-update.timer" "$WORK/u6.out"; then
  ok "--print-units emits service + timer unit text"
else
  bad "--print-units missing unit/timer text"; cat "$WORK/u6.out"
fi

# ---- real-GPG tests: prove the signature HARD GATE genuinely verifies (not a no-op) ----
if command -v gpg >/dev/null 2>&1; then
  GNUPGHOME_TEST="$WORK/gpgtest"
  mkdir -p "$GNUPGHOME_TEST"
  chmod 700 "$GNUPGHOME_TEST"
  # generate a throwaway "trusted" signing key + an "attacker" key, both unattended
  cat > "$WORK/keyparams-good" <<'EOF'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Name-Real: Fake Forgejo Release
Name-Email: release@example.invalid
Expire-Date: 0
%commit
EOF
  cat > "$WORK/keyparams-bad" <<'EOF'
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Name-Real: Attacker
Name-Email: evil@example.invalid
Expire-Date: 0
%commit
EOF
  GNUPGHOME="$GNUPGHOME_TEST" gpg --batch --gen-key "$WORK/keyparams-good" >/dev/null 2>&1
  GNUPGHOME="$GNUPGHOME_TEST" gpg --batch --gen-key "$WORK/keyparams-bad"  >/dev/null 2>&1
  GOOD_FPR="$(GNUPGHOME="$GNUPGHOME_TEST" gpg --batch --with-colons --fingerprint release@example.invalid | awk -F: '$1=="fpr"{print $10; exit}')"
  BAD_FPR="$(GNUPGHOME="$GNUPGHOME_TEST" gpg --batch --with-colons --fingerprint evil@example.invalid | awk -F: '$1=="fpr"{print $10; exit}')"
  # export the GOOD public key to the fake key URL location
  KEYPATH="keys/forgejo-signing-key.gpg"
  mkdir -p "$SRV/$(dirname "$KEYPATH")"
  GNUPGHOME="$GNUPGHOME_TEST" gpg --batch --export --armor release@example.invalid > "$SRV/$KEYPATH"
  export FORGEJO_KEY_URL="https://keyserver.example.invalid/${KEYPATH}"

  gver=9.0.3
  binf="$SRV/forgejo/${gver}/forgejo-${gver}-linux-${ARCH}"
  # ensure good sha (restored above) and sign the binary with the GOOD key
  GNUPGHOME="$GNUPGHOME_TEST" gpg --batch --yes --armor --detach-sign -u release@example.invalid \
    -o "${binf}.asc" "$binf" >/dev/null 2>&1

  echo "== test 7: real GPG signature from PINNED key -> dry-run VERIFIES, no swap =="
  before="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
  FAKE_FORGEJO_VERSION=9.0.2 FORGEJO_SIGNING_FPR="$GOOD_FPR" bash "$UPD" --to "$gver" > "$WORK/g7.out" 2>&1
  rc=$?
  after="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
  if [ "$rc" -eq 0 ] && grep -qi "GPG signature OK" "$WORK/g7.out" && grep -qi "DRY-RUN OK" "$WORK/g7.out"; then
    ok "valid signature from pinned key verifies in dry-run"
  else
    bad "valid signature should verify in dry-run (rc=$rc)"; cat "$WORK/g7.out"
  fi
  if [ "$before" = "$after" ]; then
    ok "dry-run with valid signature still made NO changes (needs --apply)"
  else
    bad "dry-run modified the binary -- must never happen"
  fi

  echo "== test 8: signature from an UNPINNED key -> abort (fingerprint mismatch) =="
  before="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
  # pin the ATTACKER fpr while the served key is the GOOD one -> imported key != pinned -> abort
  FAKE_FORGEJO_VERSION=9.0.2 FORGEJO_SIGNING_FPR="$BAD_FPR" bash "$UPD" --to "$gver" --apply > "$WORK/g8.out" 2>&1
  rc=$?
  after="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
  if [ "$rc" -ne 0 ] && grep -qi "FINGERPRINT MISMATCH" "$WORK/g8.out"; then
    ok "unpinned/served-key fingerprint mismatch aborts non-zero"
  else
    bad "fingerprint mismatch should abort (rc=$rc)"; cat "$WORK/g8.out"
  fi
  if [ "$before" = "$after" ]; then
    ok "fingerprint mismatch: binary untouched (no swap)"
  else
    bad "fingerprint mismatch modified the binary -- HARD GATE FAILURE"
  fi

  echo "== test 9: TAMPERED binary with valid-key signature -> sha256 gate aborts first =="
  # append a byte to the served binary WITHOUT re-signing / re-hashing -> sha256 must fail
  cp "$binf" "$WORK/binf.orig"
  printf 'X' >> "$binf"
  before="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
  FAKE_FORGEJO_VERSION=9.0.2 FORGEJO_SIGNING_FPR="$GOOD_FPR" bash "$UPD" --to "$gver" --apply > "$WORK/g9.out" 2>&1
  rc=$?
  after="$(sha256sum "$FORGEJO_BIN" | awk '{print $1}')"
  if [ "$rc" -ne 0 ] && grep -qi "sha256 MISMATCH" "$WORK/g9.out"; then
    ok "tampered binary caught by sha256 gate before GPG (abort)"
  else
    bad "tampered binary should fail sha256 (rc=$rc)"; cat "$WORK/g9.out"
  fi
  if [ "$before" = "$after" ]; then
    ok "tampered binary: system binary untouched"
  else
    bad "tampered binary modified the system binary -- HARD GATE FAILURE"
  fi
  cp "$WORK/binf.orig" "$binf"  # restore
else
  echo "== tests 7-9 SKIPPED: gpg not available =="
fi

echo ""
echo "==================================="
echo "RESULT: ${PASS} passed, ${FAIL} failed"
echo "==================================="
[ "$FAIL" -eq 0 ]
