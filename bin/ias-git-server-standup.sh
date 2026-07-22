#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# ias-git-server-standup.sh -- stand up a sovereign, deliberately-simple, ISOLATED Forgejo git server.
# RUN THIS ON YOUR FRESH GIT HOST (e.g. a small cloud VM or an owned box), NOT on your workstation.
# It is the "create your own sovereign git server" step of the bundle. Idempotent; sudo per step;
# verifies as it goes. Nothing here reaches out to GitHub/GitLab/Codeberg -- mirroring is a SEPARATE
# step (ias-git-mirror-setup.sh) so this box stays boring + isolated (blast-radius containment).
#
# SUBCOMMANDS:
#   status                      show what's installed/running (read-only)
#   install                     install Forgejo (systemd + SQLite) as a dedicated 'git' user
#   caddy                       install Caddy + auto-TLS reverse proxy for $GIT_DOMAIN -> 127.0.0.1:3000
#   harden                      write app.ini hardening (registration closed, no telemetry, loopback-bound)
#   firewall                    ufw: allow 443 + SSH only
#   all                         install + caddy + harden + firewall
#
# ENV KNOBS:
#   GIT_DOMAIN        (default git.example.org)  canonical hostname (DNS A-record must already point here).
#                                                ADOPTER MUST set this to their own domain before standup.
#   FORGEJO_VERSION   (default 9.0.3)            pin a stable release; update = stop, swap binary, start
#   FORGEJO_USER      (default git)
#   FORGEJO_HOME      (default /var/lib/forgejo)
#
# NOTE: DNS (A-record GIT_DOMAIN -> this host's IP) + off-box encrypted backup target are operator
# prerequisites (see the standup-plan §3/§8). Backups: ias-git-backup.sh. Updates: back up FIRST.
set -uo pipefail

GIT_DOMAIN="${GIT_DOMAIN:-git.example.org}"
FORGEJO_VERSION="${FORGEJO_VERSION:-9.0.3}"
FORGEJO_USER="${FORGEJO_USER:-git}"
FORGEJO_HOME="${FORGEJO_HOME:-/var/lib/forgejo}"
BIN=/usr/local/bin/forgejo
ARCH="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"

log() { printf '== %s ==\n' "$*"; }

cmd_status() {
  log "forgejo binary"; [ -x "$BIN" ] && "$BIN" --version 2>/dev/null || echo "(not installed)"
  log "service"; systemctl is-active forgejo 2>/dev/null || echo "(forgejo.service not active)"
  log "caddy"; systemctl is-active caddy 2>/dev/null || echo "(caddy not active)"
  log "listen (loopback 3000 expected)"; ss -ltnp 2>/dev/null | grep -E ':3000|:443' || echo "(nothing on 3000/443)"
  log "domain"; echo "GIT_DOMAIN=$GIT_DOMAIN  (DNS must A-record to this host)"
}

