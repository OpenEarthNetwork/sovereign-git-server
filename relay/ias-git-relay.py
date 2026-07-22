#!/usr/bin/env python3
# Fix A + Fix B (2026-07-21, the maintainer via subagent): push contrib branch to canonical before create_pull_request (L1 is fetch-only) + fix misleading warning; add `notify` subcommand (comment-absorbed + close_pull on the mirror PR)
# SPDX-License-Identifier: Apache-2.0
"""ias-git-relay.py -- L2 forge-agnostic contribution relay ORCHESTRATOR.

For a canonical repo, for each configured mirror forge: list open PRs (via the injectable
forge_adapters), and for each not-yet-relayed PR, delegate the git fetch-and-apply to the L1
tool (ias-git-pull-contribution.sh -- which preserves the contributor's author + Signed-off-by,
with a patch fallback when the head ref is unfetchable), then open a canonical Forgejo PR and
record state so re-runs are IDEMPOTENT (a changed head_sha = a force-push, re-relayed; an
unchanged one = skipped -> no duplicate canonical PRs).

DESIGN (framework doc):
  * Mirrors are read-only reflections; canonical (git.example.org) is the single merge point.
  * This is the automated form of the maintainer PR-fetch (L1). Per the contributor's 3-way take, prefer
    running it ON-DEMAND (L1.5) over a always-on poller until PR volume justifies a daemon.
  * Provenance is NOT re-authored here -- the git work is delegated to L1.

SAFETY: default is DRY-RUN (lists what it WOULD relay). --actually-relay performs git + API writes
and is gated for real forges (operator-attested). HTTP is injectable (forge_adapters http_get) so
this dry-runs fully OFFLINE with no credentials.

USAGE:
  python3 ias-git-relay.py plan   <repo> --forge github --forge codeberg [--base-url ...]  # dry-run
  python3 ias-git-relay.py relay  <repo> --forge github --actually-relay                   # enact (op-gated)
  python3 ias-git-relay.py notify <mirror-repo> --forge github --pr 7 --merged-sha <sha> \
      --canonical-url https://git.example.org/o/r --token-env GITHUB_TOKEN                 # close-as-absorbed
Tokens are ENV-ONLY (passed through to forge_adapters via --token-env).

NOTIFY (Fix B, leg d): a MAINTAINER runs this AFTER merging the canonical PR. It comments on the
ORIGINAL mirror PR ("absorbed as <sha>, mirrored back") and closes it (absorbed, not rejected). It is
a SEPARATE subcommand because the relay does not observe the canonical merge itself.

FIX A (2026-07-21): the relay now PUSHES contrib/<forge>/pr-N to the canonical server (ephemeral
token-in-URL, never persisted/logged) BEFORE opening the canonical PR -- L1 is fetch-only.
"""
from __future__ import annotations
import argparse, json, os, subprocess, sys, pathlib

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))
try:
    import forge_adapters as fa  # sibling module (contributor)
except Exception as e:  # pragma: no cover - import-time guard
    fa = None
    _IMPORT_ERR = e

STATE_DEFAULT = os.path.join(os.path.expanduser("~"), ".ias", "sovereign-git", "relay-state.json")
L1 = str(_HERE.parent / "bin" / "ias-git-pull-contribution.sh")


def _load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def _save_state(path, state):
    # L4: private dir + 0600 file -- relay state holds PR titles/authors/urls (no secrets, but not for a
    # shared bot host's other users).
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    os.replace(tmp, path)


def _key(pr):
    return f"{pr.forge}#{pr.number}"


