#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ias-git-server-update.sh -- safely auto-secure-update a self-hosted Forgejo server.
#
# RUN THIS ON YOUR FORGEJO HOST, as root (it swaps a system binary + controls systemd).
# It is the "keep your sovereign git server patched" step of the bundle. The whole point of
# this script is that a binary is NEVER swapped unless it is PROVABLY the authentic Forgejo
# release: sha256 match AND a valid GPG signature from the pinned Forgejo release-signing key.
# There is deliberately NO flag that bypasses that verification. Nothing irreversible happens
# without --apply: the default is a DRY-RUN that checks + verifies but does not touch the box.
#
# PIPELINE (each step gated on the previous succeeding):
#   1. CHECK    resolve latest stable (or --to <ver>); compare to installed; no-op if current
#   2. DOWNLOAD fetch linux-<arch> binary + .sha256 + .asc into a private temp dir (HTTPS only)
#   3. VERIFY   HARD GATE: sha256 must match AND .asc must GPG-verify vs the pinned key -> or abort
#   4. BACKUP   copy the current binary aside (versioned) + trigger a data backup (forgejo dump)
#   5. SWAP     stop service; atomically replace binary (temp-on-same-fs -> mv; preserve mode/owner); start
#   6. SMOKE    service active + `forgejo --version` == new + loopback HTTP health probe OK, in a timeout
#   7. ROLLBACK if smoke fails: restore old binary, restart, confirm OLD version back, exit non-zero LOUDLY
#   8. ALERT    emit a clear STATUS line + write a status file; optionally run a user-supplied --notify-cmd
#
# USAGE:
#   ias-git-server-update.sh [--to <version>] [--apply] [options]      # update pipeline (dry-run unless --apply)
#   ias-git-server-update.sh --check                                   # just report installed vs latest
#   ias-git-server-update.sh --install-timer                           # print/install systemd timer + service units
#   ias-git-server-update.sh --self-test                               # run built-in offline logic tests
#   ias-git-server-update.sh -h | --help
#
# OPTIONS:
#   --to <version>      target version (e.g. 9.0.3 or v9.0.3). Default: latest stable (resolved from dl.forgejo.org).
#   --apply             actually stop/swap/start. WITHOUT it, verification runs but the box is NOT modified.
#   --check             CHECK step only (installed vs available); exit 0 current, 10 update-available, non-0 error.
#   --notify-cmd <cmd>  a command to run with the final status line as its single argument (both success + failure).
#                       Generic on purpose -- wire it to YOUR alerting (matrix, email, webhook). No channel is baked in.
#   --status-file <f>   write the final one-line status to this file (default: /var/log/ias-git-server-update.status).
#   --health-url <url>  loopback health endpoint to probe post-restart (default: http://127.0.0.1:3000/api/healthz).
#   --health-timeout N  seconds to wait for health to go OK after restart (default: 60).
#   --keep-binaries N   how many aside-copies of prior binaries to retain (default: 5).
#   --install-timer     write forgejo-update.service + forgejo-update.timer (+ enable unattended-upgrades hint) and exit.
#   --print-units       print the systemd unit + timer text to stdout (no writes) and exit.
#   --self-test         run offline unit tests of the pure logic (version-compare, sha gate, argparse) and exit.
#
# HARD GATES (red-team note): steps 3a (sha256) and 3b (GPG) are mandatory and have NO bypass flag.
#   No code path swaps an unverified binary. TLS is never disabled. No eval. No `curl | bash`.
#
# ENV KNOBS (all optional):
#   FORGEJO_BIN            (default /usr/local/bin/forgejo)      installed binary path
#   FORGEJO_SERVICE       (default forgejo)                     systemd unit name
#   FORGEJO_CONFIG        (default /etc/forgejo/app.ini)        config (for `forgejo dump`)
#   FORGEJO_WORK_DIR      (default /var/lib/forgejo)            data dir  (for `forgejo dump`)
#   FORGEJO_USER          (default git)                         owner of the binary/service
#   FORGEJO_DL_BASE       (default https://dl.forgejo.org/forgejo)   release mirror base
#   FORGEJO_SIGNING_FPR   (default the pinned fpr below)        override ONLY with a fpr you have independently confirmed
#   FORGEJO_KEY_URL       (default the pinned URL below)        where to import the signing key from (verified vs fpr)
#   BACKUP_SCRIPT         (default <this dir>/ias-git-backup.sh)  data backup to trigger pre-swap (or "" to use forgejo dump)
# NO TOKENS are used by this script (all downloads are public). If you ever add auth, ENV-only, never argv, never printed.
set -euo pipefail

