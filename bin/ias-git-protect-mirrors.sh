#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright 2026 VakeWorks AB
#
# ias-git-protect-mirrors.sh -- protect `main` on our PUBLIC MIRROR repos (GitHub + GitLab +
# Codeberg) so HUMANS cannot commit/PR directly to main (must branch + PR/MR), WITHOUT
# breaking git.vw's push-mirror force-sync.
#
# THE TRAP: these are PUSH-MIRRORS. git.vw (Forgejo) force-pushes `main` to each forge every
# sync, authenticating as the token owner (the org owner/admin). If branch protection blocks
# force-push to main, the sync BREAKS and the mirror silently freezes. So protection must
# ALLOW the mirror-sync push identity (the owner/admin) to force-push, while blocking everyone
# else + requiring PRs.
#
#   GitHub  : PR required + enforce_admins:false (admin bypass) -> the admin PAT the mirror
#             uses can still git-push --force; non-admins are blocked and must open a PR.
#   GitLab  : push_access_level=40 (Maintainer) + merge_access_level=40 + allow_force_push:true
#             -> Owner (level 50, the mirror push) can force-push; regular members (< Maintainer)
#             cannot push and must open an MR.
#   Codeberg: enable_push + push-whitelist ONLY the owner + require PR for merges -> the mirror
#             (owner) push works; everyone else is blocked from direct push.
#
# USAGE:
#   ias-git-protect-mirrors.sh <github owner/repo> <gitlab group/path> <codeberg owner/repo> [plan|apply|verify]
#   (default MODE = plan, a dry-run that prints what it WOULD set on each forge)
#
#   plan    print the per-forge protection that WOULD be applied (no writes)
#   apply   apply the protection on all three forges
#   verify  trigger a git.vw push_mirrors-sync, wait, then read `main` on git.vw + all 3
#           mirrors and confirm ALL FOUR SHAs still match (proves protection did not break sync)
#
# TOKENS (ENV-ONLY; never on argv, never printed):
#   GITHUB_TOKEN          GitHub PAT (admin on the repo)                 (Authorization: Bearer)
#   GITLAB_TOKEN          GitLab PAT (Owner/Maintainer on the project)   (PRIVATE-TOKEN)
#   CODEBERG_TOKEN        Codeberg/Forgejo PAT (repo admin)              (Authorization: token)
#   GITVW_FORGEJO_TOKEN   git.vw Forgejo PAT (to trigger push_mirrors-sync, verify mode)
# Export them first:  set -a; source ~/.config/openearth/tokens.env; set +a
#
# OWNER IDENTITY (whom to allow force-push): auto-derived from each token's /user endpoint
# unless overridden by GH_OWNER_LOGIN / CODEBERG_OWNER_LOGIN env (GitLab uses access-level, no login).
#
# GITVW: the canonical Forgejo owner/repo for the push_mirrors-sync trigger defaults to the
# GitHub owner/repo (they match for our mirror sets); override with GITVW_SLUG=owner/repo.
#
# EXIT: 0 = ok. 1 = a forge apply failed OR verify found a broken/reverted sync. 2 = usage.
set -uo pipefail

SELF="$(basename "$0")"
die() { echo "${SELF}: ERROR: $*" >&2; exit 2; }
# redact: strip any token-ish / password-ish field values from text before printing
redact() { sed -E 's/(token|password|private-token|authorization|secret)("?[[:space:]]*[:=][[:space:]]*"?)[^",} ]*/\1\2***/gI'; }

GH_SLUG="${1:-}"; GL_SLUG="${2:-}"; CB_SLUG="${3:-}"; MODE="${4:-plan}"
[ -n "$GH_SLUG" ] && [ -n "$GL_SLUG" ] && [ -n "$CB_SLUG" ] || \
  die "usage: ${SELF} <github owner/repo> <gitlab group/path> <codeberg owner/repo> [plan|apply|verify]"
