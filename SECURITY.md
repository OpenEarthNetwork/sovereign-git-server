# Security Policy

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue:

- Use this repository's **private vulnerability reporting** (GitHub: *Security -> Report a vulnerability*), or
- Contact the maintainers via the channel listed in `README.md`.

Please include reproduction steps and the affected script/version. We aim to
acknowledge reports promptly and will coordinate a fix and disclosure timeline
with you.

## Do-no-harm by design

This toolkit is built to be safe to run on infrastructure you control:

- **No auto-execution of untrusted code.** Contribution workflows fetch and
  apply patches for human review; they never run fetched hooks, CI, or build
  steps automatically.
- **Fail-closed gates.** The confidentiality leak-gate scans *all* text files
  (not an extension allowlist) and aborts a release on any match; the
  declassify flow refuses to stage symlinks or unscanned content.
- **Verified supply chain.** Server binaries are installed only after
  GPG-signature (pinned key fingerprint) **and** sha256 verification; there is
  no unverified-binary code path.
- **Provable copies.** Every mirror/clone/restore ends with a ref-SHA
  comparison, so a faithful copy is cryptographically demonstrable.
- **No telemetry.** The tools do not phone home or collect analytics.

## Scope

This policy covers the scripts and documentation in this repository. The
third-party software it orchestrates (Forgejo, git, OpenSSH, GnuPG, etc.) has
its own security processes upstream.