SELF="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- pinned Forgejo release-signing key (fingerprint pinning; NOT blind network trust) ----
# Forgejo signs every release binary with its dedicated release-signing OpenPGP key. We pin the
# 40-hex FINGERPRINT here and REFUSE to trust any imported key whose fingerprint differs. Importing
# a key over the network is fine ONLY because we then check it equals this pinned value; a MITM that
# serves a different key fails the fingerprint check and the update aborts.
#
#   >>> CONFIRM THIS FINGERPRINT out-of-band before first use. <<<
#   Forgejo publishes it on https://forgejo.org/download/ ("Verifying release binaries") and the key
#   itself at https://codeberg.org/forgejo/forgejo (release docs). Cross-check the 40 hex chars below
#   against that page. If Forgejo rotates the key, update FORGEJO_SIGNING_FPR (env) or this constant.
# Pinned (Forgejo "Release Signing Key"); verify before trusting:
FORGEJO_SIGNING_FPR_DEFAULT="EB114F5E6C0DC2BCDD183550A4B61A2DC5923710"
FORGEJO_KEY_URL_DEFAULT="https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/release-team-key.gpg"

FORGEJO_BIN="${FORGEJO_BIN:-/usr/local/bin/forgejo}"
FORGEJO_SERVICE="${FORGEJO_SERVICE:-forgejo}"
FORGEJO_CONFIG="${FORGEJO_CONFIG:-/etc/forgejo/app.ini}"
FORGEJO_WORK_DIR="${FORGEJO_WORK_DIR:-/var/lib/forgejo}"
FORGEJO_USER="${FORGEJO_USER:-git}"
FORGEJO_DL_BASE="${FORGEJO_DL_BASE:-https://dl.forgejo.org/forgejo}"
FORGEJO_SIGNING_FPR="${FORGEJO_SIGNING_FPR:-$FORGEJO_SIGNING_FPR_DEFAULT}"
FORGEJO_KEY_URL="${FORGEJO_KEY_URL:-$FORGEJO_KEY_URL_DEFAULT}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-$SELF_DIR/ias-git-backup.sh}"

# ---- defaults for options ----
TARGET_VERSION=""          # empty => resolve latest stable
APPLY=0
CHECK_ONLY=0
NOTIFY_CMD=""
STATUS_FILE="/var/log/ias-git-server-update.status"
HEALTH_URL="http://127.0.0.1:3000/api/healthz"
HEALTH_TIMEOUT=60
KEEP_BINARIES=5

die() { echo "${SELF}: ERROR: $*" >&2; exit 2; }
log() { printf '== %s ==\n' "$*"; }

# ---------------------------------------------------------------------------
# Pure helpers (no side effects; exercised by --self-test)
# ---------------------------------------------------------------------------

# normalise_version <v> : strip a leading 'v', trim whitespace. Echoes the bare x.y.z.
normalise_version() {
  local v="${1:-}"
  v="${v#v}"
  v="${v#V}"
  printf '%s' "$v" | tr -d '[:space:]'
}

