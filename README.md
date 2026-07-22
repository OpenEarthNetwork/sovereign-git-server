# Sovereign Git Server + Forge-Agnostic Contribution Coordination

**What this is:** a small, reproducible bundle for running **your own sovereign git server** ([Forgejo](https://forgejo.org)) as the *canonical* source of truth, **mirroring out** to GitHub + GitLab + Codeberg for reach, and — the hard part nobody ships — **collating contributions raised on any of those forges back to your canonical**, forge-agnostically.

**Why (the motivation).** Public developer platforms are under US jurisdiction. In **July 2019** GitHub, complying with US OFAC export sanctions, **cut off developers in Crimea, Cuba, Iran, North Korea, and Syria** — freezing private repos and refusing to let affected users even export their own data (Iran was only restored in Jan 2021). Separately, the **US CLOUD Act (18 U.S.C. §2713, 2018)** compels US-headquartered providers to disclose data "regardless of whether [it] is located within or outside of the United States" — which the EU's own regulators found in tension with **GDPR Art. 48**. The sovereign response is already real: the **Netherlands government runs its own Forgejo forge** (`code.overheid.nl`, 2026) "for digital sovereignty." This bundle lets any team do the same — *without* losing the reach of the big forges. (Full sourcing in the accompanying LinkedIn article.)

## The model (one line)
`git.example.org` (your Forgejo) is the **single canonical merge point**; GitHub/GitLab/Codeberg are **reach-only mirrors**; contributions raised on ANY forge are **pulled back to canonical**, merged there, and the merge **push-mirrors back out** — closing the loop. The forge-agnostic hook: every forge exposes each PR as a fetchable git ref (`refs/pull/N/head` on GitHub/Forgejo, `refs/merge-requests/N/head` on GitLab).

Full design: [docs/WORKFLOWS.md](docs/WORKFLOWS.md).

## Proof it works (dogfood)
```
bash examples/local-dogfood-harness.sh
```
Spins up local bare-repo stand-ins for the canonical Forgejo + all three mirrors and drives the **entire loop** — mirror-out → a contributor PR on each forge → relay-fetch-by-ref → merge on canonical → mirror-out → all three re-converge. **19/19 assertions GREEN**, zero external services. This is the git-mechanics proof; the forge-*API* adapters (list open PRs per forge) are tested against the real forges separately.

## SHA integrity — verify every copy
A git ref SHA hashes the commit object **and its entire ancestry** (tree + parents, recursively), so if every ref (branches + tags) on the source resolves to the **same SHA** on the destination, the two repos are provably **byte-identical**. That is the cheap, network-only integrity proof that every sovereign-git copy op should end with.

- `bin/ias-git-verify.sh <src> <dst>` — `git ls-remote` both endpoints, normalise (drop `refs/remotes/*` clone-bookkeeping; sort), diff. Exit 0 = faithful copy; exit 1 = mismatch (differing refs printed). Options: `--head-only`, `--ignore-refs '<glob>'` (e.g. `refs/pull/*` for a pull-mirror that doesn't carry PR refs; repeatable), `--expect-sha <sha>` (assert dst HEAD == a known SHA, e.g. a merge SHA). Never prints tokens.
- `bin/ias-git-clone-verified.sh <remote> <dest>` — full clone then verify; reports VERIFIED only when every ref SHA matches.

**Rule:** every copy op (migrate / mirror-sync / clone / backup-restore) ends with `ias-git-verify`; after a PR-merge, verify the mirror HEAD == the merge SHA. Full recipes: `docs/WORKFLOWS.md`.

**Docs:** `docs/SETUP.md` (adopter install) · `docs/WORKFLOWS.md` (operational recipes + SHA integrity) · `docs/W1-own-and-mirror-walkthrough.md` (worked example: your repo, canonical on your Forgejo, push-mirrored OUT + all-4-endpoints SHA-verified) · `docs/W2-contribute-back-walkthrough.md` (worked example: absorb a mirror PR to canonical, merge, mirror back, close as ABSORBED) · `docs/W3-follow-copy-walkthrough.md` (worked example: contribute upstream to a repo you follow but do not own).
Local test: the SHA-integrity test suite (no network; local bare repos) — see `TESTING.md`.
Dogfooded read-only on `datascience-intro/CanvasInterface` (github ↔ git.vw pull-mirror): ref SHAs match — the mirror is faithful.

## Confidentiality leak-gate — never publish a secret
Before you publish (or declassify a private repo to a public one), scan the tree for YOUR OWN
confidential strings with `bin/ias-git-leakscan.sh` (it ships with EMPTY term lists — you populate
them; there are no built-in secrets). Deny terms are matched as FIXED strings, so a term with a
`[` or `\` cannot slip past as a stray regex.

A deny match resolves in order:
1. the WHOLE line is present in your **allowed-LINES** file (`--allow-lines-file`, default
   `.leakscan-allow-lines.txt`) — passes silently (reviewed once, remembered). This is the primary
   review mechanism: whole-line vetting cannot be fooled by a broad allow substring co-located with
   a *different* confidential substring on the same line.
2. an allow *term* (`--allow-file`, `.leakscan-allow.txt`) SUBSUMES the deny term — surfaced as an
   inferred-attribution **review** item (exit 3), never silently dropped.
3. otherwise a **hard leak** (exit 1).

Review items are cleared interactively (a `y` appends the vetted whole line), by editing the
allowed-LINES file, or with `--ack-review`. Exit codes: 0 clean · 1 hard leak · 2 config/error ·
3 review needed. Get started by copying the templates:
```
cp examples/leakscan-deny.example.txt        .leakscan-deny.txt        # your confidential strings
cp examples/leakscan-allow.example.txt       .leakscan-allow.txt       # attribution terms (optional)
cp examples/leakscan-allow-lines.example.txt .leakscan-allow-lines.txt # vetted whole lines (optional)
```
`bin/ias-git-declassify.sh` runs this gate automatically over its staging tree (forward vetted lines
with `--leak-allow-lines-file` / `--ack-review`). See `bin/ias-git-leakscan.sh --help`.

## Bundle layout
| File | Role | Status |
|---|---|---|
| `local-dogfood-harness.sh` | End-to-end loop proof on local stand-ins | ✅ GREEN |
| `README.md` | This index | ✅ |
| `bin/ias-git-server-standup.sh` | Forgejo + Caddy TLS + `app.ini` hardening + systemd | ⏳ (per `designs/forgejo-hetzner-standup-plan-2026-07-19.md` §2) |
| `bin/ias-git-mirror-setup.sh` | Per-repo push-mirrors → github/gitlab/codeberg (Forgejo API) | ⏳ |
| `bin/ias-git-pull-contribution.sh` | L1: fetch a PR by ref from any forge → land on canonical | ⏳ (contributor) |
| `forge-adapters/` | L2: list open PRs per forge (github/gitlab/codeberg) | ⏳ (contributor) |
| `CONTRIBUTING.md` | L0: mirror redirect ("PRs on any mirror relayed upstream") | ⏳ (contributor) |
| `bin/ias-git-backup.sh` | `forgejo dump` + restic off-box | ⏳ (per standup §3) |
| `bin/ias-git-server-update.sh` | Auto-secure-update Forgejo: verify (sha256+GPG) BEFORE swap; dry-run default; backup + rollback + smoke test; systemd timer | ✅ (15/15 local tests GREEN; verify-before-swap hard gate) |
| `bin/ias-git-verify.sh` | SHA-integrity: prove two endpoints byte-identical by comparing ALL ref SHAs | ✅ (7/7 local tests GREEN; dogfooded on CanvasInterface github↔git.vw) |
| `bin/ias-git-clone-verified.sh` | SHA-confirming clone: full clone → `ias-git-verify` → VERIFIED/FAIL | ✅ |

## Keeping the server patched — `bin/ias-git-server-update.sh`
A self-hosted forge you never patch is a liability. This script auto-updates Forgejo **safely**:
it will **never** swap the binary unless the download is provably the authentic Forgejo release.

**Verify-before-swap (the hard guarantee).** The pipeline is: **check** latest stable (or `--to <ver>`)
→ **download** the linux-`amd64`/`arm64` binary + its `.sha256` + its `.asc` → **verify** (a) sha256 match
*and* (b) a valid GPG signature from the **pinned** Forgejo release-signing key → **backup** (copy the current
binary aside, versioned, + a data backup via `bin/ias-git-backup.sh` or `forgejo dump`) → **swap** (stop service,
atomically replace the binary on the same filesystem preserving mode/owner, start) → **smoke test** (service
active + `forgejo --version` == new + a loopback HTTP health probe within a timeout) → **rollback loudly** if
the smoke test fails. There is deliberately **no flag that bypasses** the sha256 or GPG verification, and **no
code path swaps an unverified binary**. TLS is never disabled (`curl --fail --proto '=https' --tlsv1.2`).

**Dry-run by default.** Without `--apply` the script does the check + download + full verification but makes
**zero changes** — it tells you what it *would* do. Only `--apply` performs the stop/swap/start. Re-running when
already current is a clean no-op (idempotent). Runs as **root** (it swaps a system binary + controls systemd).

**Signing-key pinning.** The 40-hex fingerprint of the Forgejo release-signing key is pinned as a constant
(`FORGEJO_SIGNING_FPR_DEFAULT`) with a comment telling you where to confirm it (forgejo.org/download). The key
is imported into a throwaway keyring and its fingerprint is checked against the pin; a MITM serving a *different*
key fails the fingerprint check and the update aborts. Override with `FORGEJO_SIGNING_FPR=` **only** with a
fingerprint you have independently confirmed. **Confirm the pinned fingerprint before first use.**

```
bin/ias-git-server-update.sh --check                 # report installed vs latest (exit 0 current, 10 update-available)
bin/ias-git-server-update.sh                          # dry-run: check + verify, NO changes
bin/ias-git-server-update.sh --apply                  # verify then actually update (to latest stable)
bin/ias-git-server-update.sh --to 9.0.3 --apply       # pin the target version
bin/ias-git-server-update.sh --print-units            # show the systemd timer + service unit text
bin/ias-git-server-update.sh --install-timer          # install + enable the weekly timer (root)
bin/ias-git-server-update.sh --self-test              # offline logic tests
```

**Scheduling + OS updates.** `--install-timer` writes `forgejo-update.service` + a weekly `forgejo-update.timer`
(Sun 04:30 + jitter, `Persistent=true`) under `/etc/systemd/system/` and enables it; the timer runs the update
with `--apply` and logs to the journal. It also prints the Debian/Ubuntu steps to enable **`unattended-upgrades`**
for OS-level security patches (`apt-get install -y unattended-upgrades; dpkg-reconfigure -plow unattended-upgrades`).
Two layers: `unattended-upgrades` patches the OS; the timer patches Forgejo itself. `--print-units` shows the unit
text without writing anything.

**Alerting (generic — no channel baked in).** On both success and failure the script prints a `STATUS: …` line and
writes it to `--status-file` (default `/var/log/ias-git-server-update.status`). Wire it to **your** alerting with
`--notify-cmd <cmd>`: the final status line is passed as the command's single argument (never `eval`'d), so point it
at a matrix/email/webhook sender of your choosing. Nothing organisation-internal is hardcoded.

Local test (no network, no server): the self-updater test suite (see `TESTING.md`) — a fake `forgejo` binary + a
PATH-shadowed `curl` serving local fixtures + a throwaway GPG key drive the real pipeline. Asserts the
idempotent no-op, dry-run-makes-no-changes, the sha256 tamper abort, a real valid-signature verify, an
unpinned-key rejection, and argparse. **15/15 GREEN.**

## Keeping the server patched — `bin/ias-git-server-update.sh`

A self-hosted forge you never update is a liability. `bin/ias-git-server-update.sh` safely
auto-secure-updates Forgejo, with the security property that **a binary is never swapped
unless it is provably the authentic Forgejo release**.

**The verify-before-swap guarantee (hard gate, no bypass).** The pipeline is: CHECK
(resolve latest stable or `--to <ver>`; compare to installed; no-op if current) → DOWNLOAD
(binary + `.sha256` + `.asc`, HTTPS-only, strict TLS) → **VERIFY** → BACKUP → SWAP → SMOKE
TEST → ROLLBACK-on-failure → ALERT. VERIFY is two mandatory checks with **no flag that
bypasses them and no code path that swaps an unverified binary**:
1. **sha256** of the downloaded binary must equal the published `.sha256`.
2. **GPG** `.asc` must verify against the pinned **Forgejo release-signing key**. The key is
   **fingerprint-pinned** (`FORGEJO_SIGNING_FPR`): the script imports the key into a throwaway
   keyring and *refuses it unless its fingerprint matches the pinned value*, so a MITM that
   serves a different key aborts the update. Confirm the pinned fingerprint out-of-band against
   `https://forgejo.org/download/` before first use; override via env if Forgejo rotates it.

If either check fails, the current binary is left untouched and the script exits non-zero.

**Dry-run default vs `--apply`.** Running with no `--apply` performs CHECK + DOWNLOAD +
VERIFY only and **makes no changes** — nothing irreversible happens without explicit intent.
`--apply` is required to stop the service, swap the binary (atomic `mv` on the same
filesystem, mode/owner preserved), and restart. Before the swap it copies the current binary
aside (versioned) and triggers a data backup (`bin/ias-git-backup.sh`, or a local `forgejo dump`
fallback) so both binary rollback and data restore are possible. After restart it smoke-tests
(service `active` + `forgejo --version` == new + loopback HTTP health probe); on failure it
**rolls back to the old binary, restarts, verifies the old version is back, and exits non-zero
loudly**. Must run as root (it swaps a system binary + controls systemd).

```
bin/ias-git-server-update.sh --check                 # report installed vs latest (exit 10 = update available)
bin/ias-git-server-update.sh                          # DRY-RUN: check + verify, no changes
bin/ias-git-server-update.sh --apply                  # verify then actually update to latest stable
bin/ias-git-server-update.sh --to 9.0.3 --apply       # pin the target version
```

**Scheduling + OS updates.** `--install-timer` writes a `forgejo-update.service` +
`forgejo-update.timer` (weekly, randomized delay) that runs the updater, and prints the steps
to enable Debian/Ubuntu `unattended-upgrades` for **OS** security patches (the timer patches
Forgejo; unattended-upgrades patches the OS). `--print-units` shows the unit text without
writing anything.

**Wiring alerting (generic; nothing baked in).** On both success and failure the script emits
a `STATUS:` line, writes it to `--status-file` (default `/var/log/ias-git-server-update.status`),
and — if you pass `--notify-cmd <cmd>` — runs your command with the status line as its single
argument. No internal channel/host/IP is hardcoded; point `--notify-cmd` at your own matrix
hook / email / webhook, or scrape the status file / journal.

Local test (no network, no server): the self-updater test suite (see `TESTING.md`) — a fake
`forgejo` binary + a PATH-shadowed `curl` serving local fixtures + real throwaway GPG keys.
Asserts idempotent no-op, update-available detection, dry-run-makes-no-changes, tampered
checksum aborts, unpinned/attacker signing key rejected on fingerprint mismatch, and a
tampered binary caught by the sha256 gate. **15/15 GREEN** (plus the built-in `--self-test`,
14/14). Never touches the live server.

## Layered contribution model (escalating)
- **L0** — `CONTRIBUTING` redirect on every mirror (zero build).
- **L1** — maintainer fetches a PR by its per-forge ref, applies on canonical (forge-agnostic; `gh`/`glab`/`tea`).
- **L2** — relay bot: watch each mirror's PR API → fetch → land `contrib/<forge>/pr-N` on canonical → open Forgejo PR → CI → comment back. *No turnkey tool exists — this is the build.*
- **L3** — side doors: AGit-flow + patch/email (`git format-patch`/`b4`).
- **Not** ForgeFed (experimental in 2026; GitHub/GitLab don't speak it).

## Status
Local dogfood GREEN — canonical + all three mirrors, the full contribute-back loop, zero external services. SHA-integrity and auto-secure-update tools tested (verify-before-swap, 15/15 GREEN). Real-forge instantiation and production server operations are left to the adopting team. Released alongside the sovereign-git LinkedIn article.

## Digital Public Good

This bundle is offered as a Digital Public Good — open source (Apache-2.0), useful, and built so anyone can run and leave it without dependence on us.

- **Relevance (SDG 9 and 16).** It helps any team — a company, a public body, a research group — keep sovereign control of its source code and version history on infrastructure it governs, while still collaborating on the big public forges. That serves resilient digital infrastructure (SDG 9) and the institutional independence and transparency behind strong, accountable institutions (SDG 16).
- **Platform independence.** Nothing here is tied to a single vendor. The canonical server is self-hosted Forgejo; the mirror and contribute-back tools are forge-agnostic and work across GitHub, GitLab, and Codeberg alike; every dependency is free and open (git, Forgejo, restic, curl, GnuPG). You can adopt any part without adopting a proprietary platform.
- **Data portability.** Your data is plain git — commits and refs — which is inherently portable: clone it anywhere. A full backup is a single restic snapshot (or Forgejo dump) that restores onto any host, and every copy is provably faithful via ref-SHA verification (`bin/ias-git-verify.sh`). There is no proprietary export step and no lock-in.
- **Open standards and best practice.** The bundle stands on open standards throughout — git, HTTPS/TLS, and OpenPGP signature verification — with fail-closed security gates (sha256 + pinned-key GPG before any binary swap), tested behaviour (see `TESTING.md`), and DCO sign-off for contributions. Releases track upstream Forgejo's published versions.
