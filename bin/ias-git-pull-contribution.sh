#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ias-git-pull-contribution.sh -- L1 inbound: fetch ONE contribution (PR/MR) from a public mirror into
# a canonical-side contrib/<forge>/pr-<N> branch for the maintainer to review + merge on the canonical
# (git.example.org). Forge-agnostic via the L2 adapters. No bot, no daemon -- a maintainer runs it.
#
# GOOD PATH (preferred): git fetch <mirror-remote> refs/pull|merge-requests/<N>/head. This preserves the
# contributor's commits, author identity, AND any DCO `Signed-off-by` VERBATIM (provenance intact).
#
# FALLBACK (--allow-patch): if the PR head ref is unfetchable (deleted/private fork -> 404; the contributor CR c1),
# download the API diff and `git apply` it onto a fresh contrib branch. CAVEAT: a flat API diff loses
# per-commit granularity AND the original Signed-off-by -> the maintainer must re-establish DCO manually.
# The fallback commit is attributed to the PR author (best-effort) with an Origin trailer.
#
# NOTHING outward: operates only on local fetch + a contrib/* branch. Never pushes, never touches main.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTERS="$SCRIPT_DIR/relay/forge_adapters.py"

FORGE="" ; PRN="" ; REPO="" ; REMOTE="" ; BASE_URL="" ; TOKEN_ENV="" ; ALLOW_PATCH=0

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  echo
  echo "Usage: ias-git-pull-contribution.sh --forge <github|gitlab|codeberg|forgejo> --pr <N> \\"
  echo "         --repo <owner/repo|group/path|id> --mirror-remote <git-remote-name> \\"
  echo "         [--base-url <api-base>] [--token-env <ENV_VAR>] [--allow-patch]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --forge) FORGE="$2"; shift 2 ;;
    --pr) PRN="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --mirror-remote) REMOTE="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --token-env) TOKEN_ENV="$2"; shift 2 ;;
    --allow-patch) ALLOW_PATCH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$FORGE" ] || [ -z "$PRN" ] || [ -z "$REMOTE" ]; then
  echo "error: --forge, --pr, --mirror-remote are required" >&2; usage; exit 2
fi
# M2: validate PR number + forge against strict charsets BEFORE they land in git refspecs, a branch name,
# and the python -c below -> prevents ref-name confusion (e.g. --pr ../../heads/main) + code/arg injection.
printf '%s' "$PRN"   | grep -Eq '^[0-9]+$'  || { echo "error: --pr must be a positive integer" >&2; exit 2; }
printf '%s' "$FORGE" | grep -Eq '^[a-z]+$'  || { echo "error: --forge must be lowercase letters (github|gitlab|codeberg|forgejo)" >&2; exit 2; }
if ! command -v git >/dev/null 2>&1; then echo "error: git not found" >&2; exit 2; fi

ADAPTER_ARGS=(--base-url "$BASE_URL")
[ -z "$BASE_URL" ] && ADAPTER_ARGS=()
[ -n "$TOKEN_ENV" ] && ADAPTER_ARGS+=(--token-env "$TOKEN_ENV")

REF="$(python3 "$ADAPTERS" ref "$FORGE" "" "$PRN" 2>/dev/null)"
if [ -z "$REF" ]; then echo "error: could not resolve PR ref for $FORGE #$PRN" >&2; exit 1; fi
CONTRIB="contrib/${FORGE}/pr-${PRN}"

echo "== L1 pull-contribution: forge=$FORGE pr=$PRN ref=$REF -> $CONTRIB =="

# GOOD PATH: fetch the ref (preserves commits + author + Signed-off-by verbatim).
FETCH_ERR="$(mktemp)"
if git fetch "$REMOTE" "+${REF}:${CONTRIB}" 2>"$FETCH_ERR"; then
  echo "OK: fetched $REF into $CONTRIB (authorship + Signed-off-by preserved)."
  echo "Review: git log --format='%h %an <%ae> %s' main..$CONTRIB   (verify DCO Signed-off-by present)"
  echo "Merge on canonical when reviewed:  git checkout main; git merge --no-ff $CONTRIB"
  rm -f "$FETCH_ERR"
  exit 0
fi

echo "WARN: direct ref fetch failed (deleted/private fork or ref absent):" >&2
# M3: scrub any embedded https://user:TOKEN@host credential from git stderr before display
sed -E 's#(://)[^@/]*@#\1***@#g; s/^/  /' "$FETCH_ERR" >&2
rm -f "$FETCH_ERR"

if [ "$ALLOW_PATCH" -ne 1 ]; then
  echo "Re-run with --allow-patch to fall back to the API diff (provenance-degraded; see below)." >&2
  exit 1
fi
if [ -z "$REPO" ]; then echo "error: --repo required for patch fallback" >&2; exit 2; fi

echo "== patch fallback (the contributor CR c1): downloading API diff =="
PATCHFILE="$(mktemp)"; PATCH_ERR="$(mktemp)"
if ! python3 "$ADAPTERS" patch "$FORGE" "$REPO" "$PRN" "${ADAPTER_ARGS[@]}" >"$PATCHFILE" 2>"$PATCH_ERR"; then
  echo "error: patch download failed:" >&2; sed -E 's#(://)[^@/]*@#\1***@#g; s/^/  /' "$PATCH_ERR" >&2
  rm -f "$PATCHFILE" "$PATCH_ERR"; exit 1
fi
rm -f "$PATCH_ERR"

git checkout -b "$CONTRIB" 2>/dev/null || git checkout "$CONTRIB"
if ! git apply --index --whitespace=nowarn "$PATCHFILE"; then
  echo "error: git apply failed; the diff may need manual application. Saved: $PATCHFILE" >&2
  exit 1
fi
AUTHOR_META="$(python3 "$ADAPTERS" list "$FORGE" "$REPO" "${ADAPTER_ARGS[@]}" 2>/dev/null \
  | python3 -c "import sys,json
n=int('$PRN')
for ln in sys.stdin:
    d=json.loads(ln)
    if d.get('number')==n:
        login=d.get('author_login') or 'contributor'
        email=d.get('author_email') or (login+'@users.noreply.'+'$FORGE')
        print(login+'|'+email); break" 2>/dev/null)"
LOGIN="${AUTHOR_META%%|*}"; EMAIL="${AUTHOR_META##*|}"
# M1: LOGIN/EMAIL are ATTACKER-CONTROLLED (a contributor names their own login/email in the PR payload).
# Validate against a strict charset BEFORE they reach `git commit --author` -- a `>`, a newline, or
# trailer-looking text could otherwise forge commit trailers (e.g. a fake Signed-off-by), defeating the
# very DCO provenance this fallback advertises. Fall back to a noreply identity on any rejection.
printf '%s' "$LOGIN" | grep -Eq '^[A-Za-z0-9._-]+$'                || LOGIN="contributor"
printf '%s' "$EMAIL" | grep -Eq '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$' || EMAIL="${LOGIN}@users.noreply.${FORGE}"
git commit --author="$LOGIN <$EMAIL>" \
  -m "contrib(${FORGE}#${PRN}): patch-fallback import" \
  -m "Origin: ${FORGE} PR #${PRN}" \
  -m "PROVENANCE-CAVEAT: imported via flat API diff (head ref unfetchable). Per-commit granularity and" \
  -m "the contributor's original Signed-off-by are NOT preserved. Maintainer must re-verify DCO before merge."
echo "OK: applied patch to $CONTRIB, attributed to $LOGIN <$EMAIL>."
echo "PROVENANCE WARNING: DCO Signed-off-by NOT carried through a flat diff -- re-establish before merge."
exit 0
