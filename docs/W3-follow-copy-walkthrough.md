# W3 (follow-copy) -- contribute-upstream walkthrough

A worked example of the **W3 follow-copy** workflow: contributing back to a repo that
**someone else owns and keeps canonical on GitHub**, while you keep your own SHA-verified
local working clone AND an auto-updating pull-mirror on your sovereign server as a safety
copy. This is the "we follow a repo we don't control" pattern, distinct from W1/W2 (where
YOUR Forgejo is canonical and the big forges are reach-only). Taxonomy: `docs/SETUP.md` S3;
integrity primitives: `docs/WORKFLOWS.md` (SHA integrity).

Throughout, `git.example.org` is a placeholder for **your own** sovereign Forgejo domain --
replace it with yours. The GitHub org `datascience-intro` and repo `GenJSONnotebookGrader`
are the **real** public repos used in the dogfood transcript below.

---

## What W3 is (and is not)

- **Upstream stays canonical.** The repo lives on someone else's GitHub org
  (`datascience-intro`). You do NOT try to become the merge point. You contribute the
  normal open-source way: branch + push + PR to their GitHub.
- **You keep two independent copies, each with a job:**
  1. A **local WORKING clone** -- SHA-verified against upstream at creation -- that you
     branch from and open PRs from. This is where you do the actual editing.
  2. A **server-side PULL-MIRROR** on your sovereign Forgejo (`git.example.org`) that
     tracks upstream automatically (default ~8h) as a **safety copy** you control, so the
     history survives even if upstream is taken down, sanctioned, or deleted.
- **The loop you close:** you contribute UPSTREAM (PR to their GitHub) -> upstream merges
  it -> your pull-mirror later tracks the merged result -> you **SHA-verify** the merged
  change actually arrived in your sovereign mirror, nothing lost.

Contrast with W1/W2: those are for repos where **your** Forgejo is canonical and PRs raised
on any mirror are relayed back to you. W3 is the mirror image -- you are the follower.

---

## Local layout convention

Every repo you follow or own lives under a predictable local path:

```
<base>/<forge>/<org>/<public|private>/<repo>
```

- `<forge>` -- the canonical host you got it from (`github`, `gitlab`, `codeberg`, or your
  own `git.example.org`).
- `<org>` -- the owning org/user (`datascience-intro`).
- `<public|private>` -- visibility of the upstream repo. NEVER push a `private/` repo out
  to a public mirror.
- `<repo>` -- the repository name.

So the working clone in this walkthrough lives at:

```
<base>/github/datascience-intro/public/GenJSONnotebookGrader
```

Each `<org>` (and `<forge>`) directory carries a small `_ROLE.md` signpost stating what
that tree is for -- e.g. that `github/datascience-intro/` is a **W3 follow-copy** set:
upstream is canonical, these are local working clones for contributing PRs, and the
sovereign safety copies are **server-side pull-mirrors on `git.example.org`, not second
local clones**. The `_ROLE.md` is why anyone (or any future agent) picking up the tree
knows the local copy is the working copy and the durable copy lives on the server.

---

## Prerequisites

- `git`, plus the GitHub CLI `gh` authenticated (`gh auth status`) for opening the PR.
- SSH access to GitHub (`ssh://git@github.com/...`) -- HTTPS git hosts do not resolve in
  the agent sandbox; use SSH endpoints (see `docs/WORKFLOWS.md`, "Endpoint / auth notes").
- A sovereign Forgejo at `git.example.org` already configured to **pull-mirror** the
  upstream repo (Forgejo repo settings -> Mirror, or created at migration time). The
  pull-mirror is what makes this W3 rather than a plain fork.

---

## Step 1 -- SHA-confirming local working clone

Create the local working clone with the SHA-confirming tool, not a bare `git clone`. It
does a full clone and then proves every ref SHA matches upstream, so you know the copy you
are about to branch from is byte-identical to canonical.

```
bash bin/ias-git-clone-verified.sh \
  ssh://git@github.com/datascience-intro/GenJSONnotebookGrader.git \
  <base>/github/datascience-intro/public/GenJSONnotebookGrader
```