# version_is_newer <candidate> <installed> : exit 0 iff candidate > installed (semver-ish numeric).
# Non-numeric fields sort as 0. Equal => not newer (exit 1). Used for the idempotent no-op decision.
version_is_newer() {
  local a b
  a="$(normalise_version "${1:-}")"
  b="$(normalise_version "${2:-}")"
  [ -n "$a" ] || return 1
  # split on '.' and '-'/'+' (pre-release/build separators) into numeric-ish fields
  local IFS='.-+'
  # shellcheck disable=SC2206
  local aa=($a) bb=($b)
  local i max fa fb
  max=${#aa[@]}
  [ ${#bb[@]} -gt "$max" ] && max=${#bb[@]}
  for ((i=0; i<max; i++)); do
    fa="${aa[i]:-0}"; fb="${bb[i]:-0}"
    # keep only leading digits; anything non-numeric becomes 0 (conservative)
    fa="${fa%%[!0-9]*}"; fb="${fb%%[!0-9]*}"
    fa="${fa:-0}"; fb="${fb:-0}"
    if [ "$((10#$fa))" -gt "$((10#$fb))" ]; then return 0; fi
    if [ "$((10#$fa))" -lt "$((10#$fb))" ]; then return 1; fi
  done
  return 1  # equal
}

# arch_tag : map uname -m to the Forgejo release arch tag.
arch_tag() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "unsupported arch: $(uname -m) (Forgejo publishes amd64/arm64)" ;;
  esac
}

# sha256_of <file> : echo the hex sha256 of a file (portable: sha256sum or shasum -a 256).
sha256_of() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$f" | awk '{print $1}'
  else
    die "no sha256sum / shasum available"
  fi
}

# sha256_matches <binary> <sha256-file> : exit 0 iff the binary's sha256 equals the expected hex.
# The .sha256 file may be "<hex>" or "<hex>  <filename>"; we take the first field only.
sha256_matches() {
  local bin="$1" shafile="$2" got want
  got="$(sha256_of "$bin")"
  want="$(awk '{print $1; exit}' "$shafile" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  got="$(printf '%s' "$got" | tr '[:upper:]' '[:lower:]')"
  [ -n "$want" ] || return 1
  [ "$got" = "$want" ]
}

# ---------------------------------------------------------------------------
# Network + system operations (only reached in the real pipeline)
# ---------------------------------------------------------------------------

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "must run as root (swaps ${FORGEJO_BIN} + controls systemd). Re-run with sudo."
  fi
}

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# Strict TLS download. HTTPS-only, TLS>=1.2, fail on HTTP errors, follow redirects, no --insecure ever.
dl() {
  local url="$1" out="$2"
  case "$url" in
    https://*) : ;;
    *) die "refusing non-HTTPS URL: $url" ;;
  esac
  curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
       --retry 3 --retry-delay 2 --max-time 300 --output "$out" -- "$url"
}

installed_version() {
  if [ -x "$FORGEJO_BIN" ]; then
    # `forgejo --version` prints e.g. "Forgejo version 9.0.3+gitea-1.22.0 built with ..."
    "$FORGEJO_BIN" --version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="version"){print $(i+1); exit}}' \
      | sed 's/+.*//'
  else
    printf ''
  fi
}

# resolve_latest_stable : echo the latest stable version tag from the release mirror.
# dl.forgejo.org/forgejo/ exposes per-version dirs; the mirror maintains a symlinked pointer.
# We fetch the machine-readable release-notes-assistant/version index and pick the highest STABLE
# (no -rc/-test/-nightly) tag. If the network path is unavailable, we fail LOUDLY (never guess).
resolve_latest_stable() {
  need curl
  local tmp; tmp="$(mktemp)"
  # Preferred: the mirror's release index (one version per line under the base dir listing).
  if dl "${FORGEJO_DL_BASE}/" "$tmp" 2>/dev/null; then
    # extract x.y.z dir names, drop pre-release markers, sort semver-descending, take the top.
    local latest
    latest="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$tmp" \
              | grep -vE '(rc|test|nightly|beta|alpha)' \
              | sort -t. -k1,1n -k2,2n -k3,3n \
              | tail -1)"
    rm -f "$tmp"
    [ -n "$latest" ] || die "could not resolve latest stable version from ${FORGEJO_DL_BASE}/ (empty index)"
    printf '%s' "$latest"
    return 0
  fi
  rm -f "$tmp"
  die "could not reach ${FORGEJO_DL_BASE}/ to resolve latest stable (pin with --to <version> instead)"
}

