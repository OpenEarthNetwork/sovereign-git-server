
# Sovereign-git resurrection drill: rebuild the whole forge from the cold walk-away disk

**Why this exists.** A backup you have never restored is not a backup. The sovereign-git bundle's cold
tier is an **encrypted disk you can unplug and carry** (restic repository on a LUKS volume) holding the
full server state. This drill proves the promise: starting from nothing but that disk, you can bring the
entire forge back - repositories, issues, pull requests, users, and configuration. Run it on a schedule
(e.g. quarterly) and after any major upgrade.

## What the cold disk must contain (produced by `bin/ias-git-backup.sh`)
1. A **Forgejo dump** (`forgejo dump`) - the server's database, config, repositories, issues, pull
   requests, releases, attachments, and LFS objects, as one archive.
2. (Belt-and-suspenders) **git bundles / a full mirror** of every repository, so the repos are
   restorable even without the dump.
3. The restic repository holding the above is itself on a **LUKS-encrypted** external disk.

## The drill (restore into a FRESH, blank box - never the live server)

Do this on a throwaway VM or spare machine so a mistake can never touch production.

1. **Unlock the disk.** Attach the external drive and open the LUKS volume; mount it read-only if your
   tooling allows. Confirm you are reading the cold copy, not writing to it.
2. **Verify the backup before trusting it.** Run the restic integrity check against the repository on the
   disk (`restic check`). A cold copy that does not pass its own integrity check is not a resurrection
   source - stop and investigate.
3. **Stand up a blank Forgejo** on the fresh box at the SAME major version the dump was taken from
   (use the bundle's `bin/ias-git-server-standup.sh`). Do not initialise it with real data.
4. **Restore the dump.** Recover the newest Forgejo dump from restic, then restore it per the Forgejo
   admin procedure (database + `data/`/`repositories`/config from the dump into the fresh instance).
   If the dump is unavailable, fall back to restoring repositories from the git bundles/mirror.
5. **Bring the service up** behind the same reverse-proxy/TLS pattern as the bundle's standup script.

## Acceptance checks (the forge must come back WHOLE)
Tick every box before calling the drill a pass:
- [ ] The web UI loads and an admin can sign in.
- [ ] Every expected **repository** is present, and `git clone` of a sample repo returns full history
      (compare the tip commit hash against a known-good value).
- [ ] **Issues and pull requests** are present with their comments and state (open/merged/closed).
- [ ] **Users, teams, and permissions** are intact.
- [ ] **Releases / attachments / LFS** objects resolve (download one of each).
- [ ] Server **configuration** (auth, webhooks, mirror settings) matches the original.
- [ ] Push-mirroring can be re-pointed at the public forges and a test push propagates outward.

## Record the result
Log each drill (date, disk id/label, Forgejo version, restic snapshot id, pass/fail, and any gap found)
so there is an auditable history that the crown jewels are genuinely recoverable. A failed or skipped
check is a finding to fix in the backup job, not a footnote.

## Notes
- Keep the drill **generic**: never commit real hostnames, IPs, provider accounts, LUKS passphrases, or
  restic keys. Those live only on the operator's own media and password manager.
- This is the COLD tier of the framework's 3-tier backup (hot public mirrors / warm off-box restic /
  cold walk-away disk). It realises `Prp-StateResurrectionFromSanctum`: the substrate can be reconstituted
  from the sanctum alone.
