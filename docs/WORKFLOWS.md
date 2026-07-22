# Sovereign-git WORKFLOWS

Operational recipes for the sovereign-git bundle. This file grows one section per
copy/coordination op. The first (and most load-bearing) section is SHA integrity:
it is the check that turns "we copied the repo" into "we PROVED the copy is faithful."

---

## SHA integrity — verify every copy

### Why a matching ref-SHA proves a byte-identical copy
A git object name (the "SHA") is the hash of the object's **content plus everything it
transitively points at**. A commit's SHA covers its tree (every file blob + subtree)
**and** its parent commit SHA(s) — which in turn cover their trees and parents, all the
way back to the root commit. So a ref (branch/tag) SHA is a Merkle root over the entire
reachable history. If `refs/heads/main` on the source resolves to the **same** SHA as on
the destination, every commit, tree, and blob in that branch's history is identical byte
for byte. Compare **all** refs and you have proven the whole repo is a faithful copy —
without transferring a single object, just two `git ls-remote` calls.

This is why **every** sovereign-git copy op must end with a verify:
migrate, mirror-sync, clone, backup-restore. "Exit code 0" from `git clone`/`push` is
not proof; a matching ref-SHA set is.

### The tools
- **`bin/ias-git-verify.sh <src> <dst> [opts]`** — `git ls-remote` both endpoints, normalise
  (drop `refs/remotes/*` client-side tracking bookkeeping, sort by ref name), diff.
  - Exit **0** = every compared ref SHA matches (faithful copy).
  - Exit **1** = mismatch; the differing refs are printed (`src-only` / `dst-only`).
  - Exit **2** = usage / endpoint-unreachable error.
  - `--head-only` — compare just HEAD (the default branch tip).
  - `--ignore-refs '<glob>'` — omit refs matching the glob from BOTH sides (repeatable).
    Use `refs/pull/*` (GitHub/Forgejo) or `refs/merge-requests/*` (GitLab) when a
    pull-mirror does not carry PR refs — you still verify all branch + tag SHAs.
  - `--expect-sha <sha>` — assert dst HEAD == this exact SHA (e.g. a merge SHA).
  - Tokens are **never printed**; auth goes to git via ssh config / credential helper / env.
- **`bin/ias-git-clone-verified.sh <remote> <dest> [--ignore-refs <glob>]`** — full clone,
  then `ias-git-verify` the clone against the remote. Reports VERIFIED only on a full
  ref-SHA match. This is the "SHA-confirming clone" for copy ops.

### Recipe 1 — verify a migrated / mirrored repo is faithful
```
bin/ias-git-verify.sh <source-url> <dest-url>
```
For a **pull-mirror** that may not replicate PR refs, ignore them:
```
bin/ias-git-verify.sh <source-url> <mirror-url> --ignore-refs 'refs/pull/*'
```
Exit 0 => the mirror is a faithful copy of the source (all branch + tag SHAs match).

### Recipe 2 — SHA-confirming clone (backup / working copy you must trust)
```
bin/ias-git-clone-verified.sh <remote-url> <dest-dir>
```
Clones full, then verifies. "VERIFIED" => the local copy is byte-identical to the remote.

### Recipe 3 — after a PR-merge, verify the mirror caught up to the merge SHA
When you merge a contribution on the canonical (`git.example.org`) and it push-mirrors
out, confirm the mirror HEAD now equals the exact merge commit SHA:
```
bin/ias-git-verify.sh <canonical-url> <mirror-url> --head-only --expect-sha <merge-sha>
```
Exit 0 => the mirror's default-branch tip is exactly the merge commit — the loop closed
faithfully. Exit 1 => the mirror has not converged (or diverged); do not trust it yet.

### Recipe 4 — backup / restore drill
After a `forgejo dump` restore (or restic restore) into a fresh Forgejo, verify each
restored repo against a known-good source (or against the recorded pre-disaster SHAs):
```
bin/ias-git-verify.sh <known-good-url> <restored-url>
```
Only a full ref-SHA match certifies the restore.

### Endpoint / auth notes (this environment)
- HTTPS git hosts do not resolve inside the agent sandbox; **use SSH** endpoints
  (`ssh://git@github.com/<owner>/<repo>.git`, `ssh://git@git.example.org/<owner>/<repo>.git`).
  Wire your canonical SSH key via `~/.ssh/config` (Host `git.example.org`).
