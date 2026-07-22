# W1 (own-and-mirror) -- canonical-out walkthrough

A worked example of the **W1 own-and-mirror** workflow: a repo **you own**, kept canonical
on **your own sovereign Forgejo** (the single source of truth), then **push-mirrored OUT**
to GitHub + GitLab + Codeberg as read-only, byte-identical reach copies. This is the
foundational pattern of the bundle -- "we own it, we control it, the big forges only
reflect it." Contrast W3 (`docs/W3-follow-copy-walkthrough.md`), where someone else owns
the repo and you are the follower. Taxonomy: `docs/SETUP.md` S1; integrity primitives:
`docs/WORKFLOWS.md` (SHA integrity).

Throughout, `git.example.org` is a placeholder for **your own** sovereign Forgejo domain --
replace it with yours. The GitHub/GitLab/Codeberg org `OpenEarthNetwork` and the repo
`openearth-gryph` are the **real** public repos used in the dogfood transcript below.

---

## Transport rule -- read this first (it is the recurrent lesson)

Two different channels, two different auth models -- never mix them up:

- **git transport (clone / fetch / push / remote) = SSH, ALWAYS.**
  Use `ssh://git@host/owner/repo.git`. **NEVER git-over-HTTPS.** HTTPS git hosts do not
  resolve in the agent sandbox, and an SSH-only canonical server rejects HTTPS pushes
  outright.
- **forge REST APIs (create a repo, migrate/import content, list/open/merge PRs, trigger a
  mirror-sync, read a branch SHA) = HTTPS + token**, via `curl` (or `gh`). There is no SSH
  equivalent for a forge's REST API -- that is exactly what the tokens are for.

Keep the two straight: you *drive the forge* over HTTPS+token, but you *move git objects*
over SSH. Every tool in this bundle already obeys this; when you run a raw command by hand,
you must too.

---

## What W1 is (and is not)

- **Your Forgejo is canonical -- the single merge point.** The authoritative history lives
  on `git.example.org`. That is the repo you push to, review on, and merge into.
- **GitHub / GitLab / Codeberg are reach-only mirrors.** They exist so the world can find
  and read your code where it already looks. They are **push-mirrors**: Forgejo pushes the
  canonical history OUT to them on an interval (default ~8h) and on commit. Nobody merges
  *on* a mirror -- a merge there would be overwritten on the next force-sync.
- **The mirrors are byte-identical, provably.** Every mirror endpoint resolves to the exact
  same ref SHAs as the canonical. We do not take "the push succeeded" on faith; we
  **SHA-verify** all four endpoints against one another.
- **Contributions come back the W2 way.** A contributor who wants to change your code forks
  a mirror and opens a PR; the relay absorbs it to your canonical, you merge there, and the
  merge push-mirrors back out. That is the sequel: `docs/W2-contribute-back-walkthrough.md`.

### The "which is canonical" mental model

Draw it as a hub with spokes. The **hub** is `git.example.org` -- the only place history is
written. The **spokes** are the three big-forge mirrors -- read-only reflections, each an
exact copy of the hub. Contributors approach via a spoke (fork + PR on a mirror), but their
change only becomes real when it lands at the **hub** and is mirrored back out. If you ever
have to ask "which copy is the truth?" the answer is always: the one on your own server.

---

## Prerequisites

- A sovereign Forgejo at `git.example.org`, stood up per `docs/SETUP.md` section 1
  (`bin/ias-git-server-standup.sh`).
- A Forgejo API token (scope `write:repository`) for the org that will own the canonical
  repo -- used for the migrate/import + the push-mirror creation. **Env-only**, never on the
  command line.
- On each mirror forge you want reach on (GitHub / GitLab / Codeberg): an account, an org,
  and a push PAT for the mirror repo.
- `git`, `curl`, `python3`. SSH access to every git endpoint (`~/.ssh/config` with a `Host
  git.example.org` entry using your canonical key) for the verify step.

---

## Step 1 -- Establish the canonical on your Forgejo (import into git.example.org)

Bring the content into your sovereign server so it becomes the source of truth. In the
dogfood we imported the already-public `openearth-gryph` snapshot into the `OpenEarthNetwork`
org on git.example.org via Forgejo's **migrate API** (a forge REST call -- HTTPS + token),
with `mirror: false` so the imported repo is a real owned repo, **not** a pull-mirror
(a pull-mirror would follow an upstream; here *we* are upstream):

