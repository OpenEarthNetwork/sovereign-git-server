# W2 (contribute-back) -- absorb-a-mirror-PR walkthrough

A worked example of the **W2 contribute-back** workflow: a contributor opens a PR on one of
your **mirrors**, the relay **absorbs** it back to your sovereign canonical, you **merge**
there, and the merge **mirrors back out** while the original mirror PR is **notified and
closed as ABSORBED**. This is the IN direction that completes W1 (`docs/W1-own-and-mirror-walkthrough.md`,
the OUT direction). Taxonomy: `docs/SETUP.md` S2; integrity primitives: `docs/WORKFLOWS.md`
(SHA integrity).

Throughout, `git.example.org` is a placeholder for **your own** sovereign Forgejo domain --
replace it with yours. The GitHub org `OpenEarthNetwork`, the repo `openearth-gryph`, and
**PR #1** are the **real** public repos + PR used in the dogfood transcript below.

---

## Transport rule -- read this first (it is the recurrent lesson)

Two different channels, two different auth models -- never mix them up:

- **git transport (clone / fetch / push / remote) = SSH, ALWAYS.**
  Use `ssh://git@host/owner/repo.git`. **NEVER git-over-HTTPS.** This bites hardest exactly
  here: the relay's push of the absorbed branch to your canonical **must** be SSH. In our
  run the push step initially tried HTTPS and **failed** against the SSH-only canonical host;
  the fix is to push over the SSH canonical remote (documented explicitly in Step 3 below).
- **forge REST APIs (list / open / merge / comment / close PRs, trigger a mirror-sync, read a
  branch SHA) = HTTPS + token**, via `curl` / the relay adapters. There is no SSH equivalent
  for a forge's REST API -- that is exactly what the tokens are for.

So: the relay *lists and closes PRs* over HTTPS+token, but *moves the absorbed commits* over
SSH.

---

## What W2 is (and is not)

- **Canonical is still the only merge point.** The PR is raised on a mirror for the
  contributor's convenience, but it is never merged there. It is absorbed to
  `git.example.org` and merged on the canonical.
- **A mirror is a push-mirror -- never push a branch straight to it.** Forgejo force-syncs
  each mirror OUT from canonical (~8h). A branch pushed directly to the mirror repo would be
  **wiped** on the next force-sync. Contributors therefore **fork** the mirror and PR from
  the fork.
- **"Closed" is not "rejected".** After the canonical merge, the relay comments the merge SHA
  on the original mirror PR and closes it as **ABSORBED**. The close carries the proof that
  the change landed -- it is the opposite of a rejection.
- **The loop re-converges, provably.** After the merge mirrors back out, all mirror endpoints
  are SHA-verified to equal the exact merge commit.

---

## Prerequisites

- A W1 setup already in place: your canonical on `git.example.org` push-mirroring OUT to the
  big forges (`docs/W1-own-and-mirror-walkthrough.md`).
- A **working dir that is a clone of the canonical** with one git remote per forge, each an
  **SSH** URL, e.g. remote `github` = `ssh://git@github.com/OpenEarthNetwork/openearth-gryph.git`.
  The relay fetches the PR from the mirror remote and pushes the absorbed branch to canonical.
- Forge API tokens **env-only** (never argv): `GITHUB_TOKEN` for GitHub actions, and a
  canonical Forgejo token for the canonical PR-open / push.
- `git`, `python3`. SSH access (`~/.ssh/config`) to every git endpoint including
  `git.example.org`.

---

## CONTRIBUTOR side -- fork the mirror, do NOT push to it

The contributor works entirely on the mirror side, the ordinary open-source way, with one
hard rule: **fork, do not push a branch to the mirror repo** (the ~8h push-mirror
force-sync would wipe it). Sign off every commit for DCO:

```
gh repo fork OpenEarthNetwork/openearth-gryph --clone --remote
git switch -c fix/readme-header-punctuation
vim README.md                       # the actual change
git add README.md
git commit -s -m "Fix README section header punctuation"   # -s = Signed-off-by (DCO)
git push -u origin fix/readme-header-punctuation            # origin = the FORK, not the mirror
gh pr create --repo OpenEarthNetwork/openearth-gryph --base main --fill
```

Real dogfood: **github#1** "Fix README section header punctuation", author `example-contributor`, opened
from a fork against `OpenEarthNetwork/openearth-gryph:main`.

---

## MAINTAINER side -- absorb, merge, mirror-back, close