- For HTTPS-only automation, put the Forgejo token in the environment / a git credential
  helper — never on the command line, never echoed.

### Proof this works
- Local (no network): `bash tools/tests/test_sha_verify.sh` — local bare repos, 11
  assertions (identical PASS; tampered dst FAIL exit 1; `--expect-sha` match/mismatch;
  `--ignore-refs` hides a `refs/pull/*` divergence; H3 over-match guard: narrow ignore
  still VERIFIES a faithful pair, over-broad `refs/*` FAILS, non-`refs/` glob rejected
  exit 2, ERE metachar treated literally; clone-verified VERIFIED). All GREEN.
- Real read-only dogfood (2026-07-21): `datascience-intro/CanvasInterface`,
  github (`ssh://git@github.com/...`) vs canonical pull-mirror (`ssh://git@git.example.org/...`),
  `--ignore-refs 'refs/pull/*'` => **VERIFIED**, HEAD + `refs/heads/main` both
  `7e6726dcf5e0ee7c6cb00db113829b2f0629660d`. The pull-mirror is faithful.

---

## W1 (own-and-mirror) -- your repo, canonical on your Forgejo, mirrored OUT

For a repo **you own**: keep it canonical on `git.example.org` and push-mirror it OUT to
GitHub + GitLab + Codeberg as read-only, byte-identical reach copies, then SHA-verify all
four endpoints resolve to the same SHA. Full worked example (real dogfood:
`OpenEarthNetwork/openearth-gryph` imported as canonical -> 3 empty mirror repos ->
`bin/ias-git-mirror-setup.sh apply` -> `push_mirrors-sync` -> all 4 endpoints == `3a8aea37` +
all 4 anon reader links == 200): `docs/W1-own-and-mirror-walkthrough.md`.

---

## W2 (contribute-back) -- absorb a mirror PR to canonical, merge, mirror back, close