case "$MODE" in plan|apply|verify) : ;; *) die "MODE must be plan|apply|verify (got '$MODE')" ;; esac
for s in "$GH_SLUG" "$GL_SLUG" "$CB_SLUG"; do
  case "$s" in */*) : ;; *) die "expected owner/repo form, got '$s'" ;; esac
done

BRANCH="main"
GH_API="https://api.github.com"
GL_API="https://gitlab.com/api/v4"
CB_API="https://codeberg.org/api/v1"
# Your sovereign Forgejo API base. Override for your deployment, e.g.
# GITVW_API=https://git.example.org/api/v1 (default is a neutral placeholder).
GITVW_API="${GITVW_API:-https://git.example.org/api/v1}"
GITVW_SLUG="${GITVW_SLUG:-$GH_SLUG}"

RESP="$(mktemp)"; trap 'rm -f "$RESP"' EXIT   # private temp (0600), auto-cleaned

# ---- helper: resolve the login the given token authenticates as (for force-push whitelist) ----
gh_owner_login() {
  if [ -n "${GH_OWNER_LOGIN:-}" ]; then printf '%s' "$GH_OWNER_LOGIN"; return; fi
  curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN:?set GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" \
    "${GH_API}/user" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("login",""))'
}
cb_owner_login() {
  if [ -n "${CODEBERG_OWNER_LOGIN:-}" ]; then printf '%s' "$CODEBERG_OWNER_LOGIN"; return; fi
  curl -sS -H "Authorization: token ${CODEBERG_TOKEN:?set CODEBERG_TOKEN}" \
    "${CB_API}/user" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("login",""))'
}

# ---- JSON bodies (built by python3 from the ENVIRONMENT; never string-concatenated) ----
gh_body() {
  python3 -c '
import json
# require a PR before merging main; enforce_admins:false so the admin PAT the push-mirror uses
# can still force-push directly (admin bypass), while non-admins are blocked and must open a PR.
print(json.dumps({
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": False,
    "require_code_owner_reviews": False,
    "required_approving_review_count": 1
  },
  "enforce_admins": False,
  "required_status_checks": None,
  "restrictions": None,
  "allow_force_pushes": False,
  "allow_deletions": False
}))'
}
gl_body() {
  # push/merge at Maintainer(40): Owner(50, the mirror) can force-push; members < Maintainer cannot
  # push and must open an MR to merge. allow_force_push:true is what lets the sync force-push main.
  BR="$BRANCH" python3 -c '
import json,os
print(json.dumps({
  "name": os.environ["BR"],
  "push_access_level": 40,
  "merge_access_level": 40,
  "allow_force_push": True
}))'
}
cb_body() {
  # whitelist ONLY the owner for push (so the mirror push works); everyone else blocked from
  # direct push; require PR for others to change main.
  BR="$BRANCH" OWNER="$1" python3 -c '
import json,os
print(json.dumps({
  "branch_name": os.environ["BR"],
  "enable_push": True,
  "enable_push_whitelist": True,
  "push_whitelist_usernames": [os.environ["OWNER"]],
  "push_whitelist_deploy_keys": False,
  "require_signed_commits": False,
  "block_on_rejected_reviews": True,
  "block_on_outdated_branch": False,
  "enable_merge_whitelist": False,
  "required_approvals": 0
}))'
}

# =====================================================================================
# PLAN
# =====================================================================================
plan() {
  local ghlogin cblogin
  ghlogin="$(gh_owner_login)"; cblogin="$(cb_owner_login)"
  echo "== PLAN: protect '${BRANCH}' on the mirror set =="
  echo
  echo "-- GitHub ${GH_SLUG} --"
  echo "  PUT ${GH_API}/repos/${GH_SLUG}/branches/${BRANCH}/protection"
  echo "  intent: require PR before merge; block direct push by non-admins;"
  echo "          enforce_admins=false so the admin PAT (login: ${ghlogin:-<token owner>}) the"
  echo "          push-mirror uses can still force-push main. allow_force_pushes=false (admin bypass only)."
  echo "  body: $(gh_body)"
  echo
  echo "-- GitLab ${GL_SLUG} --"
  echo "  POST ${GL_API}/projects/<enc>/protected_branches"
  echo "  intent: push+merge at Maintainer(40); Owner(50, the mirror push) can force-push;"
  echo "          members below Maintainer cannot push and must open an MR. allow_force_push=true."
  echo "  body: $(gl_body)"
  echo
  echo "-- Codeberg ${CB_SLUG} --"
  echo "  POST ${CB_API}/repos/${CB_SLUG}/branch_protections"
  echo "  intent: push-whitelist ONLY owner '${cblogin:-<token owner>}' (the mirror push);"
  echo "          everyone else blocked from direct push; PR required for others."
  echo "  body: $(cb_body "${cblogin:-OWNER}")"
  echo
  echo "(dry-run; no writes. Run 'apply' to set, then 'verify' to prove the sync survives.)"
}

# =====================================================================================
# APPLY  (per-forge; sets APPLY_FAIL=1 on any failure but continues so verify runs)
# =====================================================================================
APPLY_FAIL=0
apply_github() {
  echo "-- apply GitHub ${GH_SLUG} --"
  local code
  code="$(gh_body | curl -sS -o "$RESP" -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer ${GITHUB_TOKEN:?set GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "${GH_API}/repos/${GH_SLUG}/branches/${BRANCH}/protection" --data-binary @-)"
  if [ "$code" = "200" ]; then echo "  OK  (HTTP 200) branch protection set"; else
    echo "  ERR (HTTP ${code}): $(redact < "$RESP" | head -c 300)"; APPLY_FAIL=1; fi
}
apply_gitlab() {
  echo "-- apply GitLab ${GL_SLUG} --"
  local enc code
  enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$GL_SLUG")"
  # POST fails if a rule for main already exists -> delete first (idempotent apply)
  curl -sS -o /dev/null -X DELETE -H "PRIVATE-TOKEN: ${GITLAB_TOKEN:?set GITLAB_TOKEN}" \
    "${GL_API}/projects/${enc}/protected_branches/${BRANCH}" || true
  code="$(gl_body | curl -sS -o "$RESP" -w '%{http_code}' -X POST \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    "${GL_API}/projects/${enc}/protected_branches" --data-binary @-)"
  if [ "$code" = "200" ] || [ "$code" = "201" ]; then echo "  OK  (HTTP ${code}) protected branch set"; else
    echo "  ERR (HTTP ${code}): $(redact < "$RESP" | head -c 300)"; APPLY_FAIL=1; fi
}
apply_codeberg() {
  echo "-- apply Codeberg ${CB_SLUG} --"
  local login code
  login="$(cb_owner_login)"
  [ -n "$login" ] || { echo "  ERR could not resolve Codeberg owner login for push-whitelist"; APPLY_FAIL=1; return; }
  # delete any existing rule for main first (idempotent apply)
  curl -sS -o /dev/null -X DELETE -H "Authorization: token ${CODEBERG_TOKEN:?set CODEBERG_TOKEN}" \
    "${CB_API}/repos/${CB_SLUG}/branch_protections/${BRANCH}" || true
  code="$(cb_body "$login" | curl -sS -o "$RESP" -w '%{http_code}' -X POST \
    -H "Authorization: token ${CODEBERG_TOKEN}" \
    -H "Content-Type: application/json" \
    "${CB_API}/repos/${CB_SLUG}/branch_protections" --data-binary @-)"
  if [ "$code" = "200" ] || [ "$code" = "201" ]; then echo "  OK  (HTTP ${code}) branch protection set (push-whitelist: ${login})"; else
    echo "  ERR (HTTP ${code}): $(redact < "$RESP" | head -c 300)"; APPLY_FAIL=1; fi
}

# ---- revert helpers (used by verify's safety net) ----
revert_github()   { curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${GH_API}/repos/${GH_SLUG}/branches/${BRANCH}/protection"; }
revert_gitlab()   { local enc; enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$GL_SLUG")"; curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${GL_API}/projects/${enc}/protected_branches/${BRANCH}"; }
revert_codeberg() { curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: token ${CODEBERG_TOKEN}" "${CB_API}/repos/${CB_SLUG}/branch_protections/${BRANCH}"; }

# ---- SHA readers (main branch tip on each forge) ----
sha_gitvw()    { curl -sS -H "Authorization: token ${GITVW_FORGEJO_TOKEN:?set GITVW_FORGEJO_TOKEN}" "${GITVW_API}/repos/${GITVW_SLUG}/branches/${BRANCH}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("commit",{}).get("id",""))'; }
sha_github()   { curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "${GH_API}/repos/${GH_SLUG}/branches/${BRANCH}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("commit",{}).get("sha",""))'; }
sha_gitlab()   { local enc; enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$GL_SLUG")"; curl -sS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${GL_API}/projects/${enc}/repository/branches/${BRANCH}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("commit",{}).get("id",""))'; }
sha_codeberg() { curl -sS -H "Authorization: token ${CODEBERG_TOKEN}" "${CB_API}/repos/${CB_SLUG}/branches/${BRANCH}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("commit",{}).get("id",""))'; }

# =====================================================================================
# VERIFY  (trigger push_mirrors-sync -> wait -> compare 4 SHAs -> revert broken forges)
# =====================================================================================
verify() {
  echo "== VERIFY: trigger git.vw push_mirrors-sync + confirm 4 SHAs match =="
  local base; base="$(sha_gitvw)"
  [ -n "$base" ] || die "could not read git.vw main SHA (check GITVW_FORGEJO_TOKEN / GITVW_SLUG=${GITVW_SLUG})"
  echo "  git.vw main (source of truth): ${base}"
  echo "  triggering: POST ${GITVW_API}/repos/${GITVW_SLUG}/push_mirrors-sync"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: token ${GITVW_FORGEJO_TOKEN:?set GITVW_FORGEJO_TOKEN}" \
    "${GITVW_API}/repos/${GITVW_SLUG}/push_mirrors-sync")"
  echo "  push_mirrors-sync HTTP ${code}"
  case "$code" in 200|202) : ;; *) echo "  WARN: push_mirrors-sync returned HTTP ${code} (proceeding to SHA check anyway)";; esac

  # poll each mirror until it matches the source (push-mirror is async), up to ~120s
  local waited=0 max=120 step=8
  local rc=1
  while [ "$waited" -lt "$max" ]; do
    local gh gl cb
    gh="$(sha_github)"; gl="$(sha_gitlab)"; cb="$(sha_codeberg)"
    if [ "$gh" = "$base" ] && [ "$gl" = "$base" ] && [ "$cb" = "$base" ]; then rc=0; break; fi
    sleep "$step"; waited=$(( waited + step ))
  done

  local gh gl cb; gh="$(sha_github)"; gl="$(sha_gitlab)"; cb="$(sha_codeberg)"
  echo
  echo "  git.vw   : ${base}"
  echo "  GitHub   : ${gh}   $( [ "$gh" = "$base" ] && echo MATCH || echo MISMATCH )"
  echo "  GitLab   : ${gl}   $( [ "$gl" = "$base" ] && echo MATCH || echo MISMATCH )"
  echo "  Codeberg : ${cb}   $( [ "$cb" = "$base" ] && echo MATCH || echo MISMATCH )"
  echo

  local broke=0
  if [ "$gh" != "$base" ]; then
    echo "  INCOMPATIBLE config on GitHub -- sync did not converge. Reverting GitHub protection..."
    echo "    DELETE protection -> HTTP $(revert_github)"
    echo "    -> GitHub protection REVERTED; needs manual tuning."
    broke=1
  fi
  if [ "$gl" != "$base" ]; then
    echo "  INCOMPATIBLE config on GitLab -- sync did not converge. Reverting GitLab protection..."
    echo "    DELETE protection -> HTTP $(revert_gitlab)"
    echo "    -> GitLab protection REVERTED; needs manual tuning."
    broke=1
  fi
  if [ "$cb" != "$base" ]; then
    echo "  INCOMPATIBLE config on Codeberg -- sync did not converge. Reverting Codeberg protection..."
    echo "    DELETE protection -> HTTP $(revert_codeberg)"
    echo "    -> Codeberg protection REVERTED; needs manual tuning."
    broke=1
  fi

  if [ "$rc" -eq 0 ] && [ "$broke" -eq 0 ]; then
    echo "VERIFIED: all 4 SHAs match (${base}) after sync -- protection did NOT break the mirror."
    return 0
  fi
  echo "RESULT: one or more forges reverted (protection incompatible with push-mirror sync)."
  echo "        Re-run 'verify' to confirm the reverted forge(s) re-converge with git.vw."
  return 1
}

case "$MODE" in
  plan)  plan ;;
  apply) apply_github; apply_gitlab; apply_codeberg
         if [ "$APPLY_FAIL" -eq 0 ]; then echo "== apply OK on all three forges. Run 'verify' NOW to prove the sync survives. =="; else
           echo "== apply had failures (see ERR above). Run 'verify' to check sync + revert any broken forge. =="; exit 1; fi ;;
  verify) verify ;;
esac
