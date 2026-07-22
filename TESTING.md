
# Testing and dogfooding

Every tool in this bundle ships with an automated test, and the end-to-end
workflows are exercised against real repositories (dogfooded) before release.
This file records what is covered and how to run it, and is honest about the
two live-network checks that a maintainer runs on real infrastructure.

## Run the tests

The bundle ships its full test suite under `tests/` (each test is self-contained: no
network, throwaway fixtures, cleans up after itself). From the repository root:

```
bash tests/test_sha_verify.sh                # verify + verified-clone (ref-SHA integrity)
bash tests/test_declassify.sh                # declassify: allowlist, history-safety, leak-gate
bash tests/test_sovgit_f1_f7_hardening.sh    # security-hardening regression
bash tests/test_sovereign_git_security.sh    # cross-bundle security regression
bash tests/test_server_update.sh             # self-updater: sha256 + pinned-GPG hard gate
bash tests/test_leakscan.sh                  # generic adopter-driven leak scanner
bash tests/test-ias-git-protect-mirrors.sh   # mirror push-whitelist protection
python3 tests/test_relay_notify.py           # contribute-back relay logic
```

All pass green as of this release.

**Note on the leak-gate.** `bin/ias-git-declassify.sh` auto-detects its leak-gate: in this
public bundle it uses the config-driven `bin/ias-git-leakscan.sh`, which carries NO built-in
confidential terms — you supply your own in a `.leakscan-deny.txt` (templates in
`examples/`) or via `--leak-deny-file`. An empty/absent denylist makes the gate inert and
prints a loud warning, so you never silently rely on an unconfigured gate.

## Coverage matrix

| Tool | Automated test | End-to-end dogfood |
|------|----------------|--------------------|
| `bin/ias-git-verify.sh` | `test_sha_verify.sh` (multi-branch, clone-mode, bare-dst, annotated tags) | proven on real multi-branch clones |
| `bin/ias-git-clone-verified.sh` | `test_sha_verify.sh` | proven on a real course repository |
| `bin/ias-git-declassify.sh` | `test_declassify.sh` + `test_sovgit_f1_f7_hardening.sh` | proven on a real private->public snapshot |
| `bin/ias-git-mirror-setup.sh` | `test_sovereign_git_security.sh` (JSON-injection, token handling) + hardening suite (https guard) | proven creating push-mirrors |
| `bin/ias-git-mirror-sync.sh` | hardening suite (https guard, token-in-header) | proven forcing a mirror sync (round-trip SHA-verified) |
| `bin/ias-git-server-update.sh` | `test_server_update.sh` (sha256 + pinned-GPG hard gate, rollback, dry-run) | live release-signature check: maintainer-run (see gap 1) |
| `bin/ias-git-backup.sh` | hardening suite (restore-drill proof) | restore-drill dogfooded |
| `bin/ias-git-pull-contribution.sh` | `test_sovereign_git_security.sh` (author-trailer validation) | walkthrough W2 |
| `relay/` (contribute-back) | `test_relay_notify.py` (push-before-PR, push-failure-aborts) | live-forge end-to-end: maintainer-run (see gap 2) |
| `bin/ias-git-server-standup.sh` | `test_sovereign_git_security.sh` (app.ini hardening, pinned-GPG install) | walkthrough W1 |
| `bin/ias-git-scrub-provenance.sh` | unit-tested in the development repo (its fixtures are internal provenance markers) | runs inside declassify |
| `bin/ias-git-leakscan.sh` (generic gate) | `test_leakscan.sh` (config-driven, adopter terms) | the public declassify leak-gate |

Walkthroughs: `docs/W1-own-and-mirror-walkthrough.md`, `docs/W2-contribute-back-walkthrough.md`,
`docs/W3-follow-copy-walkthrough.md` (each a real worked example). The W4
(controlled-disclosure) walkthrough accompanies the declassify tool.

## Honest gaps (live-network checks a maintainer runs on real infrastructure)

1. **Self-updater live signature check.** `test_server_update.sh` fully covers the
   sha256 + pinned-GPG hard gate with fixtures (including tampered-binary and
   wrong-key cases). Verifying a *real* upstream release signature against the
   pinned key is a one-command live check a maintainer runs on the server before
   trusting the auto-update path; it is not part of the offline test run.
2. **Contribute-back relay, live forge.** The relay's logic is unit-tested
   (`test_relay_notify.py`): it pushes before opening a pull request and aborts if
   the push fails. Exercising the full path against a live forge API (open a real
   pull request, observe it) is a maintainer step, not covered by the offline tests.

Neither gap is a correctness unknown in the offline logic; both are live-infra
confirmations that depend on real credentials and a running server.