### Step 1 -- Working dir = a clone of the canonical, one SSH remote per forge

The relay runs from a canonical clone that knows each mirror by an **SSH** remote (that is how
it fetches the PR head and, later, how you push back out). The remote for GitHub in the
dogfood:

```
git remote add github ssh://git@github.com/OpenEarthNetwork/openearth-gryph.git   # SSH, always
```

### Step 2 -- Plan (dry-run): what would be absorbed

`ias-git-relay.py plan` lists open PRs on each mirror and shows which are not yet relayed. It
is fully offline-safe (dry-run by default) and reads the forge PR list over HTTPS+token:

```
python3 tools/sovereign-git/relay/ias-git-relay.py plan openearth-gryph \
  --forge github \
  --base-url https://api.github.com \
  --token-env GITHUB_TOKEN \
  --mirror-remote github
```

Real dogfood output: the PR listed as
`WOULD RELAY github#1 -> contrib/github/pr-1  [fetch-ref]  by example-contributor :: Fix README section header punctuation`.

`[fetch-ref]` means the PR head is fetchable via the forge's per-PR ref
(`refs/pull/N/head` on GitHub/Forgejo, `refs/merge-requests/N/head` on GitLab). If the head
is unfetchable (deleted branch / private fork), the plan shows `[patch-fallback]` -- see
"`--allow-patch`" below.

### Step 3 -- Relay (enact): fetch the PR onto canonical over SSH, push, open the canonical PR

Add `--actually-relay` plus the canonical coordinates. The relay (a) fetches
`refs/pull/1/head` from the mirror over SSH into a `contrib/github/pr-1` branch (author +
`Signed-off-by` preserved -- provenance is **not** re-authored), (b) **pushes that branch to
the canonical server over SSH**, and (c) opens the canonical Forgejo PR:

```
python3 tools/sovereign-git/relay/ias-git-relay.py relay openearth-gryph \
  --forge github \
  --base-url https://api.github.com \
  --token-env GITHUB_TOKEN \
  --mirror-remote github \
  --actually-relay \
  --canonical-base-url https://git.example.org/api/v1 \
  --canonical-repo OpenEarthNetwork/openearth-gryph \
  --canonical-token-env GITVW_FORGEJO_TOKEN
```

**SSH-push note (the real-world gotcha).** L1 fetch is fetch-only, so the absorbed
`contrib/github/pr-1` branch first exists **only** in the local canonical clone; the relay
must push it to the canonical server before the canonical PR can open (`head branch not
found` otherwise). That push **must be SSH**. In our run the push initially attempted HTTPS
and failed on the SSH-only canonical host; the fix is to push over the SSH canonical remote:

```
git push ssh://git@git.example.org/OpenEarthNetwork/openearth-gryph.git \
  contrib/github/pr-1:contrib/github/pr-1
```

(The relay embeds the canonical token only in an in-process URL for the push and never logs
it; when driving the push by hand, use your configured SSH canonical remote so no token is on
the command line at all.)

### Step 4 -- Review + merge the canonical PR (op + maintainer quorum)

Review the canonical PR on `git.example.org` and merge it under your quorum (operator +
maintainer). Note the **merge commit SHA** -- everything downstream is proven against it.

Real dogfood: canonical **PR #1** merged as
`7ffe3cb9c3e97bc319136b62a69c90593e1dfe0d`.

### Step 5 -- Notify + close the ORIGINAL mirror PR (absorbed, not rejected)

The relay does not observe the canonical merge itself, so closing the loop on the mirror side
is a **separate** subcommand a maintainer runs after merging. `notify` comments the merge SHA
on the original mirror PR ("absorbed as `<sha>`, mirrored back, closing as ABSORBED") and
closes it (all forge REST -- HTTPS+token):

```
python3 tools/sovereign-git/relay/ias-git-relay.py notify openearth-gryph \
  --forge github \
  --pr 1 \
  --merged-sha 7ffe3cb9c3e97bc319136b62a69c90593e1dfe0d \
  --canonical-url https://git.example.org/OpenEarthNetwork/openearth-gryph \
  --base-url https://api.github.com \
  --token-env GITHUB_TOKEN
```

Real dogfood: github#1 was commented + closed as **ABSORBED**. This is precisely why a
"closed" mirror PR is not a rejection -- the closing comment carries the canonical merge SHA
that proves the change landed.

### Step 6 -- Mirror back out, then SHA-verify convergence

