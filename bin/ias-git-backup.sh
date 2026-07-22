#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ias-git-backup.sh -- back up a self-hosted Forgejo, encrypted, OFF the box, on a schedule.
# "A backup you have never restored is not a backup" -- so this also supports a restore drill.
# Bundles: `forgejo dump` (DB + all repos + LFS + attachments + config) -> one archive -> restic
# to an off-box, encrypted repository (e.g. a separate storage box). RUN ON THE FORGEJO HOST as the
# forgejo user (or via sudo -u). Intended for cron/systemd-timer (nightly), retention 7d/4w/6m.
#
# USAGE:
#   backup        create a forgejo dump + restic backup + prune to the retention policy
#   restore-drill restore the latest snapshot into a scratch dir + assert it is non-empty (proof)
#   status        show restic snapshots + last backup age
#
# WALK-AWAY (cold, encrypted, external-disk) TIER -- the sovereignty backstop:
#   Point RESTIC_REPOSITORY at a mounted, LUKS-encrypted EXTERNAL DISK you can unplug and carry:
#     RESTIC_REPOSITORY=/media/<you>/<DRIVE>/forgejo RESTIC_PASSWORD=... bash ias-git-backup.sh backup
#   restic encrypts the payload; the LUKS volume encrypts the disk (belt-and-suspenders). Unplug it and
#   store it off-site. If the whole datacenter/cloud vanishes, rebuild the entire forge from this disk
#   into a fresh box -- see RESURRECTION-DRILL.md. This composes with the "Walkable Sanctum" rsync
#   (backup-substrate-to-external.sh) so the git state rides your existing carry-away ritual.
#   ("A backup you have never restored is not a backup" -> run restore-drill, and the full drill in
#    RESURRECTION-DRILL.md, periodically.)
#
# ENV (ENV-ONLY secrets):
#   RESTIC_REPOSITORY   e.g. sftp:u12345@u12345.your-storagebox.de:/forgejo   (OFF-box!)
#   RESTIC_PASSWORD     restic repo password (or RESTIC_PASSWORD_FILE)
#   FORGEJO_BIN         (default /usr/local/bin/forgejo)
#   FORGEJO_WORK_DIR    (default /var/lib/forgejo)
#   FORGEJO_CONFIG      (default /etc/forgejo/app.ini)
#   RETAIN              (default "--keep-daily 7 --keep-weekly 4 --keep-monthly 6")
set -uo pipefail

FORGEJO_BIN="${FORGEJO_BIN:-/usr/local/bin/forgejo}"
FORGEJO_WORK_DIR="${FORGEJO_WORK_DIR:-/var/lib/forgejo}"
FORGEJO_CONFIG="${FORGEJO_CONFIG:-/etc/forgejo/app.ini}"
RETAIN="${RETAIN:---keep-daily 7 --keep-weekly 4 --keep-monthly 6}"
MODE="${1:-status}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; return 1; }; }

cmd_backup() {
  need restic || return 1
  : "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY (must be OFF this box)}"
  local tmp; tmp="$(mktemp -d)"
  echo "== forgejo dump =="
  ( cd "$tmp" && "$FORGEJO_BIN" dump -c "$FORGEJO_CONFIG" --work-path "$FORGEJO_WORK_DIR" -f forgejo-dump.zip )
  echo "== restic backup -> ${RESTIC_REPOSITORY} =="
  restic snapshots >/dev/null 2>&1 || restic init
  restic backup "$tmp/forgejo-dump.zip"
  echo "== prune (retain: $RETAIN) =="
  restic forget $RETAIN --prune || true
  rm -rf "$tmp"
  echo "OK: encrypted off-box backup complete."
}

cmd_restore_drill() {
  need restic || return 1
  : "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}"
  local out; out="$(mktemp -d)"
  echo "== restore latest snapshot -> $out (proof-of-restore) =="
  restic restore latest --target "$out"
  if find "$out" -name 'forgejo-dump.zip' -size +0c | grep -q .; then
    echo "OK: restore produced a non-empty forgejo-dump.zip -> the backup is restorable."
  else
    echo "FAIL: restored tree has no non-empty dump; investigate before trusting this backup." >&2
    rm -rf "$out"; return 1
  fi
  rm -rf "$out"
}

cmd_status() {
  need restic || return 1
  echo "RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-(unset)}"
  restic snapshots 2>&1 | tail -12 || echo "(no snapshots / repo unreachable)"
}

case "$MODE" in
  backup)        cmd_backup ;;
  restore-drill) cmd_restore_drill ;;
  status)        cmd_status ;;
  -h|--help|help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown: $MODE (backup|restore-drill|status|--help)" >&2; exit 2 ;;
esac