# import_and_verify_key <workdir> : import the Forgejo signing key into an isolated keyring and
# assert its fingerprint equals the pinned FORGEJO_SIGNING_FPR. Aborts on any mismatch.
# Uses a throwaway GNUPGHOME so we never touch root's real keyring.
GPG_HOME=""
import_and_verify_key() {
  local wd="$1"
  need gpg
  GPG_HOME="$wd/gnupg"
  mkdir -p "$GPG_HOME"
  chmod 700 "$GPG_HOME"
  local keyfile="$wd/forgejo-signing-key.asc"
  dl "$FORGEJO_KEY_URL" "$keyfile" || die "could not download signing key from ${FORGEJO_KEY_URL}"
  GNUPGHOME="$GPG_HOME" gpg --batch --import "$keyfile" >/dev/null 2>&1 \
    || die "failed to import Forgejo signing key"
  # collect the imported fingerprint(s) and require the pinned one to be present.
  local want; want="$(printf '%s' "$FORGEJO_SIGNING_FPR" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  local have
  have="$(GNUPGHOME="$GPG_HOME" gpg --batch --with-colons --fingerprint 2>/dev/null \
          | awk -F: '$1=="fpr"{print $10}')"
  if ! printf '%s\n' "$have" | grep -qx "$want"; then
    echo "${SELF}: imported key fingerprint(s):" >&2
    printf '  %s\n' $have >&2
    die "SIGNING KEY FINGERPRINT MISMATCH: expected ${want} not present. Refusing to trust this key."
  fi
  echo "  signing key fingerprint pinned + confirmed: ${want}"
}

# gpg_verify <binary> <asc> <workdir> : HARD GATE. exit 0 iff the detached .asc verifies vs the
# imported+pinned key. Any failure aborts the caller.
gpg_verify() {
  local bin="$1" asc="$2"
  [ -n "$GPG_HOME" ] || die "internal: key not imported before gpg_verify"
  # F5: require a VALIDSIG bound to the PINNED primary fingerprint (as standup:88 does),
  # not merely GOODSIG from any key in the keyring. VALIDSIG's trailing field is the
  # primary-key fpr; match the pinned fpr there. Defence-in-depth over the isolated ring.
  local want; want="$(printf '%s' "$FORGEJO_SIGNING_FPR" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  GNUPGHOME="$GPG_HOME" gpg --batch --status-fd 1 --verify "$asc" "$bin" 2>/dev/null \
    | grep -qE "^\[GNUPG:\] VALIDSIG .*${want}"
}

# ---------------------------------------------------------------------------
# status / notify
# ---------------------------------------------------------------------------
emit_status() {
  local line="$1"
  echo "STATUS: $line"
  # best-effort status file (do not fail the run if the dir is unwritable)
  if [ -n "$STATUS_FILE" ]; then
    if ! printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" > "$STATUS_FILE" 2>/dev/null; then
      echo "${SELF}: warn: could not write status file ${STATUS_FILE}" >&2
    fi
  fi
  # optional user-supplied notify command (status passed as a single argv element; never eval'd)
  if [ -n "$NOTIFY_CMD" ]; then
    "$NOTIFY_CMD" "$line" || echo "${SELF}: warn: --notify-cmd exited non-zero" >&2
  fi
}

# ---------------------------------------------------------------------------
# CHECK
# ---------------------------------------------------------------------------
do_check() {
  local cur want
  cur="$(installed_version)"
  if [ -n "$TARGET_VERSION" ]; then
    want="$(normalise_version "$TARGET_VERSION")"
  else
    want="$(resolve_latest_stable)"
  fi
  echo "installed: ${cur:-<none>}"
  echo "target   : ${want}"
  if [ -z "$cur" ]; then
    echo "result   : NOT INSTALLED (forgejo not found at ${FORGEJO_BIN})"
    return 10
  fi
  if version_is_newer "$want" "$cur"; then
    echo "result   : UPDATE AVAILABLE (${cur} -> ${want})"
    return 10
  fi
  echo "result   : already up to date (${cur})"
  return 0
}

# ---------------------------------------------------------------------------
# The full pipeline
# ---------------------------------------------------------------------------
WORKDIR=""
cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }

