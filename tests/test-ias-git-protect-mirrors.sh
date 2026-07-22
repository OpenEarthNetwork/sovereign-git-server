#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright 2026 VakeWorks AB
#
# Offline / mocked test for ias-git-protect-mirrors.sh. NO network. Asserts:
#   (1) plan mode emits the correct per-forge ENDPOINT + METHOD strings,
#   (2) the per-forge JSON BODIES have the load-bearing fields with the right values
#       (GitHub PR-required + enforce_admins:false; GitLab push/merge 40 + allow_force_push;
#        Codeberg push-whitelist owner + enable_push),
#   (3) verify mode compares FOUR SHAs (git.vw + 3 mirrors) and reverts a mismatching forge.
#
# It stubs curl (via PATH shim) so no real API is hit. plan mode calls curl only for /user
# login resolution -> the shim returns a fixed login. verify mode calls curl for the sync
# trigger + 4 branch reads -> the shim returns a scripted set of SHAs to exercise MATCH and
# MISMATCH+REVERT paths.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="${HERE}/../bin/ias-git-protect-mirrors.sh"
[ -f "$TOOL" ] || { echo "FAIL: tool not found at $TOOL"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
has()  { grep -qF -- "$2" "$1" && ok "$3" || bad "$3"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"

# ---- curl shim: dispatch on the URL (last arg) + emit deterministic JSON to a fixed file ----
# SHA_MODE selects the verify scenario: "match" => all mirrors == source; "gh_mismatch" =>
# GitHub lags (forces a revert).
cat > "$BIN/curl" <<'SHIM'
#!/usr/bin/env bash
# minimal curl stand-in: find the URL (last non-flag arg), print a canned body OR http_code.
url=""; want_code=0; outfile=""
prev=""
for a in "$@"; do
  case "$prev" in -o) outfile="$a";; -w) [ "$a" = '%{http_code}' ] && want_code=1;; esac
  case "$a" in http*://*) url="$a";; esac
  prev="$a"
done
emit() { if [ -n "$outfile" ] && [ "$outfile" != "/dev/null" ]; then printf '%s' "$1" > "$outfile"; else printf '%s' "$1"; fi; }
BASE="7ffe3cb9c3e97bc319136b62a69c90593e1dfe0d"
GH="$BASE"
case "${SHA_MODE:-match}" in gh_mismatch) GH="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef";; esac
case "$url" in
  *api.github.com/user)                 emit '{"login":"example-gh-owner"}'; [ "$want_code" = 1 ] && echo 200; exit 0;;
  *codeberg.org/api/v1/user)            emit '{"login":"example-owner"}';  [ "$want_code" = 1 ] && echo 200; exit 0;;
  *git.example.org/*/branches/main)      emit "{\"commit\":{\"id\":\"$BASE\"}}"; [ "$want_code" = 1 ] && echo 200; exit 0;;
  *git.example.org/*/push_mirrors-sync)  emit ''; [ "$want_code" = 1 ] && echo 200; exit 0;;
  *api.github.com/*/branches/main)      emit "{\"commit\":{\"sha\":\"$GH\"}}"; [ "$want_code" = 1 ] && echo 200; exit 0;;
  *gitlab.com/*/repository/branches/main) emit "{\"commit\":{\"id\":\"$BASE\"}}"; [ "$want_code" = 1 ] && echo 200; exit 0;;
  *codeberg.org/*/branches/main)        emit "{\"commit\":{\"id\":\"$BASE\"}}"; [ "$want_code" = 1 ] && echo 200; exit 0;;
  *branch_protections/main|*protected_branches/main|*protection) emit ''; [ "$want_code" = 1 ] && echo 204; exit 0;;
  *) emit ''; [ "$want_code" = 1 ] && echo 200; exit 0;;
esac
SHIM
chmod +x "$BIN/curl"

export GITHUB_TOKEN=x GITLAB_TOKEN=x CODEBERG_TOKEN=x GITVW_FORGEJO_TOKEN=x
GH=OpenEarthNetwork/openearth-gryph
GL=openearthnetwork/openearth-gryph
CB=OpenEarthNetwork/openearth-gryph

echo "== TEST 1: plan endpoints + methods =="
PLAN="$WORK/plan.txt"
PATH="$BIN:$PATH" bash "$TOOL" "$GH" "$GL" "$CB" plan > "$PLAN" 2>&1
has "$PLAN" "PUT https://api.github.com/repos/${GH}/branches/main/protection" "GitHub endpoint+PUT"
has "$PLAN" "POST https://gitlab.com/api/v4/projects/<enc>/protected_branches" "GitLab endpoint+POST"
has "$PLAN" "POST https://codeberg.org/api/v1/repos/${CB}/branch_protections" "Codeberg endpoint+POST"

echo "== TEST 2: per-forge JSON body load-bearing fields =="
# GitHub: PR required + enforce_admins false
has "$PLAN" '"required_pull_request_reviews"' "GitHub requires PR"
has "$PLAN" '"enforce_admins": false' "GitHub enforce_admins=false (admin/mirror bypass)"
has "$PLAN" '"allow_force_pushes": false' "GitHub allow_force_pushes=false (admin bypass only)"
# GitLab: maintainer push/merge + allow_force_push
has "$PLAN" '"push_access_level": 40' "GitLab push_access_level=40"
has "$PLAN" '"merge_access_level": 40' "GitLab merge_access_level=40"
has "$PLAN" '"allow_force_push": true' "GitLab allow_force_push=true (owner/mirror force-push)"
# Codeberg: push-whitelist owner + enable_push
has "$PLAN" '"enable_push": true' "Codeberg enable_push=true"
has "$PLAN" '"enable_push_whitelist": true' "Codeberg enable_push_whitelist=true"
has "$PLAN" '"push_whitelist_usernames": ["example-owner"]' "Codeberg whitelists owner example-owner"

echo "== TEST 3: verify compares 4 SHAs, all MATCH -> VERIFIED =="
V1="$WORK/verify_match.txt"
SHA_MODE=match PATH="$BIN:$PATH" bash "$TOOL" "$GH" "$GL" "$CB" verify > "$V1" 2>&1 || true
has "$V1" "git.vw" "verify reads git.vw SHA (source)"
has "$V1" "GitHub" "verify reads GitHub SHA"
has "$V1" "GitLab" "verify reads GitLab SHA"
has "$V1" "Codeberg" "verify reads Codeberg SHA"
has "$V1" "push_mirrors-sync" "verify triggers push_mirrors-sync"
has "$V1" "VERIFIED: all 4 SHAs match" "verify PASS path (all 4 match)"

echo "== TEST 4: verify with GitHub lagging -> REVERT GitHub =="
V2="$WORK/verify_mismatch.txt"
SHA_MODE=gh_mismatch PATH="$BIN:$PATH" bash "$TOOL" "$GH" "$GL" "$CB" verify > "$V2" 2>&1 || true
has "$V2" "MISMATCH" "verify detects a mismatch"
has "$V2" "INCOMPATIBLE config on GitHub" "verify flags the incompatible forge"
has "$V2" "GitHub protection REVERTED" "verify reverts the broken forge"

echo
echo "RESULT: PASS=${PASS} FAIL=${FAIL}"
[ "$FAIL" -eq 0 ] || exit 1
