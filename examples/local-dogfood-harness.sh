#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# local-dogfood-harness.sh -- prove the forge-agnostic sovereign-git contribution loop with ZERO
# external services. Uses LOCAL bare repos as stand-ins for the canonical Forgejo (git.example.org)
# and the three public mirrors (github / gitlab / codeberg). Proves, end to end:
#   1. canonical -> push-mirror OUT to all 3 forges
#   2. a contributor opens a PR on EACH forge (pushed to that forge's native PR ref)
#   3. the RELAY fetches each PR by its per-forge ref and lands contrib/<forge>/pr-N on canonical
#   4. canonical merges all contributions
#   5. canonical push-mirrors OUT again -> all 3 mirrors re-converge on canonical
# The GIT mechanics are REAL; only the forge PR-list API is simulated (that's the adapter layer the contributor
# builds + tests against the real forges later, with the operator).
#
# Run:  bash examples/local-dogfood-harness.sh
# Exit 0 = all assertions passed. Read-only wrt the repo; all work in a mktemp dir (auto-cleaned).
set -uo pipefail

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
step() { printf '\n== %s ==\n' "$1"; }

WORK="$(mktemp -d -t sovgit-dogfood-XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
export GIT_AUTHOR_NAME="dogfood" GIT_AUTHOR_EMAIL="dogfood@local" \
       GIT_COMMITTER_NAME="dogfood" GIT_COMMITTER_EMAIL="dogfood@local"
G() { git -C "$1" "${@:2}"; }   # G <repodir> <git-args...>

# Per-forge PR ref convention (the forge-agnostic hook). Contributor pushes here; relay fetches here.
prref() {
  case "$1" in
    github)   echo "refs/pull/$2/head" ;;
    gitlab)   echo "refs/merge-requests/$2/head" ;;
    codeberg) echo "refs/pull/$2/head" ;;   # Forgejo == canonical semantics
  esac
}

FORGES="github gitlab codeberg"

step "0. Set up bare repos (canonical = git.example.org stand-in; 3 mirrors)"
for r in canonical github gitlab codeberg; do
  git init -q --bare "$WORK/$r.git"
  git -C "$WORK/$r.git" symbolic-ref HEAD refs/heads/main   # so clones check out main (not the default 'master')
done
ok "created bare repos: canonical + github + gitlab + codeberg (HEAD->main)"

step "1. Seed canonical + push-mirror OUT to all 3"
git init -q "$WORK/canon-wc"
printf 'name = sovereign-git-server\ncontributions:\n' > "$WORK/canon-wc/DEMO.md"
G "$WORK/canon-wc" add DEMO.md
G "$WORK/canon-wc" commit -q -m "seed: sovereign-git-server demo (canonical git.example.org)"
G "$WORK/canon-wc" branch -q -M main
G "$WORK/canon-wc" remote add canonical "$WORK/canonical.git"
G "$WORK/canon-wc" push -q canonical main
for f in $FORGES; do
  G "$WORK/canon-wc" remote add "$f" "$WORK/$f.git"
  G "$WORK/canon-wc" push -q "$f" main
done
base="$(G "$WORK/canonical.git" rev-parse main)"
for f in $FORGES; do
  if [ "$(G "$WORK/$f.git" rev-parse main)" = "$base" ]; then ok "mirror-out: $f main == canonical"; else bad "mirror-out: $f diverged"; fi
done

step "2. A contributor opens a PR on EACH forge (native fork+PR button, simulated as the PR ref)"
n=1
for f in $FORGES; do
  git clone -q "$WORK/$f.git" "$WORK/contrib-$f"
  # distinct file per contributor: this proof is about the RELAY LOOP, not merge-conflict resolution
  # (concurrent same-file PRs conflict -> a normal maintainer git concern; see framework doc).
  G "$WORK/contrib-$f" checkout -q -b "feat-$f"
  printf 'contribution from a %s contributor via native fork+PR (PR #%s)\n' "$f" "$n" > "$WORK/contrib-$f/contrib-$f.md"
  G "$WORK/contrib-$f" add -A
  G "$WORK/contrib-$f" commit -q -m "contrib($f): add contrib-$f.md via native PR"
  # push to that forge's PR ref (what the fork+PR actually produces server-side)
  G "$WORK/contrib-$f" push -q origin "HEAD:$(prref "$f" "$n")"
  ok "contributor PR #$n opened on $f ($(prref "$f" "$n"))"
done

step "3. RELAY: fetch each PR by its per-forge ref -> contrib/<forge>/pr-N on canonical"
git clone -q "$WORK/canonical.git" "$WORK/relay-wc"
G "$WORK/relay-wc" checkout -q main
for f in $FORGES; do
  G "$WORK/relay-wc" remote add "$f" "$WORK/$f.git"
  if G "$WORK/relay-wc" fetch -q "$f" "$(prref "$f" "$n"):contrib/$f/pr-$n"; then
    ok "relay fetched $f PR via $(prref "$f" "$n")"
  else
    bad "relay could NOT fetch $f PR ref"
  fi
done

step "4. canonical merges all contributions (maintainer review point)"
for f in $FORGES; do
  if G "$WORK/relay-wc" merge -q --no-edit "contrib/$f/pr-$n" -m "merge $f PR #$n into main (relayed to canonical)"; then
    ok "merged contrib/$f/pr-$n on canonical"
  else
    bad "merge conflict on contrib/$f/pr-$n"
    G "$WORK/relay-wc" merge --abort 2>/dev/null || true
  fi
done
G "$WORK/relay-wc" push -q canonical 2>/dev/null || G "$WORK/relay-wc" push -q origin main

step "5. push-mirror OUT again -> all 3 mirrors re-converge on canonical"
for f in $FORGES; do
  G "$WORK/relay-wc" push -q "$f" main
done
canon="$(G "$WORK/canonical.git" rev-parse main)"
for f in $FORGES; do
  if [ "$(G "$WORK/$f.git" rev-parse main)" = "$canon" ]; then ok "re-converge: $f main == canonical"; else bad "re-converge: $f diverged"; fi
done

step "6. content proof: canonical DEMO.md carries ALL three contributions"
G "$WORK/relay-wc" checkout -q main
for f in $FORGES; do
  if [ -f "$WORK/relay-wc/contrib-$f.md" ]; then ok "canonical carries contrib-$f.md (the $f contribution)"; else bad "canonical MISSING contrib-$f.md"; fi
done

step "RESULT"
printf 'PASS=%s  FAIL=%s\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf 'DOGFOOD GREEN: the forge-agnostic loop (mirror-out -> per-forge PR -> relay-back -> merge -> mirror-out) works end-to-end on local stand-ins.\n'
  exit 0
else
  printf 'DOGFOOD RED: see FAIL lines above.\n'
  exit 1
fi