def _canonical_push_url(canonical_base_url, canonical_repo, token, user="relay-bot"):
    """Build an ephemeral HTTPS push URL for the CANONICAL server.

    Derives the git host root from the API base URL (strips a trailing /api/v1 or /api/vN) and
    appends <repo>.git. The token is embedded ONLY in the in-process URL string we hand to a single
    `git push` -- it is NEVER written into .git/config (no persisted remote), never logged, never in
    argv beyond this one subprocess. Callers must scrub the URL out of any error text before display.
    """
    from urllib.parse import urlsplit, urlunsplit
    base = (canonical_base_url or "").rstrip("/")
    # Strip the API suffix (/api/v1, /api/v4, ...) to get the git host root.
    for suffix in ("/api/v1", "/api/v4", "/api/v3"):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    else:
        # generic /api/<anything> tail
        import re
        base = re.sub(r"/api/[^/]+$", "", base)
    parts = urlsplit(base)
    # Inject user:token into the authority. token is URL-safe (forge tokens are alnum) but we do not
    # rely on that -- git accepts it verbatim; we just never persist or echo it.
    netloc = f"{user}:{token}@{parts.netloc}" if token else parts.netloc
    repo = (canonical_repo or "").strip("/")
    path = f"/{repo}.git"
    return urlunsplit((parts.scheme or "https", netloc, path, "", ""))


def _scrub_creds(text):
    """Redact any https://user:token@host credential from text before it reaches the console."""
    import re
    return re.sub(r"(://)[^@/\s]*@", r"\1***@", text or "")