Real dogfood output:

```
VERIFIED: all 9 compared ref SHAs match (faithful copy)
```

(8 branches + HEAD = 9 refs.) The tool runs the verify in `--clone-mode` automatically: a
working `git clone` keeps non-default branches under `refs/remotes/origin/*`, so
`--clone-mode` remaps those to `refs/heads/*` for the comparison and auto-ignores the forge
PR/MR namespaces (`refs/pull/*`, `refs/merge-requests/*`) a clone never fetches. That is
why a multi-branch clone VERIFIES instead of false-FAILing. You never pass `--clone-mode`
yourself here -- `bin/ias-git-clone-verified.sh` does.

---

## Step 2 -- Branch, change, commit, push, PR (contribute upstream)

Work in the local clone exactly as you would for any open-source contribution. This is the
operator's real terminal session:

```
cd <base>/github/datascience-intro/public/GenJSONnotebookGrader
git switch -c test/sovereign-git-roundtrip
vim README.md            # made a one-line change
git add README.md
git commit -m "test: sovereign-git round-trip marker in README"   # commit ab6f422
git push -u origin test/sovereign-git-roundtrip
gh pr create --fill --base main
```

Result:

```
PR opened: https://github.com/datascience-intro/GenJSONnotebookGrader/pull/7
```

`origin` here is upstream GitHub (that is what the SHA-confirming clone set it to), so the
branch and PR go straight to the canonical repo.

### Fork fallback (no push access to the upstream org)

