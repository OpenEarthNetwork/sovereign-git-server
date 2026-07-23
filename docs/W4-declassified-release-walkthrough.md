# W4 (declassified release) -- walkthrough

A worked example of the **W4 declassified-release** workflow: turning a repo you own that
carries **private layers** (L1 public + L2 shared-internal + L3 proprietary) into a clean,
history-safe, leak-gated **L1-only public release** -- without ever exposing L2/L3 code or
history. This is distinct from W1 (mirror a repo *whole*, byte-identical) and from W3
(follow a repo someone else owns): W4 is for **our own layered repos** that must ship a
public subset.

Throughout, `git.example.org` is a placeholder for **your own** sovereign Forgejo domain,
and `OpenEarthNetwork` is the canonical public org. Replace with yours.

---

## What W4 is (and is not)

- **Two canonicals, not one.** The **private canonical** (full L1+L2+L3) is where
  development happens and is **never** mirrored out. The **public canonical** (L1-only,
  declassified) is a *separately built* repo -- and the only one that is ever
  W1-mirrored to the big forges.
- **It is intentionally lossy.** The public snapshot is NOT a byte copy of the private
  repo, so a ref-SHA match is the wrong proof. W4 verifies by **leak-gate + full-history
  scan + allowlist assertion** instead (see WORKFLOWS.md "Split SHA-verify").
- **History-safe by construction.** Deleting files is not enough -- git history keeps
  them. W4 builds a fresh history (squash) or rewrites it (filter-repo), so no L2/L3 byte
  survives in any reachable object.
- **It never publishes by itself.** `bin/ias-git-declassify.sh` only *stages* a snapshot for
  review. Publish + mirror + ledger-record happen later, op-gated.

---

## Prior real example -- openearth-gryph (W4 before it had a name)

W4 formalises something we had already done by hand:

- **Private canonical:** our private GitLab repo (`gitlab.example.org/<org>/openearth-gryph`)
  -- a specific HEAD (call it `PRIV`), `main` + a release tag (full, private).
- **Public canonical:** `codeberg.org/openearth/openearth-gryph` -- `main` `3a8aea37`,
  with a **distinct** top commit (*"release: switch to codeberg.org/openearth/openearth-gryph ..."*).

The public HEAD `3a8aea37` is **not** the private HEAD `PRIV`: the public copy is a
separately-committed, declassified snapshot, not a byte mirror. That is exactly W4 -- but
done manually, unreviewed, untracked, and (the cautionary part) its public location was
**later lost and had to be hunted for**. W4 tools + the linkage ledger fix all three:
repeatable, reviewed, recorded.

---

## The tooled pipeline -- `bin/ias-git-declassify.sh`

The first *tooled* W4 dogfood is the sovereign-git bundle itself: the private repo carries
the bundle under `tools/sovereign-git/` alongside all our L2/L3 substrate, and the public
release is just the bundle as a standalone repo.

### 1. Declassify (stages a snapshot; publishes nothing)
```
bin/ias-git-declassify.sh . ../sovereign-git-standalone \
  --allow 'tools/sovereign-git/*.sh' \
  --allow 'tools/sovereign-git/relay/*' \
  --allow 'tools/sovereign-git/docs/*' \
  --allow 'tools/sovereign-git/*.md' \
  --allow 'tools/sovereign-git/CONTRIBUTING.template.md' \
  --allow 'tools/tests/test_sha_verify.sh' \
  --method squash --name sovereign-git-server --record
```
What each step does (all gated; aborts loudly on any failure):
1. **materialise** the private source into a temp workdir -- the local path is treated
   **read-only** (copied out, never mutated).
2. **select L1** -- only the `--allow`ed paths survive (`--deny` subtracts even under an
   allow). Omitting `--allow` is a hard error; the tool never defaults to "publish all".
3. **history-safe** -- `--method squash` (default) `git init`s a fresh repo with ONE
   commit, so **zero** history is inherited from the private repo. (`--method filter`
   uses `git filter-repo` to keep only the L1 paths across full history, when L1 history
   has real value.)
4. **leak-gate** -- the allowlist-aware confidentiality scanner (`ias-git-leakscan.sh` in the
   public standalone; `check-confidentiality.sh` + `check-no-internal-leak.py` internally) runs
   over the staged tree, plus a narrow history scan for any explicit `--deny-term`. Deny terms are
   matched as FIXED strings. A match resolves in order: whole line in the **allowed-LINES** file
   -> passes silently; else an allow *term* that SUBSUMES it -> inferred-attribution REVIEW
   (exit 3, never silent); else a **hard leak** (exit 1, aborts). Whole-line vetting can't be
   gamed by a broad allow substring co-located with a different confidential substring. Clear a
   review with `--leak-allow-lines-file F` + `--ack-review` (op-gated) or by vetting each line
   interactively. **Any hard leak aborts**, nothing staged.
