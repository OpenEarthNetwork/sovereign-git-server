#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ias-git-mirror-setup.sh -- configure per-repo PUSH-MIRRORS from your canonical Forgejo
# (git.example.org) OUT to GitHub + GitLab + Codeberg, using Forgejo's built-in push-mirror
# (so the canonical stays the origin and the public hosts are downstream reach-only reflections).
# ONLY public repos are mirrored; private (e.g. CLOUD-Act-sensitive) repos are NEVER mirrored out.
#
# Run against your Forgejo API (from anywhere that can reach it). DRY-RUN by default.
#
# USAGE:
#   FORGEJO_URL=https://git.example.org OWNER=OpenEarthNetwork REPO=sovereign-git-server \\
#     bash ias-git-mirror-setup.sh plan
#   ...same... bash ias-git-mirror-setup.sh apply        # actually create the mirrors (op-gated)
#
# TOKENS (ENV-ONLY; never on the CLI):
#   FORGEJO_TOKEN   Forgejo API token (scope: write:repository) for OWNER/REPO
#   GH_MIRROR_URL   GITLAB_MIRROR_URL   CODEBERG_MIRROR_URL   push target remote URLs (https)
#   GH_MIRROR_TOKEN GITLAB_MIRROR_TOKEN CODEBERG_MIRROR_TOKEN per-host push credentials (PAT)
# A host is skipped (with a note) if its URL/token pair is absent -> partial mirroring is fine.
set -uo pipefail

FORGEJO_URL="${FORGEJO_URL:-https://git.example.org}"
OWNER="${OWNER:?set OWNER (Forgejo org, e.g. OpenEarthNetwork)}"
REPO="${REPO:?set REPO}"
# F4: refuse a non-https FORGEJO_URL -> a bearer token must never ride over plaintext.
case "$FORGEJO_URL" in
  https://*) : ;;
  *) echo "${0##*/}: ERROR: refusing non-https FORGEJO_URL '${FORGEJO_URL}' (the API token would ride in cleartext). Use https://." >&2; exit 2 ;;
esac
API="${FORGEJO_URL%/}/api/v1/repos/${OWNER}/${REPO}/push_mirrors"
MODE="${1:-plan}"

hosts() { printf 'github %s %s\ngitlab %s %s\ncodeberg %s %s\n' \
  "${GH_MIRROR_URL:-}" "${GH_MIRROR_TOKEN:-}" \
  "${GITLAB_MIRROR_URL:-}" "${GITLAB_MIRROR_TOKEN:-}" \
  "${CODEBERG_MIRROR_URL:-}" "${CODEBERG_MIRROR_TOKEN:-}"; }

echo "== mirror-setup ${MODE}: ${OWNER}/${REPO} @ ${FORGEJO_URL} =="
RESP="$(mktemp)"; trap 'rm -f "$RESP"' EXIT   # private temp (0600), auto-cleaned; never a world-readable /tmp path
while read -r name url tok; do
  [ -z "$url" ] || [ -z "$tok" ] && { echo "  skip $name (no ${name^^}_MIRROR_URL / _TOKEN set)"; continue; }
  if [ "$MODE" = "plan" ]; then
    echo "  WOULD add push-mirror -> $name ($url) [interval 8h, sync-on-commit]"
    continue
  fi
  # apply: create the push-mirror via the Forgejo API (token via header; body built by a real JSON
  # encoder with url/tok passed through the ENVIRONMENT -- NEVER string-concatenated into JSON (a quote
  # or backslash in a mirror URL/PAT would otherwise break or field-smuggle the request) and NEVER on
  # the argv (would show in `ps`). python3 is already a bundle dependency.
  body=$(REMOTE_URL="$url" REMOTE_TOK="$tok" python3 -c 'import json,os; print(json.dumps({"remote_address":os.environ["REMOTE_URL"],"remote_username":"git","remote_password":os.environ["REMOTE_TOK"],"interval":"8h0m0s","sync_on_commit":True}))')
  code=$(printf '%s' "$body" | curl -sS --proto '=https' --tlsv1.2 -o "$RESP" -w '%{http_code}' -X POST "$API" \
    -H "Authorization: token ${FORGEJO_TOKEN:?set FORGEJO_TOKEN}" \
    -H 'Content-Type: application/json' --data-binary @-)
  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    echo "  OK  push-mirror -> $name"
  else
    # never print a raw response body that might echo the submitted token -> redact password-ish fields
    echo "  ERR $name (HTTP $code): $(sed -E 's/([Pp]assword"?[[:space:]]*[:=][[:space:]]*"?)[^",}]*/\1***/g' "$RESP" | head -c 200)"
  fi
done <<EOF
$(hosts)
EOF
echo "Done. (private repos are intentionally NOT mirrored; only run this for PUBLIC repos.)"
