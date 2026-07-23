# How-to: incremental public release + the allow-lines file

A step-by-step a human can follow (no agent) to ship an **update** to a repo you already
published with W4 — as a **no-force-push child commit**, and how to tell the leak-gate that a
specific line (e.g. your own brand in a LICENSE, or a link to your own site in a README) is
**intentionally public**.

Placeholders: `git.example.org` = your own sovereign Forgejo; `your-org` = your public
org; `<repo>` = the repo name; `<src>` = the private source path. Replace with yours.

---

## When to use this (incremental) vs a fresh squash

- **First release / re-baseline:** `--method squash` — builds a fresh single-commit public repo.
- **Every update after that:** `--method incremental --onto <prior>` — rebuilds the L1 tree and
  commits it **on top of** the existing public history. No force-push, so mirrors and clones stay
  fast-forwardable and no reader's clone breaks.

## Prerequisites (once)
- The repo is already published publicly (you have the prior public canonical, local or by URL).
- You know the **allowlist** for this repo (which files are L1-public). Keep it recorded so you do
  not reconstruct it each time (we keep ours in a per-repo release recipe).

## Step 1 — allow-lines: mark intentionally-public lines
> First time? Set up your `.leakscan-deny.txt` from `examples/leakscan-deny.example.txt` before this
> step (see README.md / WORKFLOWS.md). The allow-lines file below only makes sense once you have a
> deny list to make exceptions *to*.

The leak-gate blocks any confidential/deny term (from *your* `.leakscan-deny.txt`) unless the
**whole line** is vetted. Some lines are *meant* to be public even though they contain a deny term
— e.g. your own org name in a copyright line, or a link to your own website in the README.

For each such line, put the **exact whole line** into an allow-lines file:

```
# my-repo.allow-lines.txt  (one exact, whole line per entry)
Copyright 2026 Example Org
- Home page: https://example.org/
```

Rules: the match is a **whole-line exact match** (un-gameable — a broad allow substring cannot
leak a different secret on the same line). A starter template ships at
`examples/leakscan-allow-lines.example.txt`. Keep this file **private/local** — it is release
config, not something you publish.

## Step 2 — stage the incremental release (nothing is published yet)
```
bin/ias-git-declassify.sh <src> <staging-dir> \
  --allow '<glob>' [--allow '<glob>' ...] \
  [--deny '<glob>' ...] \
  --leak-allow-lines-file my-repo.allow-lines.txt \
  --ack-review \
  --method incremental --onto <prior-public-canonical> \
  --name <repo>
```
`ias-git-declassify.sh` **only stages** — it never pushes, never touches a forge. The staging dir
must not already exist.

## Step 3 — read the staged result (this is your review gate)
A clean run prints:
- `selected N L1 file(s)` — confirm N is the file count you expect.
- `incremental commit added. HEAD=… total-commits=M` — the new child commit on top of the prior tip.
- `4a … PASS` (working-tree confidentiality), `4b … PASS` (internal-leak),
  `4d (AF-INCR-1) … PASS` (**every inherited commit is re-scanned** under the current gate).
- `DECLASSIFY STAGED OK`.

If **4d FAILS** with "a leak persists in INHERITED history", an *older* published commit contains a
deny term that is not allow-lined. If it is intentionally public, add that exact line to your
allow-lines file (Step 1) and re-run. If it is a real secret, you must scrub or re-baseline
(`--method squash`) before publishing — never publish over it.

## Step 4 — publish + mirror + verify (only after review + approval)
Declassify staged; publishing is a separate, deliberate act:
1. Push the staged repo to your public canonical `git.example.org/your-org/<repo>` (SSH; fast-forward —
   an incremental release is a child commit, so it never needs `--force`).
2. **Mirror OUT (push-mirror, W1).** `bin/ias-git-mirror-setup.sh` (one-time per repo) configures Forgejo
   to push-mirror the canonical OUT to GitHub + GitLab + Codeberg; after that they sync on Forgejo's own
   interval. To force an **immediate** sync **and** prove every endpoint matches, run:
   ```
   GITVW_API=https://git.example.org/api/v1 \
   bin/ias-git-protect-mirrors.sh <github owner/repo> <gitlab group/path> <codeberg owner/repo> verify
   ```
   (tokens via env: `GITHUB_TOKEN`, `GITLAB_TOKEN`, `CODEBERG_TOKEN`, `GITVW_FORGEJO_TOKEN` — never on argv).
   It POSTs `push_mirrors-sync`, waits for the async push, then compares the canonical + all 3 mirror SHAs.
   > Note: `ias-git-mirror-sync.sh` is for the **pull**-mirror case (W3, following a repo you do not own) —
   > it is NOT the tool for pushing your own repo out. Use `ias-git-protect-mirrors.sh … verify` here.
3. **Verify** (standalone, no tokens): `bin/ias-git-verify.sh <canonical> <mirror>` — `git ls-remote` both
   and diff; each mirror's `main` SHA must equal the canonical's. (Step 2's `verify` already does this
   4-way; this is the independent re-check.)
4. Record the release (SHA + date) in your linkage ledger so the public copy is never lost.

---
**Two proofs, not one:** private→public (declassify) is intentionally lossy — verified by the
leak-gate + full-history scan, NOT a SHA match. public→mirrors is byte-identical — verified by SHA.