5. **stage** -- the clean snapshot is left in `../sovereign-git-standalone/`; the tool
   prints the file list, the commit SHA, and the PASS verdict. Exit 0 = staged clean.

### 2. Independent leak-gate review (human + second agent)
The staged tree goes to a human and an independent agent (the "G-E" second-eyes pass) for
an adversarial confidentiality read -- residual internal idioms, names, paths, provenance
headers -- on top of the automated gate. Nothing publishes until this clears.

### 3. Publish + mirror + record (op-gated)
On explicit operator approval:
- create the **public canonical** `git.example.org/OpenEarthNetwork/<name>` and push the
  staged snapshot to it;
- **W1-mirror** it out with `bin/ias-git-mirror-setup.sh apply` (GitHub + GitLab + Codeberg);
- **SHA-verify** each mirror against the public canonical with `bin/ias-git-verify.sh`
  (byte-identical here -- ref-SHA match is the right check now);
- add the **publish record** to `.ias/declassified-releases.json` so the private<->public
  linkage is never lost.

---

## Dogfood transcript (sov-git bundle -- first tooled W4)

The real `bin/ias-git-declassify.sh` run over the sov-git bundle itself, leak-gate **PASS**
(host-specific paths generalised):

```text
$ bin/ias-git-declassify.sh tools/sovereign-git <staging> \
    --allow '*' --deny 'SECURITY-REVIEW-*.md' --deny 'TESTING.md'
== STEP 1/5 MATERIALISE private source ==
== STEP 2/5 SELECT L1 (allowlist minus denylist) ==
  selected 31 L1 file(s)                       # .git + __pycache__/*.pyc auto-skipped
== STEP 3/5 HISTORY-SAFE = squash (fresh git init + ONE commit) ==
bin/ias-git-scrub-provenance.sh: scrubbed 78 provenance-header line(s) + 29 agent-token(s) across 26 file(s)
  fresh single-commit repo built. snapshot HEAD=<sha>
== STEP 4/5 LEAK-GATE (working tree + full-history object scan) ==
  4-pre. binary-file guard (F1 residual, fail-closed)
     text-scannable: 31 file(s); binary/unscannable: 0 file(s)
  4a. check-confidentiality.sh over staging working tree
     PASS (confidentiality)
  4b. check-no-internal-leak.py over staging working tree
     PASS (internal-leak)
  4c. history scan for explicit --deny-term secrets only
     SKIP (squash: single commit == tree, already covered by 4a/4b)
== DECLASSIFY STAGED OK ==
  leak-gate verdict : PASS (confidentiality + internal-leak + --deny-term history scan)
```

Read the pipeline top-to-bottom: the **scrub** step strips the internal provenance headers
and maps author identities to neutral roles; the **binary guard** fails closed on anything
the text scanners cannot inspect; the **leak-gate** then confirms the staged tree is clean.
The staged tree is left in place for a human plus an independent second-eyes review, and
nothing is published until an explicit go.

---

## When to use which workflow

| Situation | Workflow |
|---|---|
| Clean repo, we own it (public from the start) | **W1** -- own -> canonical -> byte-identical mirrors |
| Clean repo, someone else owns it | **W3** -- follow-copy + PR upstream |
| **Layered repo (L1+L2+L3), we own it, want a public release** | **W4** -- declassify -> public canonical -> then W1 from there |
| A contribution comes back on a mirror | **W2** -- relay to the (public) canonical |

---

## Updating an existing release -- `--method incremental` (no force-push)

The first release uses `--method squash` (or `incremental` with no `--onto`): a single clean commit.
For every SUBSEQUENT release, use **`--method incremental --onto <prior-canonical>`** so the new
release is a **child commit** of the prior published tip -- not a fresh unrelated root:

```
ias-git-declassify.sh <src> <staging> --allow '<globs>' --method incremental \
    --onto ssh://git@<your-forge>/<Org>/<repo>.git
```

It clones the prior published canonical (full public history), rebuilds the tree from the current
`--allow` selection + scrub, and commits on top. The push then **fast-forwards** (never `--force`), so
anyone who cloned or forked just `git pull`s -- their history is never rewritten. It is **idempotent**
(an unchanged tree produces no commit). Leak-safety is identical to squash and preserved across the
chain: the private `.git` is never cloned, so the published history is only ever a sequence of scrubbed
public trees. Avoid re-`squash`ing an already-published repo -- that makes an unrelated root and forces
a history-rewriting push.