```
curl -sS -X POST https://git.example.org/api/v1/repos/migrate \
  -H "Authorization: token $FORGEJO_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"clone_addr":"ssh://git@codeberg.org/OpenEarthNetwork/openearth-gryph.git",
       "repo_owner":"OpenEarthNetwork","repo_name":"openearth-gryph",
       "mirror":false,"private":false}'
```

Note the split: the API call is **HTTPS + token** (that is how you talk to a forge), while
`clone_addr` is an **SSH** git URL (that is how git objects move). `private:false` publishes
it; `mirror:false` makes it a genuine owned canonical, not a follower.

Real dogfood result: the canonical `OpenEarthNetwork/openearth-gryph` on git.example.org at
snapshot SHA `3a8aea37`.

### Make the canonical anonymously readable

A canonical you can only see while logged in is not a shareable reader link. Set
`REQUIRE_SIGNIN_VIEW = false` on the instance so logged-out visitors can browse **public**
repos (private repos stay fully walled). One-time server-side fix:
`docs/howtos/make-public-repos-anonymously-viewable.md`. In the dogfood, after this the
canonical's anon reader link returned **HTTP 200**.

---

## Step 2 -- Create the three empty mirror targets

Create the (empty) destination repos on each big forge that the push-mirror will fill. Each
is a forge REST call (HTTPS + token) or the forge CLI:

```
gh repo create OpenEarthNetwork/openearth-gryph --public          # GitHub (gh)
# GitLab + Codeberg: POST /projects and /user/repos respectively, token in a header.
```

Leave them empty -- Step 3's push-mirror is what fills them, and keeping them empty avoids a
first-sync history conflict. In the dogfood, three empty public `openearth-gryph` repos were
created under `OpenEarthNetwork` on github / gitlab / codeberg.

---

## Step 3 -- Wire the push-mirrors (canonical -> all three)

`bin/ias-git-mirror-setup.sh` creates Forgejo **push-mirrors** from your canonical OUT to each
forge. It is DRY-RUN by default; run `plan` first, then `apply`. Tokens go in the
**environment only** -- never on argv (they would show in `ps`), never concatenated into the
JSON body (a quote or backslash would corrupt or field-smuggle the request); the tool builds
the JSON with a real encoder and sends the Forgejo token in an `Authorization` header:

```
export FORGEJO_URL=https://git.example.org
export OWNER=OpenEarthNetwork
export REPO=openearth-gryph
export FORGEJO_TOKEN=...            # write:repository on OWNER/REPO (env-only)
export GH_MIRROR_URL=https://github.com/OpenEarthNetwork/openearth-gryph.git
export GH_MIRROR_TOKEN=...          # per-host push PAT
export GITLAB_MIRROR_URL=https://gitlab.com/openearthnetwork/openearth-gryph.git
export GITLAB_MIRROR_TOKEN=...
export CODEBERG_MIRROR_URL=https://codeberg.org/OpenEarthNetwork/openearth-gryph.git
export CODEBERG_MIRROR_TOKEN=...

bash bin/ias-git-mirror-setup.sh plan      # dry-run: WOULD add push-mirror -> github/gitlab/codeberg
bash bin/ias-git-mirror-setup.sh apply     # actually create them (op-gated)
```

Real dogfood output (apply): `OK  push-mirror -> github` / `-> gitlab` / `-> codeberg`.

**Transport-model note.** The push-mirror is created via the Forgejo forge API (token over
HTTPS at the forge-API level), but the mirror push that Forgejo then performs is a
**server-side** operation on your Forgejo host, on its own schedule (interval `8h0m0s`,
`sync_on_commit: true`). A host with a URL/token pair missing is skipped with a note --
partial mirroring (e.g. GitHub + Codeberg but not GitLab) is fine. **Only public repos** are
ever mirrored out; a private (e.g. jurisdiction-sensitive) repo must never leave the
canonical.

---

## Step 4 -- Force the first sync (do not wait ~8h)

The push-mirror will sync on its interval, but for a fresh setup you want it now. Trigger an
immediate push-mirrors-sync (again a forge API call, HTTPS + token in a header):

```
curl -sS -X POST \
  https://git.example.org/api/v1/repos/OpenEarthNetwork/openearth-gryph/push_mirrors-sync \
  -H "Authorization: token $FORGEJO_TOKEN"
```

(`bin/ias-git-mirror-sync.sh` is the tool for the *pull*-mirror direction used in W3; for W1's
push-mirrors the `push_mirrors-sync` endpoint above is the OUT-direction trigger.) The sync
is **asynchronous** -- Forgejo queues it. Give it a moment, then verify.