If you cannot push branches to the upstream org (the common case for a stranger's repo),
fork it and PR from your fork instead:

```
gh repo fork datascience-intro/GenJSONnotebookGrader --remote
git push -u <your-fork-remote> test/sovereign-git-roundtrip
gh pr create --fill --base main --head <your-gh-user>:test/sovereign-git-roundtrip
```

`gh repo fork --remote` creates the fork and adds it as a git remote; you push the branch
to the fork and open the PR from the fork against upstream `main`. Everything downstream
(the merge, the mirror sync, the SHA proof) is identical.

---

## Step 2b -- Merge the PR upstream

If you have merge rights on the upstream repo (e.g. it is your own course's repo), merge
from the CLI or the GitHub mobile app -- either produces the same merge commit on `main`.

CLI (in the repo dir):

```
gh pr merge 7 --squash --delete-branch
```

- `--squash` folds the PR into one clean commit on `main` (fine for a small change); use
  `--merge` instead to keep a merge commit, or `--rebase` to replay commits. If branch
  protection blocks it and you are an admin, add `--admin`.
- **Mobile:** open the PR in the GitHub app -> **Merge** -> same result.

If you do NOT have merge rights, this step belongs to the upstream maintainer -- wait for
them to merge, then continue at Step 3 once it lands on `main`.

In the dogfood, PR #7 was squash-merged and the branch deleted; `main` advanced to merge
commit `dd3c720ab64907da16e74c6e546614c2874f13e8`.

---

## Step 3 -- The round-trip / SHA proof (the heart of W3)

Once the PR is **merged upstream**, prove the merged change reached your sovereign mirror,
nothing lost. This is what turns "I contributed and I have a mirror" into "I have
cryptographic proof my sovereign copy holds the merged result."

### 3a. Capture the exact merge SHA

```
gh pr view 7 --json mergeCommit -q .mergeCommit.oid
```

Or, once upstream is fetched locally:

```
git fetch origin
git rev-parse origin/main
```

Either gives you the exact merge commit SHA -- call it `<merge-sha>`.

### 3b. Let (or force) the sovereign pull-mirror catch up

Your Forgejo pull-mirror on `git.example.org` follows upstream on its own schedule
(default ~8h). To force an immediate sync, use the bundle tool:

```
set -a; source ~/.config/openearth/tokens.env; set +a    # EXPORT the token (see note)
bash bin/ias-git-mirror-sync.sh datascience-intro/GenJSONnotebookGrader \
  --base-url https://git.example.org
```

Real dogfood output: `HTTP 200` (sync queued). Under the hood the tool sends the token in an
**Authorization header** (never in the URL, never echoed) to the Forgejo API
`POST /api/v1/repos/<owner>/<repo>/mirror-sync`. Two gotchas it documents for you:

- The token must be **exported** so the tool's child process inherits it. A plain `source`
  of your tokens file (without `set -a` / `export`) sets the var only in your current shell,
  not in the tool -- hence the `set -a; source ...; set +a` form above.
- mirror-sync is **asynchronous** -- Forgejo queues the pull. Give it a moment, or just
  re-run the verify below until it matches.

### 3c. Prove it arrived

Compare the two server endpoints (upstream GitHub vs your sovereign mirror) and assert the
mirror's HEAD is exactly the merge SHA:

```
bash bin/ias-git-verify.sh \
  ssh://git@github.com/datascience-intro/GenJSONnotebookGrader.git \
  ssh://git@git.example.org/datascience-intro/GenJSONnotebookGrader.git \
  --ignore-refs 'refs/pull/*' \
  --expect-sha <merge-sha>
```

Real dogfood output (`<merge-sha>` = `dd3c720ab64907da16e74c6e546614c2874f13e8`):

```
OK: dst HEAD == expected dd3c720ab64907da16e74c6e546614c2874f13e8
  ignore 'refs/pull/*' removed 7 src / 7 dst refs
VERIFIED: all 9 compared ref SHAs match (faithful copy).
```

A green `VERIFIED` (all branch + tag SHAs match) **plus** a matching `--expect-sha` is
cryptographic proof the merged change reached your sovereign mirror faithfully -- the loop
closed. `--ignore-refs 'refs/pull/*'` omits GitHub's PR refs, which a pull-mirror does not
carry, so you still verify every branch and tag SHA without the PR refs counting as
divergence.

**Note -- no `--clone-mode` here.** This is a **server-to-server** compare (GitHub bare
canonical vs Forgejo pull-mirror); both sides store branches under `refs/heads/*` already.
`--clone-mode` is ONLY for verifying a working `git clone` (Step 1), whose non-default
branches live under `refs/remotes/origin/*`. Passing it to a server-to-server compare would
be wrong.

---

## Grab a whole org cleanly

W3 scales to an entire org, not just one repo. In the dogfood we cloned + SHA-verified
**all 19 in-scope `datascience-intro` repos** (forks and archived repos excluded), each via
`bin/ias-git-clone-verified.sh` into `<base>/github/datascience-intro/public/<repo>`, each
ending in a `VERIFIED` line. Because every copy op ended with a SHA-verify, the local
`datascience-intro/` tree is a **complete, provably faithful W3 set** -- and each repo also
has (or gets) its server-side pull-mirror safety copy on `git.example.org`. Exclude forks
(they are not the canonical you want to follow) and archived repos (no upstream activity to
track) so the follow-copy set stays meaningful.

---

## Every copy op ends with a SHA-verify

This is the invariant that makes the whole bundle trustworthy: **"exit code 0" from
`git clone` / `push` / mirror-sync is not proof; a matching ref-SHA set is.** Step 1's clone
ends with a verify; Step 3's mirror sync ends with a verify. Full rationale (why a matching
ref SHA proves a byte-identical copy) and every integrity recipe:
`docs/WORKFLOWS.md`, "SHA integrity -- verify every copy".

---

## Summary (the W3 loop in five lines)

1. `bin/ias-git-clone-verified.sh` upstream -> local working clone under
   `<forge>/<org>/public/<repo>`; VERIFIED.
2. `git switch -c`, edit, commit, `git push -u origin`, `gh pr create --base main`
   (or fork + PR from the fork).
3. After upstream merges, capture `<merge-sha>` (`gh pr view N --json mergeCommit`).
4. Force / await the Forgejo pull-mirror sync on `git.example.org` (token in a header).
5. `bin/ias-git-verify.sh <upstream> <mirror> --ignore-refs 'refs/pull/*' --expect-sha
   <merge-sha>` -> green VERIFIED = the merged change is provably in your sovereign copy.