cmd_install() {
  log "dedicated '$FORGEJO_USER' user + data dir"
  id "$FORGEJO_USER" >/dev/null 2>&1 || sudo useradd --system --shell /bin/bash --create-home --home-dir /home/"$FORGEJO_USER" "$FORGEJO_USER"
  sudo mkdir -p "$FORGEJO_HOME"/{custom,data,log} /etc/forgejo
  sudo chown -R "$FORGEJO_USER":"$FORGEJO_USER" "$FORGEJO_HOME"
  sudo chown root:"$FORGEJO_USER" /etc/forgejo
  sudo chmod 770 /etc/forgejo

  if [ -x "$BIN" ] && "$BIN" --version 2>/dev/null | grep -q "$FORGEJO_VERSION"; then
    echo "forgejo $FORGEJO_VERSION already installed."
  else
    log "download + VERIFY Forgejo $FORGEJO_VERSION ($ARCH) release binary (fail-closed)"
    local base="https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_VERSION}"
    local binfile="forgejo-${FORGEJO_VERSION}-linux-${ARCH}"
    local dl; dl="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$dl/bin"        "${base}/${binfile}"
    curl -fsSL --retry 3 -o "$dl/bin.sha256" "${base}/${binfile}.sha256"
    curl -fsSL --retry 3 -o "$dl/bin.asc"    "${base}/${binfile}.asc"

    # (1) sha256 MUST match the published checksum (aborts on any mismatch -- no skip).
    local want got
    want="$(awk '{print tolower($1)}' "$dl/bin.sha256")"
    got="$(sha256sum "$dl/bin" | awk '{print $1}')"
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
      rm -rf "$dl"; echo "FATAL: Forgejo binary sha256 mismatch (want=$want got=$got) -- refusing to install (possible tampering)." >&2; exit 1
    fi

    # (2) GPG signature MUST verify against the PINNED Forgejo release-signing key fingerprint.
    #     FAIL-CLOSED: never trust an unverified server binary, never a network key blindly.
    #     Default below CONFIRMED against https://forgejo.org/download 2026-07-21 (the page's
    #     `gpg --keyserver keys.openpgp.org --recv <fpr>` value). SAME value as
    #     ias-git-server-update.sh FORGEJO_SIGNING_FPR_DEFAULT (single source of truth); override
    #     FORGEJO_GPG_FINGERPRINT only for a rotated key you have independently confirmed.
    local fpr="${FORGEJO_GPG_FINGERPRINT:-EB114F5E6C0DC2BCDD183550A4B61A2DC5923710}"
    fpr="${fpr// /}"; fpr="${fpr^^}"
    local gnupg; gnupg="$(mktemp -d)"
    if ! GNUPGHOME="$gnupg" gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "$fpr" >/dev/null 2>&1; then
      rm -rf "$dl" "$gnupg"; echo "FATAL: could not fetch Forgejo signing key $fpr -- aborting." >&2; exit 1
    fi
    if ! GNUPGHOME="$gnupg" gpg --batch --status-fd 1 --verify "$dl/bin.asc" "$dl/bin" 2>/dev/null | grep -Eqi "^\[GNUPG:\] VALIDSIG .*${fpr}"; then
      rm -rf "$dl" "$gnupg"; echo "FATAL: Forgejo binary GPG signature did NOT verify against pinned key $fpr -- refusing to install." >&2; exit 1
    fi
    rm -rf "$gnupg"

    sudo install -m 0755 "$dl/bin" "$BIN"
    rm -rf "$dl"
    log "verified (sha256 + GPG pinned $fpr) + installed Forgejo $FORGEJO_VERSION"
  fi

  log "systemd unit"
  sudo tee /etc/systemd/system/forgejo.service >/dev/null <<EOF
[Unit]
Description=Forgejo (sovereign git)
After=network.target
[Service]
User=${FORGEJO_USER}
Group=${FORGEJO_USER}
WorkingDirectory=${FORGEJO_HOME}
ExecStart=${BIN} web --config /etc/forgejo/app.ini
Restart=always
Environment=USER=${FORGEJO_USER} HOME=/home/${FORGEJO_USER} GITEA_WORK_DIR=${FORGEJO_HOME}
# isolation hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${FORGEJO_HOME} /etc/forgejo
[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now forgejo
  echo "Forgejo installed. Complete first-run admin setup via the web UI, then run 'harden'."
}

cmd_harden() {
  log "app.ini hardening (registration closed; no telemetry; loopback-bound; SQLite)"
  sudo tee /etc/forgejo/app.ini >/dev/null <<EOF
# WORK_PATH MUST be set (DEFAULT section, absolute) so EVERY invocation resolves the same paths: the
# web service (systemd env), the git-over-SSH 'serv' command (authorized_keys; NO env), and hooks.
# Without it, git-over-SSH falls back to <binary-dir>/data and dies with
# "mkdir /usr/local/bin/data: permission denied" (web works, SSH push/clone fatal). Hard-won 2026-07-20.
WORK_PATH = ${FORGEJO_HOME}
APP_NAME = Sovereign Git
RUN_USER = ${FORGEJO_USER}
RUN_MODE = prod
[server]
DOMAIN           = ${GIT_DOMAIN}
ROOT_URL         = https://${GIT_DOMAIN}/
HTTP_ADDR        = 127.0.0.1
HTTP_PORT        = 3000
DISABLE_SSH      = false
APP_DATA_PATH    = ${FORGEJO_HOME}/data
LANDING_PAGE     = login
[database]
DB_TYPE = sqlite3
PATH    = ${FORGEJO_HOME}/data/forgejo.db
[service]
DISABLE_REGISTRATION            = true
# REQUIRE_SIGNIN_VIEW=false serves PUBLIC repos + the explore listing anonymously (the point of a public
# mirror org). If this instance hosts PRIVATE repos too, they stay walled (DEFAULT_PRIVATE); flip this to
# true only if you want the whole instance sign-in-gated. Conscious adopter choice.
REQUIRE_SIGNIN_VIEW             = false
DEFAULT_KEEP_EMAIL_PRIVATE      = true
[repository]
DEFAULT_PRIVATE = private
[security]
# Do NOT run server-side git hooks (they execute as the git user -> code-exec on import of a hostile repo).
DISABLE_GIT_HOOKS  = true
# Never let a migration/import read local filesystem paths (path-traversal / local-file exfiltration).
IMPORT_LOCAL_PATHS = false
[webhook]
# Webhooks may only reach external hosts -> a repo owner cannot point one at your internal network (SSRF).
ALLOWED_HOST_LIST = external
[cron.update_checker]
# No phone-home update beacon (the "no telemetry" posture; [metrics] alone does not cover this).
ENABLED = false
[migrations]
ALLOW_LOCALNETWORKS = false
[other]
SHOW_FOOTER_VERSION = false
[metrics]
ENABLED = false
EOF
  sudo chown root:"$FORGEJO_USER" /etc/forgejo/app.ini
  sudo chmod 640 /etc/forgejo/app.ini
  sudo systemctl restart forgejo
  # Rewrite the git user's authorized_keys forced-commands against THIS config so git-over-SSH resolves
  # WORK_PATH correctly (idempotent; safe if no keys yet).
  sudo -u "$FORGEJO_USER" "$BIN" --config /etc/forgejo/app.ini admin regenerate keys 2>/dev/null || true
  echo "Hardened. NOTE: REQUIRE_SIGNIN_VIEW=false so PUBLIC repos serve anonymously; DEFAULT_PRIVATE=private keeps new repos private by default."
  echo "Git-over-SSH uses port 22 by default: clone with ssh://git@${GIT_DOMAIN}/<org>/<repo>.git"
}

cmd_caddy() {
  log "Caddy + auto-TLS for ${GIT_DOMAIN} -> 127.0.0.1:3000 (own Caddy on THIS box; do not proxy via another)"
  command -v caddy >/dev/null 2>&1 || { echo "Install Caddy first (https://caddyserver.com/docs/install), then re-run."; return 1; }
  sudo tee /etc/caddy/Caddyfile >/dev/null <<EOF
${GIT_DOMAIN} {
    reverse_proxy 127.0.0.1:3000
}
EOF
  sudo systemctl reload caddy || sudo systemctl restart caddy
  echo "Caddy serving ${GIT_DOMAIN} with auto Let's Encrypt TLS."
}

cmd_firewall() {
  log "ufw: allow 443 + SSH only"
  command -v ufw >/dev/null 2>&1 || { echo "ufw not installed; configure your firewall to allow only 443 + SSH."; return 0; }
  sudo ufw allow OpenSSH || true
  sudo ufw allow 443/tcp || true
  sudo ufw --force enable || true
  sudo ufw status verbose || true
}

case "${1:-status}" in
  status)   cmd_status ;;
  install)  cmd_install ;;
  caddy)    cmd_caddy ;;
  harden)   cmd_harden ;;
  firewall) cmd_firewall ;;
  all)      cmd_install; cmd_harden; cmd_caddy; cmd_firewall ;;
  -h|--help|help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown: ${1:-} (status|install|caddy|harden|firewall|all|--help)" >&2; exit 2 ;;
esac
