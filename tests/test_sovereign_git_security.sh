#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Security regression tests for the sovereign-git bundle. Guards the red-team hardenings so a future edit
# cannot silently reintroduce a fixed hole. Behavioural where cheap; static-assertion otherwise (these
# scripts mostly do privileged/networked I/O that cannot be exercised in CI without a live forge).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG="$HERE/.."   # bundle-root-relative (test lives at <bundle>/tests/); works in monorepo + public
fail=0
ok(){ echo "ok   - $1"; }
no(){ echo "FAIL - $1"; fail=1; }

# --- M2: pull-contribution rejects a non-numeric PR and a bad forge (injection guard) ---
if bash "$SG/bin/ias-git-pull-contribution.sh" --forge github --pr 'evil;rm' --mirror-remote r >/dev/null 2>&1; then
  no "M2: non-numeric --pr should be rejected (exit!=0)"; else ok "M2: non-numeric --pr rejected"; fi
if bash "$SG/bin/ias-git-pull-contribution.sh" --forge 'bad/../x' --pr 1 --mirror-remote r >/dev/null 2>&1; then
  no "M2: bad --forge should be rejected"; else ok "M2: bad --forge rejected"; fi

# --- H1: mirror-setup builds JSON with a real encoder, never string-concatenation ---
grep -q 'json.dumps' "$SG/bin/ias-git-mirror-setup.sh" && ok "H1: mirror-setup uses json.dumps" || no "H1: mirror-setup json.dumps missing"

# --- H2: no fixed world-readable /tmp response file ---
grep -q '/tmp/mirror-resp.json' "$SG/bin/ias-git-mirror-setup.sh" && no "H2: fixed /tmp/mirror-resp.json still present" || ok "H2: mirror-setup uses mktemp (no fixed /tmp path)"

# --- C1: standup verifies the binary (sha256 + pinned GPG) with no comment-only bypass ---
grep -q 'FORGEJO_GPG_FINGERPRINT' "$SG/bin/ias-git-server-standup.sh" && ok "C1: pinned GPG fingerprint gate present" || no "C1: GPG fingerprint gate missing"
grep -q 'sha256sum' "$SG/bin/ias-git-server-standup.sh" && ok "C1: sha256 check present" || no "C1: sha256 check missing"
grep -qi 'Production: verify' "$SG/bin/ias-git-server-standup.sh" && no "C1: comment-only 'Production: verify' bypass still present" || ok "C1: bypass comment removed"

# --- M4: Forgejo hardening keys present ---
for k in DISABLE_GIT_HOOKS IMPORT_LOCAL_PATHS ALLOWED_HOST_LIST 'cron.update_checker'; do
  grep -q "$k" "$SG/bin/ias-git-server-standup.sh" && ok "M4: app.ini has $k" || no "M4: app.ini missing $k"
done

# --- H4: relay drives L1 with the CORRECT flag (--mirror-remote), not the dead --canonical-remote ---
grep -q -- '--mirror-remote' "$SG/relay/ias-git-relay.py" && ok "H4: relay uses --mirror-remote" || no "H4: relay --mirror-remote missing"
# check the code ATTRIBUTE (args.canonical_remote / argparse dest), not comments that may mention the old flag name
grep -q 'canonical_remote' "$SG/relay/ias-git-relay.py" && no "H4: dead canonical_remote arg still used" || ok "H4: obsolete canonical_remote removed"

# --- M1: pull-contribution validates contributor author before git commit --author ---
grep -q 'A-Za-z0-9._-' "$SG/bin/ias-git-pull-contribution.sh" && ok "M1: author LOGIN validated" || no "M1: author validation missing"

# --- M3: L1 scrubs credentials from git stderr ---
grep -q 's#(://)' "$SG/bin/ias-git-pull-contribution.sh" && ok "M3: L1 scrubs ://user:token@ from errors" || no "M3: L1 credential scrub missing"

# --- L4: relay writes state 0600 ---
grep -q '0o600' "$SG/relay/ias-git-relay.py" && ok "L4: relay state file 0600" || no "L4: relay state perms not tightened"

echo
if [ "$fail" -eq 0 ]; then echo "ALL SECURITY REGRESSION CHECKS PASS"; else echo "SECURITY REGRESSION FAILURES ABOVE"; fi
exit "$fail"
