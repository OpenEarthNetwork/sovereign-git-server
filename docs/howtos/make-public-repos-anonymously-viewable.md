
# How-to: make your PUBLIC repos anonymously viewable

**Goal:** a logged-out visitor can browse your **public** repos + the `/explore` listing on your
sovereign Forgejo, while **private** repos stay fully walled. This is what makes your public
canonical repo a real, shareable reader link (e.g. from a blog post or README).

**Symptom if it is wrong:** a logged-out `https://git.example.org/explore/repos` (or any public
repo page) returns **HTTP 303 -> /user/login** instead of 200. That means the instance has
`REQUIRE_SIGNIN_VIEW = true` (Forgejo's default in some setups) — every view needs an account.

`bin/ias-git-server-standup.sh` sets the correct values on a fresh install, but an instance stood up
earlier (or with defaults) may need this one-time fix.

## The setting

In `app.ini`, section `[service]`:

- `REQUIRE_SIGNIN_VIEW = false` -> public repos + `/explore` are anonymous-viewable; **private
  repos remain fully private** (auth still required for them).
- `DEFAULT_PRIVATE = private` -> new repos are private by default, so you opt IN to public
  per-repo (you never accidentally expose a repo).

## Steps (run on the server; `app.ini` is root-owned)

1. Back up the config:
   ```
   sudo cp /etc/forgejo/app.ini /etc/forgejo/app.ini.bak
   ```
2. Inspect the current `[service]` block:
   ```
   sudo grep -n -A25 '^\[service\]' /etc/forgejo/app.ini
   ```
3. Set the key. If a `REQUIRE_SIGNIN_VIEW` line already exists, flip it:
   ```
   sudo sed -i 's/^REQUIRE_SIGNIN_VIEW.*/REQUIRE_SIGNIN_VIEW = false/' /etc/forgejo/app.ini
   ```
   If it is absent, add it under `[service]`:
   ```
   sudo sed -i '/^\[service\]/a REQUIRE_SIGNIN_VIEW = false' /etc/forgejo/app.ini
   ```
4. Confirm exactly one line results:
   ```
   sudo grep -n 'REQUIRE_SIGNIN_VIEW' /etc/forgejo/app.ini
   ```
5. Restart + check it is running:
   ```
   sudo systemctl restart forgejo
   systemctl status forgejo --no-pager | head -5
   ```
6. Verify anonymously (from any machine, logged out):
   ```
   curl -sS -o /dev/null -w '%{http_code}\n' https://git.example.org/explore/repos
   ```
   Expect **200**. Also confirm a **private** repo still returns 404/login anonymously (privacy
   intact).

## Security notes

- `false` exposes ONLY repos explicitly marked public — private repos are unaffected. Verify both:
  a public repo = 200 anon, a private repo = not visible anon.
- **`app.ini` is a secret file.** It contains `[oauth2] JWT_SECRET`, `[security] INTERNAL_TOKEN`,
  and `SECRET_KEY`. Never paste it into chat/logs, never commit it. If any of those values is
  exposed, rotate it (e.g. `sudo -u git forgejo generate secret JWT_SECRET`, update `app.ini`,
  restart) — a leaked JWT/secret can be used to forge tokens.
- Keep `DEFAULT_PRIVATE = private` so publishing a repo is always a deliberate per-repo choice.