run_pipeline() {
  need curl; need gpg
  local cur want arch
  cur="$(installed_version)"
  [ -n "$cur" ] || die "forgejo not installed at ${FORGEJO_BIN} -- use ias-git-server-standup.sh first."

  # 1. CHECK
  log "1/8 CHECK"
  if [ -n "$TARGET_VERSION" ]; then
    want="$(normalise_version "$TARGET_VERSION")"
  else
    want="$(resolve_latest_stable)"
  fi
  echo "  installed=${cur}  target=${want}"
  if ! version_is_newer "$want" "$cur"; then
    emit_status "OK no-op: forgejo already at ${cur} (target ${want}); nothing to do."
    return 0
  fi
  arch="$(arch_tag)"

  # temp workspace (private, cleaned on exit)
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ias-git-server-update.XXXXXX")" || die "mktemp failed"
  chmod 700 "$WORKDIR"
  trap cleanup EXIT

  # 2. DOWNLOAD
  log "2/8 DOWNLOAD forgejo ${want} (linux-${arch}) + .sha256 + .asc"
  local base bin sha asc
  base="${FORGEJO_DL_BASE}/${want}/forgejo-${want}-linux-${arch}"
  bin="$WORKDIR/forgejo.new"
  sha="$WORKDIR/forgejo.new.sha256"
  asc="$WORKDIR/forgejo.new.asc"
  dl "$base"        "$bin" || die "download failed: ${base}"
  dl "${base}.sha256" "$sha" || die "download failed: ${base}.sha256"
  dl "${base}.asc"    "$asc" || die "download failed: ${base}.asc"

  # 3. VERIFY (HARD GATE -- no bypass)
  log "3/8 VERIFY (sha256 + GPG; HARD GATE, no bypass)"
  if sha256_matches "$bin" "$sha"; then
    echo "  sha256 OK"
  else
    die "sha256 MISMATCH -- refusing to install (binary left untouched)."
  fi
  import_and_verify_key "$WORKDIR"
  if gpg_verify "$bin" "$asc"; then
    echo "  GPG signature OK (valid signature from pinned Forgejo release key)"
  else
    die "GPG signature INVALID/absent -- refusing to install (binary left untouched)."
  fi

  if [ "$APPLY" -ne 1 ]; then
    emit_status "DRY-RUN OK: ${want} downloaded + sha256 + GPG verified. Re-run with --apply to install (currently ${cur})."
    log "DRY-RUN complete -- no changes made. Pass --apply to perform the swap."
    return 0
  fi

  require_root

  # 4. BACKUP (safety copy of binary + data dump so rollback + data-restore are possible)
  log "4/8 BACKUP (aside-copy of current binary + data backup)"
  local aside; aside="${FORGEJO_BIN}.bak.${cur}.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p -- "$FORGEJO_BIN" "$aside" || die "failed to copy current binary aside (aborting; nothing swapped)."
  echo "  current binary saved: ${aside}"
  prune_aside_copies
  # data backup: prefer the bundle's backup script; fall back to a local forgejo dump.
  if [ -n "$BACKUP_SCRIPT" ] && [ -x "$BACKUP_SCRIPT" ]; then
    echo "  triggering data backup via ${BACKUP_SCRIPT}"
    if ! "$BACKUP_SCRIPT" backup; then
      die "pre-update data backup FAILED -- refusing to swap (nothing changed). Fix backups first."
    fi
  else
    echo "  BACKUP_SCRIPT not runnable; taking a local forgejo dump as the safety copy"
    local dumpdir; dumpdir="${FORGEJO_WORK_DIR}/pre-update-dumps"
    install -d -o "$FORGEJO_USER" -g "$FORGEJO_USER" -m 0750 "$dumpdir" 2>/dev/null || mkdir -p "$dumpdir"
    local dumpf; dumpf="${dumpdir}/forgejo-dump-pre-${cur}-$(date -u +%Y%m%dT%H%M%SZ).zip"
    if ! sudo -u "$FORGEJO_USER" "$FORGEJO_BIN" dump -c "$FORGEJO_CONFIG" --work-path "$FORGEJO_WORK_DIR" -f "$dumpf"; then
      die "pre-update forgejo dump FAILED -- refusing to swap (nothing changed)."
    fi
    echo "  data dump: ${dumpf}"
  fi
  echo "  pre-update version recorded: ${cur}"

  # 5. SWAP (stop; atomic replace on same fs preserving mode/owner; start)
  log "5/8 SWAP (stop service, atomic binary replace, start service)"
  local mode owner tmpbin
  mode="$(stat -c '%a' "$FORGEJO_BIN")"
  owner="$(stat -c '%U:%G' "$FORGEJO_BIN")"
  tmpbin="$(dirname "$FORGEJO_BIN")/.forgejo.new.$$"   # same filesystem -> mv is atomic rename
  cp -- "$bin" "$tmpbin" || die "failed staging new binary next to ${FORGEJO_BIN}"
  chmod "$mode" "$tmpbin" || die "failed to set mode on staged binary"
  chown "$owner" "$tmpbin" 2>/dev/null || true
  systemctl stop "$FORGEJO_SERVICE" || die "failed to stop ${FORGEJO_SERVICE} (nothing swapped)."
  if ! mv -f -- "$tmpbin" "$FORGEJO_BIN"; then
    # swap failed before it could damage anything; bring the OLD service back up
    rm -f -- "$tmpbin" || true
    systemctl start "$FORGEJO_SERVICE" || true
    die "atomic replace failed -- restored service on OLD binary."
  fi
  systemctl start "$FORGEJO_SERVICE" || {
    log "service failed to start on NEW binary -> rolling back"
    rollback "$aside" "$cur"
    emit_status "FAILED: ${FORGEJO_SERVICE} did not start on ${want}; rolled back to ${cur}."
    exit 1
  }

  # 6. SMOKE TEST
  log "6/8 SMOKE TEST (service active + version + loopback health)"
  if smoke_test "$want"; then
    echo "  smoke test PASSED"
  else
    log "smoke test FAILED -> rolling back"
    rollback "$aside" "$cur"
    emit_status "FAILED: smoke test failed on ${want}; rolled back to ${cur}."
    exit 1
  fi

  # 8. ALERT (success)
  emit_status "OK: forgejo updated ${cur} -> ${want} (verified sha256 + GPG; smoke test passed)."
  log "UPDATE COMPLETE: ${cur} -> ${want}"
  return 0
}