def _push_contrib_to_canonical(push_url, branch):
    """Push a single contrib branch to the canonical server. Returns (rc, scrubbed_stderr).

    Uses `git -c credential.helper=` to disable any interactive/stored credential helper so the only
    credential in play is the one in the ephemeral URL (which we do not persist)."""
    cmd = ["git", "-c", "credential.helper=", "push", push_url, f"{branch}:{branch}"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, _scrub_creds((proc.stderr or "") + (proc.stdout or ""))


def _canonical_push_url(canonical_base_url, canonical_repo, user, token):
    """Build an EPHEMERAL https push URL for the canonical Forgejo git server.

    Fix A: L1 is fetch-only (never pushes), so the relayed contrib/<forge>/pr-N branch lives only in
    the local canonical clone. It MUST be pushed to the canonical server before create_pull_request,
    else the API rejects the PR ("head branch not found").

    Derivation: strip a trailing /api/v1 (or /api/v4) from --canonical-base-url to get the web/git
    root, then append <repo>.git. The token is embedded in the URL IN-PROCESS ONLY: this string is
    never printed, never logged, and never written to .git/config (the push uses it inline / via a
    temp remote that is removed immediately after -- see _push_contrib_to_canonical).
    """
    base = (canonical_base_url or "").rstrip("/")
    for suffix in ("/api/v1", "/api/v4"):
        if base.endswith(suffix):
            base = base[: -len(suffix)]
            break
    base = base.rstrip("/")
    # base is like https://git.example.org ; split scheme so we can inject <user>:<token>@host.
    if "://" in base:
        scheme, host_and_path = base.split("://", 1)
    else:
        scheme, host_and_path = "https", base
    cred = f"{user}:{token}@" if token else ""
    return f"{scheme}://{cred}{host_and_path}/{canonical_repo}.git"


def _push_contrib_to_canonical(push_url, branch):
    """Push a single contrib branch to the canonical server over an ephemeral, credential-in-URL push.

    Token discipline: the URL (which contains the token) is passed straight to `git push` argv and is
    NEVER echoed by us. We DO redact any URL git itself might print to stderr (it can, on error), and
    we NEVER persist the URL as a named remote in .git/config. Returns (rc, redacted_stderr)."""
    import re
    proc = subprocess.run(["git", "push", push_url, f"{branch}:{branch}"],
                          capture_output=True, text=True)
    # Redact https://user:TOKEN@host from any git output before it can surface in a log.
    redact = re.compile(r"(://)[^@/\s]*@")
    err = redact.sub(r"\1***@", (proc.stderr or "") + (proc.stdout or ""))
    return proc.returncode, err.strip()


def plan(args):
    if fa is None:
        print(f"[relay] cannot import forge_adapters: {_IMPORT_ERR}", file=sys.stderr)
        return 3
    state = _load_state(args.state_file)
    todo, skip = [], []
    for forge in args.forge:
        token = os.environ.get(args.token_env) if args.token_env else None
        adapter = fa.make_adapter(forge, base_url=args.base_url, token=token)
        try:
            prs = adapter.list_open_prs(args.repo)
        except Exception as e:
            print(f"[relay] {forge}: list_open_prs failed: {e}", file=sys.stderr)
            continue
        for pr in prs:
            prev = state.get(_key(pr))
            if prev and prev.get("head_sha") == pr.head_sha:
                skip.append(pr)
            else:
                todo.append(pr)
    print(f"== relay PLAN for {args.repo} (forges: {', '.join(args.forge)}) ==")
    print(f"  already-relayed (skip): {len(skip)}")
    for pr in todo:
        mode = "patch-fallback" if not getattr(pr, "head_fetchable", True) else "fetch-ref"
        print(f"  WOULD RELAY {_key(pr)} -> {pr.contrib_branch()}  [{mode}]  by {pr.author_login} :: {pr.title}")
    if not todo:
        print("  (nothing new to relay)")
    return 0


def relay(args):
    if fa is None:
        print(f"[relay] cannot import forge_adapters: {_IMPORT_ERR}", file=sys.stderr)
        return 3
    if not args.actually_relay:
        print("[relay] refusing to enact without --actually-relay (default is dry-run). Showing plan:")
        return plan(args)
    if not os.path.exists(L1):
        print(f"[relay] L1 tool not found: {L1}", file=sys.stderr)
        return 3
    state = _load_state(args.state_file)
    ctoken = os.environ.get(args.canonical_token_env) if args.canonical_token_env else None
    canonical = fa.make_adapter("forgejo", base_url=args.canonical_base_url, token=ctoken)
    relayed = 0
    for forge in args.forge:
        token = os.environ.get(args.token_env) if args.token_env else None
        adapter = fa.make_adapter(forge, base_url=args.base_url, token=token)
        for pr in adapter.list_open_prs(args.repo):
            prev = state.get(_key(pr))
            if prev and prev.get("head_sha") == pr.head_sha:
                continue
            # Delegate the git fetch-and-apply (provenance-preserving) to L1. NOTE (H4 fix 2026-07-21):
            # L1's flag is --mirror-remote, not --canonical-remote, and the PR is fetched from the MIRROR
            # (by convention the canonical clone names each mirror remote after its forge; override with
            # --mirror-remote). Forward base-url/token-env + --allow-patch so L1's API patch-fallback can
            # run when a PR head ref is unfetchable (deleted/private fork).
            mirror_remote = args.mirror_remote or pr.forge
            cmd = ["bash", L1, "--forge", pr.forge, "--pr", str(pr.number), "--repo", args.repo,
                   "--mirror-remote", mirror_remote]
            if args.base_url:
                cmd += ["--base-url", args.base_url]
            if args.token_env:
                cmd += ["--token-env", args.token_env]
            if not getattr(pr, "head_fetchable", True):
                cmd += ["--allow-patch"]
            print(f"[relay] {_key(pr)} -> {pr.contrib_branch()} via L1 ...")
            rc = subprocess.run(cmd).returncode
            if rc != 0:
                print(f"[relay] L1 failed for {_key(pr)} (rc={rc}); leaving unrelayed", file=sys.stderr)
                continue
            canonical_repo = args.canonical_repo or args.repo
            branch = pr.contrib_branch()
            # Fix A: L1 only landed contrib/<forge>/pr-N in the LOCAL canonical clone. Push it to the
            # canonical server FIRST -- otherwise create_pull_request fails ("head branch not found").
            push_url = _canonical_push_url(args.canonical_base_url, canonical_repo,
                                           args.canonical_push_user, ctoken)
            print(f"[relay] pushing {branch} to canonical ...")  # NOTE: push_url (with token) NEVER printed
            prc, perr = _push_contrib_to_canonical(push_url, branch)
            if prc != 0:
                print(f"[relay] ERROR: canonical push of {branch} failed (rc={prc}); NOT opening a PR for "
                      f"{_key(pr)} (a PR with no head would fail). git said: {perr}", file=sys.stderr)
                continue
            # Open the canonical Forgejo PR from the now-pushed contrib branch (the contributor's canonical adapter).
            try:
                canonical.create_pull_request(canonical_repo,
                                              title=f"[relay:{pr.forge}#{pr.number}] {pr.title}",
                                              head=branch, base="main")
            except Exception as e:
                print(f"[relay] warn: canonical PR-open failed for {_key(pr)}: {e} "
                      f"(the contrib branch '{branch}' IS now on the canonical server -- open the PR "
                      f"manually: base=main head={branch})", file=sys.stderr)
            state[_key(pr)] = {"head_sha": pr.head_sha, "contrib_branch": pr.contrib_branch(),
                               "author": pr.author_login, "title": pr.title, "web_url": pr.web_url}
            _save_state(args.state_file, state)
            relayed += 1
    print(f"[relay] relayed {relayed} new PR(s) to canonical.")
    return 0


def _absorbed_comment(canonical_url, merged_sha):
    return (
        "Thank you! Your contribution was reviewed and merged into the sovereign canonical repository "
        f"at {canonical_url} as commit {merged_sha}, and has been mirrored back to this repo (see the "
        "default branch). Closing this PR as ABSORBED (not rejected).")


def notify(args):
    """Fix B leg d: comment on the ORIGINAL mirror PR that it was absorbed into canonical, then close
    it (absorbed != rejected). Run by a MAINTAINER AFTER the canonical PR is merged -- the relay does
    not observe the merge itself, so this is a deliberately separate subcommand."""
    if fa is None:
        print(f"[relay] cannot import forge_adapters: {_IMPORT_ERR}", file=sys.stderr)
        return 3
    token = os.environ.get(args.token_env) if args.token_env else None
    adapter = fa.make_adapter(args.forge, base_url=args.base_url, token=token)
    body = _absorbed_comment(args.canonical_url, args.merged_sha)
    print(f"[relay] notify {args.forge}#{args.pr}: commenting (absorbed as {args.merged_sha}) ...")
    adapter.add_comment(args.repo, args.pr, body)
    print(f"[relay] notify {args.forge}#{args.pr}: closing PR as ABSORBED ...")
    adapter.close_pull(args.repo, args.pr)
    print(f"[relay] {args.forge}#{args.pr} closed as absorbed.")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                allow_abbrev=False)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "relay"):
        sp = sub.add_parser(name)
        sp.add_argument("repo")
        sp.add_argument("--forge", action="append", required=True, choices=["github", "gitlab", "codeberg", "forgejo"])
        sp.add_argument("--base-url", default=None)
        sp.add_argument("--token-env", default=None, help="ENV var name holding the forge token (never a literal)")
        sp.add_argument("--mirror-remote", default=None,
                        help="git remote (in the canonical clone) that points at the forge mirror to "
                             "fetch the PR from; defaults to the forge name")
        sp.add_argument("--state-file", default=STATE_DEFAULT)
        if name == "relay":
            sp.add_argument("--actually-relay", action="store_true")
            sp.add_argument("--canonical-base-url", default=None, help="your canonical Forgejo base URL")
            sp.add_argument("--canonical-repo", default=None, help="canonical repo path (defaults to <repo>)")
            sp.add_argument("--canonical-token-env", default=None, help="ENV var holding the canonical token")
            sp.add_argument("--canonical-push-user", default="git",
                            help="git username for the ephemeral canonical push URL (token comes from "
                                 "--canonical-token-env; never printed/persisted). Default: git")

    # notify: run by a maintainer AFTER the canonical PR is merged -- comment 'absorbed as <sha>' on the
    # ORIGINAL mirror PR + close it (not-rejected). Separate from relay: the relay never sees the merge.
    npar = sub.add_parser("notify")
    npar.add_argument("repo", help="owner/repo (github/forgejo) or group/path|id (gitlab) of the MIRROR")
    npar.add_argument("--forge", required=True, choices=["github", "gitlab", "codeberg", "forgejo"])
    npar.add_argument("--pr", type=int, required=True, help="the mirror PR/MR number (GitLab: iid)")
    npar.add_argument("--merged-sha", required=True, help="canonical merge commit SHA")
    npar.add_argument("--canonical-url", required=True, help="public canonical repo link (for the comment)")
    npar.add_argument("--base-url", default=None)
    npar.add_argument("--token-env", default=None, help="ENV var name holding the forge token (never a literal)")

    args = p.parse_args(argv)
    return {"plan": plan, "relay": relay, "notify": notify}[args.cmd](args)


if __name__ == "__main__":
    raise SystemExit(main())
