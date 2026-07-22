#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright 2026 VakeWorks AB
#
# ias-git-mirror-sync.sh -- force a Forgejo PULL-mirror to sync from its upstream NOW,
# instead of waiting for the periodic interval (default ~8h). The W3 (follow-copy)
# round-trip uses this: after a PR merges upstream, force the sovereign server's mirror
# to pull, then prove it arrived with `ias-git-verify.sh ... --expect-sha <merge-sha>`.
#
# It calls the Forgejo API: POST /api/v1/repos/<owner>/<repo>/mirror-sync
#
# USAGE:
#   ias-git-mirror-sync.sh <owner>/<repo> [--base-url URL] [--token-env VAR]
#
# OPTIONS:
#   --base-url URL     Forgejo base URL (default https://git.example.org). Set to your server.
#   --token-env VAR    env var holding the API token (default GITVW_FORGEJO_TOKEN). The token
#                      is sent in an Authorization header and is NEVER printed or put in a URL.
#
# EXIT: 0 = sync accepted (HTTP 200/202). 1 = API returned another status. 2 = usage error.
#
# NOTE: mirror-sync is ASYNC -- Forgejo queues the pull. Poll the mirror's ref
#       (git ls-remote) or just run ias-git-verify.sh afterwards until it matches.
set -uo pipefail
SELF="$(basename "$0")"
die() { echo "${SELF}: ERROR: $*" >&2; exit 2; }

BASE_URL="https://git.example.org"
TOKEN_ENV="GITVW_FORGEJO_TOKEN"
SLUG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) [ $# -ge 2 ] || die "--base-url needs a value"; BASE_URL="$2"; shift 2 ;;
    --base-url=*) BASE_URL="${1#*=}"; shift ;;
    --token-env) [ $# -ge 2 ] || die "--token-env needs a value"; TOKEN_ENV="$2"; shift 2 ;;
    --token-env=*) TOKEN_ENV="${1#*=}"; shift ;;
    -h|--help) sed -n '8,27p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) SLUG="$1"; shift ;;
  esac
done

[ -n "$SLUG" ] || die "usage: ${SELF} <owner>/<repo> [--base-url URL] [--token-env VAR]"
case "$SLUG" in */*) : ;; *) die "expected <owner>/<repo>, got '${SLUG}'" ;; esac

# token from the environment only (never argv, never printed)
TOKEN="${!TOKEN_ENV:-}"
[ -n "$TOKEN" ] || die "token env var \$${TOKEN_ENV} is empty -- EXPORT it first so this process inherits it: 'set -a; source ~/.config/openearth/tokens.env; set +a' (a plain 'source' without export does not reach a child process)"

# F4: refuse a non-https base-url -> a bearer token must never ride over plaintext.
case "$BASE_URL" in
  https://*) : ;;
  *) die "refusing non-https --base-url '${BASE_URL}' (the API token would ride in cleartext). Use https://." ;;
esac
URL="${BASE_URL%/}/api/v1/repos/${SLUG}/mirror-sync"
echo "== mirror-sync: ${SLUG} @ ${BASE_URL%/} =="
code="$(curl -sS --proto '=https' --tlsv1.2 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: token ${TOKEN}" "$URL")" \
  || die "curl failed reaching ${BASE_URL%/} (network / TLS)"
echo "  HTTP ${code}"
case "$code" in
  200|202) echo "OK: sync queued (async). Verify with: ias-git-verify.sh <upstream> ${BASE_URL%/}/${SLUG}.git --ignore-refs 'refs/pull/*' --expect-sha <merge-sha>"; exit 0 ;;
  401|403) die "auth rejected (HTTP ${code}) -- check \$${TOKEN_ENV} scope" ;;
  404) die "repo not found or not a mirror (HTTP 404): ${SLUG}" ;;
  *) echo "FAIL: unexpected HTTP ${code}" >&2; exit 1 ;;
esac