prune_aside_copies() {
  # keep only the newest $KEEP_BINARIES aside copies
  local dir base; dir="$(dirname "$FORGEJO_BIN")"; base="$(basename "$FORGEJO_BIN")"
  local -a olds=()
  # newest-first
  while IFS= read -r f; do olds+=("$f"); done < <(ls -1t "${dir}/${base}.bak."* 2>/dev/null || true)
  local i
  for ((i=KEEP_BINARIES; i<${#olds[@]}; i++)); do
    rm -f -- "${olds[i]}" || true
  done
}

smoke_test() {
  local want; want="$(normalise_version "$1")"
  # a) service active
  systemctl is-active --quiet "$FORGEJO_SERVICE" || { echo "  smoke: service not active" >&2; return 1; }
  # b) binary reports the new version
  local got; got="$(installed_version)"
  if ! version_eq "$got" "$want"; then
    echo "  smoke: version mismatch (got ${got:-<none>}, want ${want})" >&2
    return 1
  fi
  # c) loopback HTTP health within timeout
  local waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if health_ok; then return 0; fi
    sleep 2
    waited=$((waited+2))
  done
  echo "  smoke: health endpoint ${HEALTH_URL} not OK within ${HEALTH_TIMEOUT}s" >&2
  return 1
}

version_eq() {
  [ "$(normalise_version "${1:-}")" = "$(normalise_version "${2:-}")" ]
}

health_ok() {
  # loopback only; treat any 2xx as healthy. Never disables TLS (loopback is plain http by default).
  local code
  code="$(curl --silent --show-error --max-time 5 --output /dev/null --write-out '%{http_code}' -- "$HEALTH_URL" 2>/dev/null || echo 000)"
  case "$code" in 2??) return 0 ;; *) return 1 ;; esac
}

# 7. ROLLBACK
rollback() {
  local aside="$1" oldver="$2"
  log "7/8 ROLLBACK to ${oldver}"
  systemctl stop "$FORGEJO_SERVICE" 2>/dev/null || true
  if [ -f "$aside" ]; then
    local tmpbin; tmpbin="$(dirname "$FORGEJO_BIN")/.forgejo.rollback.$$"
    cp -p -- "$aside" "$tmpbin" && mv -f -- "$tmpbin" "$FORGEJO_BIN" \
      || echo "${SELF}: CRITICAL: could not restore old binary from ${aside}" >&2
  else
    echo "${SELF}: CRITICAL: aside copy ${aside} missing; cannot restore binary!" >&2
  fi
  systemctl start "$FORGEJO_SERVICE" 2>/dev/null || echo "${SELF}: CRITICAL: service did not restart after rollback" >&2
  # confirm we are back on the OLD version
  local now; now="$(installed_version)"
  if version_eq "$now" "$oldver" && systemctl is-active --quiet "$FORGEJO_SERVICE"; then
    echo "  rollback OK: service active on OLD version ${oldver}"
  else
    echo "${SELF}: CRITICAL: rollback verification FAILED (now=${now:-<none>}, active=$(systemctl is-active "$FORGEJO_SERVICE" 2>/dev/null)). MANUAL INTERVENTION REQUIRED." >&2
  fi
}

# ---------------------------------------------------------------------------
# systemd timer + OS unattended-upgrades
# ---------------------------------------------------------------------------
UNIT_SERVICE_TEXT() {
cat <<EOF
[Unit]
Description=Forgejo sovereign-git auto-secure-update (verify-before-swap)
Documentation=file://$(realpath "$0" 2>/dev/null || echo "$0")
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# --apply performs the swap; verification (sha256 + GPG) is ALWAYS enforced and cannot be bypassed.
ExecStart=$(realpath "$0" 2>/dev/null || echo "$0") --apply
# capture output for the journal / your alerting; adjust --notify-cmd to wire your alerts.
Nice=10
IOSchedulingClass=idle
EOF
}

UNIT_TIMER_TEXT() {
cat <<'EOF'
[Unit]
Description=Weekly Forgejo sovereign-git auto-secure-update

[Timer]
OnCalendar=Sun *-*-* 04:30:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

print_units() {
  echo "# ---- /etc/systemd/system/forgejo-update.service ----"
  UNIT_SERVICE_TEXT
  echo ""
  echo "# ---- /etc/systemd/system/forgejo-update.timer ----"
  UNIT_TIMER_TEXT
  echo ""
  echo "# ---- OS security updates (Debian/Ubuntu) ----"
  echo "# apt-get install -y unattended-upgrades"
  echo "# dpkg-reconfigure -plow unattended-upgrades   # enable automatic security updates"
  echo "# (unattended-upgrades patches the OS; forgejo-update.timer patches Forgejo itself.)"
}

install_timer() {
  require_root
  log "install systemd timer + service for weekly Forgejo auto-secure-update"
  UNIT_SERVICE_TEXT > /etc/systemd/system/forgejo-update.service
  UNIT_TIMER_TEXT   > /etc/systemd/system/forgejo-update.timer
  systemctl daemon-reload
  systemctl enable --now forgejo-update.timer
  echo "  enabled forgejo-update.timer (weekly). Inspect: systemctl list-timers forgejo-update.timer"
  echo ""
  log "OS security updates (Debian/Ubuntu unattended-upgrades)"
  if command -v apt-get >/dev/null 2>&1; then
    echo "  Run these to enable automatic OS security updates (adopter step; not auto-run here):"
    echo "    apt-get install -y unattended-upgrades"
    echo "    dpkg-reconfigure -plow unattended-upgrades"
  else
    echo "  Non-Debian OS: enable your distro's automatic security updates (e.g. dnf-automatic)."
  fi
}

# ---------------------------------------------------------------------------
# --self-test (offline unit tests of the pure logic)
# ---------------------------------------------------------------------------
self_test() {
  local PASS=0 FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

  echo "== version_is_newer =="
  version_is_newer 9.0.3 9.0.2 && ok "9.0.3 > 9.0.2" || bad "9.0.3 should be > 9.0.2"
  version_is_newer 9.0.3 9.0.3 && bad "9.0.3 should NOT be > 9.0.3" || ok "9.0.3 == 9.0.3 (not newer)"
  version_is_newer 9.0.2 9.0.3 && bad "9.0.2 should NOT be > 9.0.3" || ok "9.0.2 < 9.0.3 (not newer)"
  version_is_newer 10.0.0 9.9.9 && ok "10.0.0 > 9.9.9 (numeric, not lexical)" || bad "10.0.0 should be > 9.9.9"
  version_is_newer v9.1.0 9.0.9 && ok "v9.1.0 > 9.0.9 (leading v stripped)" || bad "v9.1.0 should be > 9.0.9"

  echo "== normalise_version =="
  [ "$(normalise_version v9.0.3)" = "9.0.3" ] && ok "strips leading v" || bad "should strip leading v"
  [ "$(normalise_version ' 9.0.3 ')" = "9.0.3" ] && ok "trims whitespace" || bad "should trim whitespace"

  echo "== version_eq =="
  version_eq 9.0.3 v9.0.3 && ok "9.0.3 == v9.0.3" || bad "9.0.3 should == v9.0.3"
  version_eq 9.0.3 9.0.2 && bad "9.0.3 should != 9.0.2" || ok "9.0.3 != 9.0.2"

  echo "== sha256 gate (PASS + tamper FAIL) =="
  local td; td="$(mktemp -d)"
  printf 'authentic forgejo binary bytes\n' > "$td/bin"
  sha256_of "$td/bin" > "$td/bin.sha256"
  if sha256_matches "$td/bin" "$td/bin.sha256"; then ok "matching sha256 passes"; else bad "matching sha256 should pass"; fi
  # sha256 file with two-field format ("<hex>  filename")
  printf '%s  forgejo-x-linux-amd64\n' "$(sha256_of "$td/bin")" > "$td/bin.sha256b"
  if sha256_matches "$td/bin" "$td/bin.sha256b"; then ok "two-field sha256 format passes"; else bad "two-field sha256 should pass"; fi
  # tamper the binary
  printf 'tampered\n' >> "$td/bin"
  if sha256_matches "$td/bin" "$td/bin.sha256"; then bad "tampered binary should FAIL sha256"; else ok "tampered binary fails sha256 (abort)"; fi
  # empty/garbage sha file
  printf '\n' > "$td/bin.empty"
  if sha256_matches "$td/bin" "$td/bin.empty"; then bad "empty sha file should FAIL"; else ok "empty sha file fails (abort)"; fi
  rm -rf "$td"

  echo "== arch_tag =="
  case "$(arch_tag)" in amd64|arm64) ok "arch_tag returned $(arch_tag)" ;; *) bad "arch_tag unexpected" ;; esac

  echo ""
  echo "RESULT (self-test): ${PASS} passed, ${FAIL} failed"
  [ "$FAIL" -eq 0 ]
}