A contributor PRs on one of your **mirrors** (fork it, never push to it -- the ~8h
force-sync would wipe a pushed branch); the relay absorbs it to canonical, you merge there,
the merge mirrors back out, and the original mirror PR is closed as ABSORBED (not rejected)
with the merge SHA. **git transport = SSH always; forge REST = HTTPS+token.** Full worked
example (real dogfood: github#1 on `OpenEarthNetwork/openearth-gryph` -> `ias-git-relay.py`
plan/relay/notify -> canonical PR#1 merged as `7ffe3cb9` -> all 4 endpoints == `7ffe3cb9`):
`docs/W2-contribute-back-walkthrough.md`.

---

## W3 (follow-copy) -- contribute upstream to a repo you do not own

When the canonical repo lives on **someone else's** forge (upstream stays canonical), you
keep a SHA-verified local working clone to branch + PR from AND a server-side pull-mirror on
`git.example.org` as a safety copy, then SHA-verify the merged result reached your mirror.
Full worked example (real dogfood: `datascience-intro/GenJSONnotebookGrader` PR #7, clone ->
branch -> PR -> merge -> mirror-sync -> `--expect-sha` proof): `docs/W3-follow-copy-walkthrough.md`.

---

## W4 (declassified release) -- publish a repo that has private layers, safely

Most repos we own carry three licensing layers -- **L1** public, **L2** shared-internal,
**L3** proprietary. W1 mirrors a repo *whole* --
so you **cannot** W1-mirror a layered repo outward: its L2/L3 code AND its history would
become public. W4 turns a layered private repo into a clean public release **safely**.

### Two canonicals, not one
A W4 repo has a **private canonical** (full L1+L2+L3; where real development happens;
**never** mirrored out) and a **public canonical** (L1-only, declassified; this is what
gets W1-mirrored to the big forges). Each release regenerates the public canonical from
the private one; only the public one ever leaves your control.

### History safety -- the sharp edge
Deleting L2/L3 files in a new commit is **NOT** enough: git history keeps every deleted
file, so a public clone would expose them in older commits. A W4 snapshot MUST be
history-safe by either **squash** (default -- a fresh single-commit repo, zero inherited
history) or **filter** (`git filter-repo` keeping only the L1 paths across all history).
Never a plain `rm` + commit.

### Split SHA-verify -- two proofs, not one
- **private -> public (declassify) is intentionally LOSSY** -- a ref-SHA match is the
  WRONG check. Verify by (a) leak-gate (`check-confidentiality.sh` +
  `check-no-internal-leak.py`) over the snapshot, (b) a full-history scan (no denylisted
  term / L2/L3 path in ANY object), (c) an allowlist assertion (only L1 paths present).
- **public -> mirrors (W1) is byte-identical** -- normal `bin/ias-git-verify.sh` ref-SHA match.

A W4 release therefore ends with TWO proofs: declassify (leak-gate + history scan) THEN
mirrors (SHA), not one.

### The tool -- `bin/ias-git-declassify.sh` (stages for review; never publishes)
```
bin/ias-git-declassify.sh <private-source> <staging-dir> --allow <glob> [--allow <glob>...] \
                      [--deny <glob>...] [--method squash|filter] [--deny-term <term>...] \
                      [--leak-allow-lines-file F] [--ack-review] [--record]
```
Pipeline, each step gated on the previous (aborts loudly on any failure): **materialise**
the source (a local path is treated strictly read-only) -> **select L1** (only the
`--allow` paths, allowlist beats denylist; **omitting `--allow` is an ERROR** -- it never
defaults to "publish everything") -> **history-safe** (squash by default) -> **leak-gate**
(the allowlist-aware confidentiality tools over the tree PLUS a narrow `--deny-term`
history scan; ABORT on any hit) -> **stage** the snapshot for review. It does **not**
publish, push, create a remote, or touch any forge. Exit 0 = staged clean; 1 =
leak-gate/pipeline failure (hard leak); 2 = usage/config error; 3 = leak-gate needs review
(inferred-attribution items only -- vet them, see below).

### Leak-gate review model (whole-line allowed-LINES; hardened 2026-07-22)
Deny/confidential terms are matched as FIXED strings (a term with a `[` or `\` cannot slip
past as a stray regex). A match is resolved in order: (1) the WHOLE line is present in an
**allowed-LINES** file -> passes silently (reviewed once, remembered); (2) an allow *term*
SUBSUMES the deny term on that line -> surfaced as an inferred-attribution REVIEW item
(exit 3), never silently dropped; (3) otherwise a hard leak (exit 1). Whole-line vetting
cannot be fooled by a broad allow substring overlapping a *different* confidential substring
on the same line. Clear review items by running the scan in a terminal (answer `y` to append
the exact vetted line), by adding lines to the allowed-LINES file, or -- for declassify --
with `--leak-allow-lines-file F` plus `--ack-review` (op-gated, after human review). The
adopter scanner is `bin/ias-git-leakscan.sh`; see its `--help` and
`examples/leakscan-allow{,-lines}.example.txt`.

### The linkage ledger -- never lose a public copy again
`--record` appends a staged entry to `.ias/declassified-releases.json` (private canonical,
public canonical, mirrors, method, source SHA, snapshot SHA, date); the publish record is
added later, op-gated. Motivating incident: `openearth-gryph` was declassified + published
to codeberg but its location was later lost -- recovered only by hunting.

### Then W1 from the public canonical
Once the staged snapshot passes leak-gate + human/independent-agent review + operator
approval, publish it to the public canonical (org `OpenEarthNetwork`) and mirror OUT with
`bin/ias-git-mirror-setup.sh` (W1), SHA-verifying each mirror.

Full worked example (the `openearth-gryph` prior release + the sov-git bundle as the first
tooled dogfood): `docs/W4-declassified-release-walkthrough.md`.

---

## Keeping the server patched (auto-secure-update)

A sovereign forge you never patch becomes the weakest link. `bin/ias-git-server-update.sh`
updates Forgejo **safely** — the binary is swapped **only** if it is provably the authentic
Forgejo release, and nothing irreversible happens without `--apply`.

### The guarantee: verify BEFORE swap (no bypass)
The pipeline gates each step on the previous, and steps 3a + 3b are **hard gates with no
skip flag**:
1. **CHECK** — resolve latest stable (or `--to <ver>`), compare to `forgejo --version`.
   Already current => clean **no-op** (idempotent).
2. **DOWNLOAD** — fetch the `linux-amd64`/`arm64` binary **+ its `.sha256` + its `.asc`**
   into a private `mktemp -d` (700, trap-cleaned). HTTPS only: `curl --fail --location
   --proto '=https' --tlsv1.2`. TLS is **never** disabled.
3. **VERIFY (HARD GATE)** — (a) `sha256sum` the binary == the published `.sha256`, **and**
   (b) the `.asc` GPG-verifies against the **pinned** Forgejo release-signing key. The key
   is imported into a throwaway keyring and its **fingerprint is checked against the pinned
   value** — a MITM serving a different key fails and the update aborts. Either check
   failing => abort, binary untouched, non-zero exit.
4. **BACKUP** — copy the current binary aside (versioned) + trigger a data backup
   (`bin/ias-git-backup.sh backup`, or a local `forgejo dump` fallback). Rollback + data-restore
   are both possible from here. If the data backup fails, the swap is refused.
5. **SWAP** (`--apply` only) — stop the service, write the new binary to a temp path on the
   **same filesystem** then `mv` (atomic rename), preserving mode/owner; start the service.
6. **SMOKE TEST** — service `active` + `forgejo --version` == new + a **loopback** HTTP
   health probe returns 2xx within `--health-timeout` (default 60s).
7. **ROLLBACK** — if the smoke test fails: restore the aside binary, restart, confirm the
   service is back on the **OLD** version, and exit non-zero **loudly**.
8. **ALERT** — a `STATUS: …` line on success **and** failure, written to `--status-file`
   and passed to an optional `--notify-cmd` (your alerting; nothing baked in).

### Recipe 1 — see what an update would do (safe, default)
```
bin/ias-git-server-update.sh --check      # installed vs latest (exit 0 current / 10 available)
bin/ias-git-server-update.sh              # dry-run: download + full sha256 + GPG verify, NO changes
```
Exit 0 + "DRY-RUN OK" => the latest release is authentic and ready; nothing was touched.

### Recipe 2 — actually update (root)
```
sudo bin/ias-git-server-update.sh --apply                 # to latest stable
sudo bin/ias-git-server-update.sh --to 9.0.3 --apply      # pin the target
```
Runs the full pipeline. On smoke-test failure it rolls back to the prior version by itself.

### Recipe 3 — schedule it + OS security updates
```
sudo bin/ias-git-server-update.sh --install-timer    # weekly forgejo-update.timer (Sun 04:30 + jitter)
bin/ias-git-server-update.sh --print-units           # inspect the unit text without writing
# OS layer (Debian/Ubuntu):
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```
`unattended-upgrades` patches the **OS**; the timer patches **Forgejo**. Two independent layers.

### Recipe 4 — wire it to your alerting (generic)
```
bin/ias-git-server-update.sh --apply --notify-cmd /usr/local/bin/my-alert.sh
```
`my-alert.sh` receives the final `STATUS: …` line as `$1` (never `eval`'d). Point it at
matrix/email/a webhook — the bundle hardcodes **no** channel/host/IP.

### Signing-key pinning (confirm before first use)
The 40-hex fingerprint of the Forgejo release-signing key is pinned in the script
(`FORGEJO_SIGNING_FPR_DEFAULT`). **Confirm it out-of-band** against
`https://forgejo.org/download/` ("Verifying release binaries") before your first run; if
Forgejo rotates the key, set `FORGEJO_SIGNING_FPR=<confirmed-fpr>` (env) or update the
constant. Never override the pin with a fingerprint you have not independently verified.

### Proof this works (no network, no server)
`bash tools/tests/test_server_update.sh` — a fake `forgejo` binary + a PATH-shadowed `curl`
serving local fixtures + a throwaway GPG key drive the **real** pipeline. Asserts: idempotent
no-op; update-available detection; dry-run makes no changes; **tampered checksum aborts**;
a **real valid signature from the pinned key verifies**; an **unpinned key is rejected on
fingerprint mismatch**; a tampered binary is caught by the sha256 gate; argparse rejects
unknown options. **15/15 GREEN** (+ the tool's built-in `--self-test`: version-compare,
sha256 gate, arch mapping — 14/14 GREEN).