---

## Step 5 -- SHA-verify all four endpoints (the heart of W1)

This is the invariant: **no copy op is done until a matching ref-SHA set proves it.** "The
push-mirror was created" and "the sync returned 200" are not proof -- a matching SHA is.
Compare the canonical against each mirror with `bin/ias-git-verify.sh`, over **SSH** endpoints,
asserting the exact snapshot SHA:

```
bash bin/ias-git-verify.sh \
  ssh://git@git.example.org/OpenEarthNetwork/openearth-gryph.git \
  ssh://git@github.com/OpenEarthNetwork/openearth-gryph.git \
  --ignore-refs 'refs/pull/*' \
  --expect-sha 3a8aea37...
```

Repeat with the GitLab endpoint (`--ignore-refs 'refs/merge-requests/*'`) and the Codeberg
endpoint. Each must end in:

```
OK: dst HEAD == expected 3a8aea37...
VERIFIED: all N compared ref SHAs match (faithful copy).
```

Real dogfood result: **all 4 endpoints** (git.example.org canonical + github + gitlab +
codeberg) resolved to the **same SHA** `3a8aea37`, and **all 4 anon reader links returned
HTTP 200** -- including the git.example.org canonical (which required
`REQUIRE_SIGNIN_VIEW = false`; see Step 1). A green `VERIFIED` plus a matching `--expect-sha`
on every spoke is cryptographic proof the mirrors are byte-identical reflections of your
canonical, nothing lost.

`--ignore-refs 'refs/pull/*'` / `'refs/merge-requests/*'` omits each forge's PR/MR refs
(which a mirror may carry differently) so you still verify every branch and tag SHA without
those counting as divergence. These are **server-to-server** compares (both sides bare), so
you do **not** pass `--clone-mode` (that flag is only for verifying a working `git clone`).

---

## Step 6 -- Record the linkage

Record the public release in `.ias/declassified-releases.json` (the W4 declassified-release
ledger): the private canonical, the public canonical on git.example.org, the three mirrors,
the release snapshot SHA, and the verify result. This is the audit trail that says "this
public artefact = this canonical at this SHA, mirrored to these three, all verified." The
dogfood recorded `openearth-gryph` -> git.example.org canonical -> github/gitlab/codeberg,
snapshot `3a8aea37`, all four SHA-verified + anon-200.

---

## Fork-based contribution (leads into W2)

W1 sets up the OUT direction; the way changes come back IN is the sequel. Because a mirror is
a push-mirror that Forgejo force-syncs (~8h), a contributor must **never** push a branch
straight to a mirror repo -- the next force-sync would wipe it. Instead they **fork** the
mirror, push their branch to the fork, and open a PR against the mirror's `main`. Your relay
then absorbs that PR to the canonical, you merge there, and the merge push-mirrors back out
-- closing the loop and re-converging all four endpoints on the new SHA. Full worked example:
`docs/W2-contribute-back-walkthrough.md`.

---

## Every copy op ends with a SHA-verify

The invariant that makes the whole bundle trustworthy: **"exit code 0" from a migrate / a
push-mirror create / a sync is not proof; a matching ref-SHA set is.** Step 5 verifies all
four endpoints against the same `--expect-sha`. Full rationale (why a matching ref SHA proves
a byte-identical copy) and every integrity recipe: `docs/WORKFLOWS.md`, "SHA integrity --
verify every copy".

---

## Summary (the W1 loop in six lines)

1. Import the content into your Forgejo as an OWNED canonical (`mirror:false`, `private:false`
   via the migrate API -- HTTPS+token; `clone_addr` is SSH). Make it anon-viewable.
2. Create the three EMPTY mirror repos on github / gitlab / codeberg (forge API / `gh`).
3. `bin/ias-git-mirror-setup.sh plan` then `apply` -> Forgejo push-mirrors canonical -> all 3
   (tokens env-only).
4. Trigger `push_mirrors-sync` (forge API, HTTPS+token) -> queues the OUT push (async).
5. `bin/ias-git-verify.sh <canonical-ssh> <each-mirror-ssh> --ignore-refs ... --expect-sha <sha>`
   -> all 4 endpoints == the same SHA; all 4 anon reader links == 200.
6. Record the linkage in `.ias/declassified-releases.json`. Contributions come back the W2
   way (fork a mirror, PR, relay to canonical).