# ---------------------------------------------------------------------------
# arg parse
# ---------------------------------------------------------------------------
MODE="pipeline"
while [ $# -gt 0 ]; do
  case "$1" in
    --to)             [ $# -ge 2 ] || die "--to needs a version"; TARGET_VERSION="$2"; shift 2 ;;
    --to=*)           TARGET_VERSION="${1#*=}"; shift ;;
    --apply)          APPLY=1; shift ;;
    --check)          CHECK_ONLY=1; MODE="check"; shift ;;
    --notify-cmd)     [ $# -ge 2 ] || die "--notify-cmd needs a command"; NOTIFY_CMD="$2"; shift 2 ;;
    --notify-cmd=*)   NOTIFY_CMD="${1#*=}"; shift ;;
    --status-file)    [ $# -ge 2 ] || die "--status-file needs a path"; STATUS_FILE="$2"; shift 2 ;;
    --status-file=*)  STATUS_FILE="${1#*=}"; shift ;;
    --health-url)     [ $# -ge 2 ] || die "--health-url needs a url"; HEALTH_URL="$2"; shift 2 ;;
    --health-url=*)   HEALTH_URL="${1#*=}"; shift ;;
    --health-timeout) [ $# -ge 2 ] || die "--health-timeout needs seconds"; HEALTH_TIMEOUT="$2"; shift 2 ;;
    --health-timeout=*) HEALTH_TIMEOUT="${1#*=}"; shift ;;
    --keep-binaries)  [ $# -ge 2 ] || die "--keep-binaries needs a count"; KEEP_BINARIES="$2"; shift 2 ;;
    --keep-binaries=*) KEEP_BINARIES="${1#*=}"; shift ;;
    --install-timer)  MODE="install-timer"; shift ;;
    --print-units)    MODE="print-units"; shift ;;
    --self-test)      MODE="self-test"; shift ;;
    -h|--help)        sed -n '7,72p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --)               shift; break ;;
    -*)               die "unknown option: $1 (see --help)" ;;
    *)                die "unexpected argument: $1 (see --help)" ;;
  esac
done

case "$MODE" in
  check)         do_check ;;
  self-test)     self_test ;;
  print-units)   print_units ;;
  install-timer) install_timer ;;
  pipeline)      run_pipeline ;;
  *)             die "internal: unknown mode ${MODE}" ;;
esac