Merging on canonical means the push-mirror will carry the merge OUT on its interval; trigger
it now, then prove every mirror converged to the exact merge SHA. Trigger the OUT sync
(`bin/ias-git-mirror-sync.sh` for the pull direction, or the `push_mirrors-sync` forge endpoint
for push-mirrors -- HTTPS+token in a header, never in the URL), then verify over **SSH**:

```
bash bin/ias-git-verify.sh \
  ssh://git@git.example.org/OpenEarthNetwork/openearth-gryph.git \
  ssh://git@github.com/OpenEarthNetwork/openearth-gryph.git \
  --ignore-refs 'refs/pull/*' \
  --expect-sha 7ffe3cb9c3e97bc319136b62a69c90593e1dfe0d
```

Repeat for the GitLab (`--ignore-refs 'refs/merge-requests/*'`) and Codeberg endpoints. Each
must end in `OK: dst HEAD == expected 7ffe3cb9...` + `VERIFIED: ...`.

Real dogfood result: **all 4 endpoints == `7ffe3cb9`** -- canonical + github + gitlab +
codeberg re-converged on the merge commit. The loop closed, provably.

---

## The push-mirror force-overwrite tension (why fork, not push-to-mirror)

The single most common W2 mistake: pushing a fix branch straight to the mirror repo. Because
Forgejo force-syncs each mirror OUT from canonical (~8h), any branch that exists only on the
mirror is **overwritten** on the next sync -- the contributor's work vanishes. The mirror is
a reflection, not a workspace. The correct shape is always: **fork the mirror -> PR from the
fork -> relay absorbs to canonical**. Reflections are read-only; work happens at the hub.

## `--allow-patch` fallback for unfetchable heads

If a PR head cannot be fetched by ref -- the contributor deleted their branch, or the fork is
private -- the per-PR `refs/pull/N/head` no longer resolves. The `plan` output flags such a
PR as `[patch-fallback]`, and the relay passes `--allow-patch` to L1 so the change is
absorbed from the forge's API-served patch instead of a git fetch. Authorship and
`Signed-off-by` are still preserved; only the transport of the diff differs.

## Attribution / DCO preservation

The relay never re-authors. The absorbed `contrib/<forge>/pr-N` branch carries the original
commit author and the contributor's `Signed-off-by` line intact, so the canonical history --
and every mirror it pushes back out to -- credits the real contributor and preserves the DCO
sign-off. The `-s` at commit time (contributor side) is what makes that sign-off exist.

## Known follow-ups

- **Auto-poll monitor (L2 daemon).** Today a maintainer runs `plan` / `relay` on demand
  (the L1.5 stance). The planned next step is a monitor that polls each mirror's PR API and
  auto-relays new PRs to canonical, escalating from on-demand to a bot once PR volume
  justifies a daemon. Design: L2 in `README.md` "Layered contribution model" +
  `docs/WORKFLOWS.md`.

---

## Every copy op ends with a SHA-verify

The invariant that makes the whole bundle trustworthy: **"exit code 0" from a fetch / push /
merge / mirror-sync is not proof; a matching ref-SHA set is.** Step 6 verifies every mirror
against the exact `--expect-sha` merge commit. Full rationale + every integrity recipe:
`docs/WORKFLOWS.md`, "SHA integrity -- verify every copy".

---

## Summary (the W2 loop in six lines)

1. CONTRIBUTOR: **fork** the mirror (never push to it), edit, `git commit -s` (DCO), open a
   PR against the mirror's `main`. (Dogfood: github#1, author example-contributor.)
2. `ias-git-relay.py plan <repo> --forge github ... --mirror-remote github` -> lists it as
   `contrib/github/pr-N [fetch-ref]`.
3. `ias-git-relay.py relay ... --actually-relay --canonical-base-url ... --canonical-repo ...`
   -> fetch the PR head over SSH, **push the branch to canonical over SSH**, open the
   canonical PR.
4. Review + merge the canonical PR on git.example.org (op + maintainer quorum); note the
   merge SHA. (Dogfood: canonical PR#1 = `7ffe3cb9...`.)
5. `ias-git-relay.py notify <mirror-repo> --pr N --merged-sha <sha> ...` -> comments
   "absorbed as `<sha>`, mirrored back" + closes the mirror PR as ABSORBED (not rejected).
6. Trigger the OUT mirror-sync, then `bin/ias-git-verify.sh <canonical-ssh> <each-mirror-ssh>
   --expect-sha <sha>` -> all 4 endpoints == the merge commit. (Dogfood: all 4 == `7ffe3cb9`.)
