# Sovereign-git SETUP

Adopter setup guide for the sovereign-git bundle: stand up your own canonical Forgejo,
mirror it out to the big forges for reach, keep it patched, back it up, and prove every
copy is faithful. This is the "install" companion to `docs/WORKFLOWS.md` (the day-to-day
operational recipes) and `README.md` (the model + motivation).

Throughout, `git.example.org` is a placeholder -- **replace it with your own domain.**
No hostname is baked into the scripts; you set yours via environment variables.

---

## 0. Prerequisites

- A Linux host you control (Debian/Ubuntu tested), reachable from the internet, that will
  run the canonical Forgejo. Root (or sudo) on that host.
- A domain + a **DNS A/AAAA record** for your canonical hostname (e.g. `git.example.org`)
  already pointing at that host's IP. Caddy provisions TLS via ACME, so the record must
  resolve before standup.
- Outbound HTTPS from the host (to reach `forgejo.org` for the binary + `codeberg.org`,
  and Let's Encrypt for TLS).
- `git`, `curl`, `gpg`, and `python3` available (the scripts check what they need).
- An **off-box, encrypted backup target** (a separate storage box, or a LUKS external
  disk you can unplug) -- see step 4.
- Accounts + API tokens on any public forges you want to mirror to (GitHub / GitLab /
  Codeberg), each with push credentials for the mirror repos.

---

## 1. Stand up the canonical server -- `bin/ias-git-server-standup.sh`

Installs Forgejo (verified binary), fronts it with Caddy for automatic TLS, hardens the
Forgejo `app.ini`, and wires a systemd service + firewall (443 + SSH only).

**You MUST set `GIT_DOMAIN`** to your own canonical hostname -- the default is the neutral
placeholder `git.example.org`, which is not yours. Nothing works until you set it:

```
GIT_DOMAIN=git.example.org bash bin/ias-git-server-standup.sh all
```

Sub-commands (`install`, `caddy`, `harden`, `firewall`, `all`) let you run the phases
individually; `all` does the full sequence. Other knobs (all optional, sensible defaults):
`FORGEJO_VERSION`, `FORGEJO_USER`, `FORGEJO_HOME`.

**Confirm the Forgejo binary signature.** Standup FAILS CLOSED: it verifies the downloaded
Forgejo binary against its published `sha256` **and** a GPG signature from a **pinned**
release-signing fingerprint (`FORGEJO_GPG_FINGERPRINT`). There is no skip path. Before
first use, confirm the pinned fingerprint out-of-band against `https://forgejo.org/download`
and, if Forgejo has rotated it, override with a fingerprint you have independently checked.
A MITM serving a different key aborts the install.

After standup: browse to `https://git.example.org` (your value), complete the Forgejo
first-run admin setup, and create the org/repos you will mirror.

---

## 2. Mirror out to the big forges -- `bin/ias-git-mirror-setup.sh`

Configures per-repo **push-mirrors** from your canonical Forgejo OUT to GitHub + GitLab +
Codeberg, using Forgejo's built-in push-mirror feature. The canonical stays the origin;
the public hosts are downstream, reach-only reflections. **Only public repos** are
mirrored; never mirror a private (e.g. jurisdiction-sensitive) repo out.

DRY-RUN by default -- it prints what it would create. Tokens go in the **environment only**,
never on the command line:

```
FORGEJO_URL=https://git.example.org OWNER=YourOrg REPO=your-repo \
  bash bin/ias-git-mirror-setup.sh plan          # dry-run: show planned mirrors
FORGEJO_URL=https://git.example.org OWNER=YourOrg REPO=your-repo \
  bash bin/ias-git-mirror-setup.sh apply         # actually create them
```

Set `FORGEJO_URL` to your canonical base URL and provide `FORGEJO_TOKEN` plus the per-host
`*_MIRROR_URL` / `*_MIRROR_TOKEN` pairs for whichever forges you want. A host is skipped
(with a note) if its URL/token pair is absent -- partial mirroring is fine.

---

## 3. The contribution loop (W1 / W2 / W3)

The point of the bundle is that contributions raised on **any** forge come back to your
canonical, get merged there, and the merge push-mirrors back out -- closing the loop.
The operational recipes for these workflows live in **`docs/WORKFLOWS.md`**:

- **W1 -- collate an inbound contribution:** a maintainer fetches a PR/MR by its per-forge
  ref (`refs/pull/N/head` on GitHub/Forgejo, `refs/merge-requests/N/head` on GitLab) onto
  a `contrib/<forge>/pr-N` branch on canonical, reviews, and merges there
  (`bin/ias-git-pull-contribution.sh`; forge-agnostic via the L2 adapters in `relay/`).
- **W2 -- verify the mirror caught up:** after merging on canonical, confirm the mirror's
  HEAD equals the exact merge commit SHA (`bin/ias-git-verify.sh --expect-sha`).
- **W3 -- prove any copy is faithful:** compare all ref SHAs between two endpoints.

See `docs/WORKFLOWS.md` for the exact commands and the L0 `CONTRIBUTING` redirect that
tells contributors on any mirror that their PR will be relayed upstream
(`CONTRIBUTING.template.md`).

---

## 4. Keep it patched -- `bin/ias-git-server-update.sh`

A self-hosted forge you never patch is a liability. This script auto-updates Forgejo
**safely**: it never swaps the binary unless the download is provably the authentic Forgejo
release (sha256 + GPG against the pinned fingerprint), with backup + rollback + smoke test.

```
bin/ias-git-server-update.sh --check                 # installed vs latest (exit 10 = update available)
bin/ias-git-server-update.sh                          # DRY-RUN: check + verify, no changes
bin/ias-git-server-update.sh --apply                  # verify then actually update
bin/ias-git-server-update.sh --install-timer          # weekly systemd timer (runs on the host, as root)
```

Confirm the pinned signing fingerprint before first use. `--install-timer` also prints the
steps to enable Debian/Ubuntu `unattended-upgrades` for OS-level patches -- two layers:
the timer patches Forgejo, unattended-upgrades patches the OS.

---

## 5. Back it up -- `bin/ias-git-backup.sh` + RESURRECTION-DRILL.md

Runs on the Forgejo host. Bundles `forgejo dump` (DB + all repos + LFS + attachments +
config) into one archive and pushes it with `restic` to an **off-box, encrypted**
repository. "A backup you have never restored is not a backup," so it also drives a
restore drill.

```
RESTIC_REPOSITORY=... RESTIC_PASSWORD=... bash bin/ias-git-backup.sh backup         # dump + restic + prune
RESTIC_REPOSITORY=... RESTIC_PASSWORD=... bash bin/ias-git-backup.sh restore-drill  # restore + assert non-empty
RESTIC_REPOSITORY=... RESTIC_PASSWORD=... bash bin/ias-git-backup.sh status         # snapshots + last-backup age
```

For the sovereignty backstop, point `RESTIC_REPOSITORY` at a LUKS-encrypted external disk
you can unplug and carry. Schedule `backup` nightly (cron / systemd timer). Then rehearse
a full rebuild-from-cold using **`RESURRECTION-DRILL.md`** -- the step-by-step walk that
proves you can resurrect the server from backups alone.

---

## 6. Verify every copy -- `bin/ias-git-verify.sh` / `bin/ias-git-clone-verified.sh`

A git ref SHA is a Merkle root over the whole reachable history, so if every ref (branches
+ tags) on the source resolves to the **same** SHA on the destination, the two repos are
provably byte-identical. This is the cheap, network-only integrity proof that every copy op
should end with.

```
bin/ias-git-verify.sh <src> <dst>                     # compare ALL ref SHAs; exit 0 = faithful copy
bin/ias-git-verify.sh <src> <dst> --ignore-refs 'refs/pull/*'   # e.g. a pull-mirror lacking PR refs
bin/ias-git-verify.sh <src> <dst> --head-only --expect-sha <sha># assert dst HEAD == a known merge SHA
bin/ias-git-clone-verified.sh <remote> <dest>         # full clone, then verify; VERIFIED only if faithful
```

`--ignore-refs` globs **must** be anchored at `refs/` and are rejected otherwise; an
over-broad ignore that would strip every comparable ref from one side FAILS rather than
falsely reporting VERIFIED. Tokens are never printed -- pass auth via the environment / a
git credential helper / ssh config.

**Rule of thumb:** every migrate / mirror-sync / clone / backup-restore ends with a verify;
after a PR-merge, verify the mirror HEAD == the merge SHA. Full recipes: `docs/WORKFLOWS.md`.
Local (no-network) test of these tools: `bash tools/tests/test_sha_verify.sh`.

---

## Where to go next

- `README.md` -- the model, the motivation (CLOUD Act / sanctions), and the bundle layout.
- `docs/WORKFLOWS.md` -- the operational recipes (SHA integrity + the contribution loop).
- `RESURRECTION-DRILL.md` -- rebuild-from-cold rehearsal.
- `docs/WORKFLOWS.md` -- the full design and operational recipes.
