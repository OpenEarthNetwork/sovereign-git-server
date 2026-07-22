#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# forge_adapters.py -- L2 relay-bot forge adapters (github / gitlab / forgejo|codeberg|canonical).
#
# ROLE in the framework: the relay-bot CORE (the maintainer's lane: git fetch/push/PR-open/CI/comment) needs a
# UNIFORM view of "what open contributions exist on each mirror" + "how do I fetch each one". This
# module is that adapter seam. Each adapter normalizes a forge's PR/MR REST API into PullRequest and
# knows the forge's fetchable PR git-ref.
#
# FORGE-AGNOSTIC PRIMITIVE: every forge exposes a PR as a fetchable ref --
#   GitHub / Forgejo|Gitea : refs/pull/<N>/head
#   GitLab                 : refs/merge-requests/<iid>/head
# so `git fetch <mirror-remote> <pr_ref>` is uniform once the ref string is right. When that ref is
# NOT fetchable (deleted/private fork -> 404), fall back to fetch_patch() (the API diff) -- review note (c1).
#
# OFFLINE/TESTABLE BY DESIGN: all network I/O goes through an injected http_get callable. The default
# uses urllib; tests inject a fake returning fixtures, so the whole layer runs with NO external creds
# (matches the LOCAL-FIRST dogfood: forge APIs stubbed).
#
# PROVENANCE (review note b): PullRequest carries author identity so the relay preserves the original
# author + any DCO Signed-off-by; the relay MUST NOT re-author. GitHub may expose only a noreply login
# (author_email None) -> the relay records author_login + web_url so attribution survives.
from __future__ import annotations

import abc
import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Optional

# http_get(url, headers) -> (status_code:int, body:bytes)
HttpGet = Callable[[str, dict], "tuple[int, bytes]"]


def _urllib_get(url: str, headers: dict) -> "tuple[int, bytes]":
    req = urllib.request.Request(url, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.getcode(), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read() if hasattr(e, "read") else b""


def _urllib_post(url: str, headers: dict, data: bytes) -> "tuple[int, bytes]":
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.getcode(), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read() if hasattr(e, "read") else b""


def _urllib_send(method: str, url: str, headers: dict, data: bytes) -> "tuple[int, bytes]":
    """Generic urllib sender for verbs beyond POST (PATCH / PUT) -- the close-as-absorbed leg (Fix B)."""
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.getcode(), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read() if hasattr(e, "read") else b""


@dataclass
class PullRequest:
    forge: str
    number: int                    # GitHub/Forgejo PR number; GitLab MR iid
    title: str
    head_ref: str                  # fetchable git ref: refs/pull/N/head | refs/merge-requests/iid/head
    head_sha: str = ""
    author_login: str = ""
    author_name: Optional[str] = None
    author_email: Optional[str] = None
    source_clone_url: Optional[str] = None   # fork clone URL (may be None: same-repo or deleted fork)
    head_fetchable: bool = True              # False => ref likely 404s (deleted/private fork) => use patch
    web_url: str = ""

    def contrib_branch(self) -> str:
        """Canonical-side staging branch name for this contribution (relay pushes here)."""
        return f"contrib/{self.forge}/pr-{self.number}"


class ForgeAdapter(abc.ABC):
    """Common interface. One instance per (forge, base_url). Codeberg + canonical git.example.org are
    both Forgejo -> the SAME ForgejoAdapter class serves both (de-risking note: adapter matrix ~1.5)."""

    name: str = "forge"

    def __init__(self, base_url: str, token: Optional[str] = None, http_get=None, http_post=None,
                 http_send=None):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self._http_get = http_get or _urllib_get
        self._http_post = http_post or _urllib_post
        # http_send(method, url, headers, data) -> (status, body) for PATCH/PUT (Fix B close_pull).
        self._http_send = http_send or _urllib_send

    def _get_json(self, url: str):
        status, body = self._http_get(url, self._headers())
        if status < 200 or status >= 300:
            raise ForgeAPIError(f"{self.name} GET {url} -> HTTP {status}")
        return json.loads(body.decode("utf-8", "replace"))

    def _post_json(self, url: str, payload: dict):
        headers = dict(self._headers()); headers["Content-Type"] = "application/json"
        status, body = self._http_post(url, headers, json.dumps(payload).encode("utf-8"))
        if status < 200 or status >= 300:
            raise ForgeAPIError(f"{self.name} POST {url} -> HTTP {status}: {body[:200]!r}")
        return json.loads(body.decode("utf-8", "replace")) if body else {}

    def _send_json(self, method: str, url: str, payload: dict):
        # PATCH/PUT with a JSON body -- token stays in the header (via _headers), never in the URL.
        headers = dict(self._headers()); headers["Content-Type"] = "application/json"
        status, body = self._http_send(method, url, headers, json.dumps(payload).encode("utf-8"))
        if status < 200 or status >= 300:
            raise ForgeAPIError(f"{self.name} {method} {url} -> HTTP {status}: {body[:200]!r}")
        return json.loads(body.decode("utf-8", "replace")) if body else {}

    def add_comment(self, repo: str, number: int, body: str) -> dict:
        """Post a comment on a mirror PR/MR (the notify/close-as-absorbed leg, Fix B). Run by a
        maintainer AFTER the canonical PR is merged -- the relay does not observe the merge itself."""
        raise NotImplementedError(f"{self.name}: add_comment not implemented")

    def close_pull(self, repo: str, number: int) -> dict:
        """Close a mirror PR/MR WITHOUT merging (absorbed, not rejected). Pairs with add_comment."""
        raise NotImplementedError(f"{self.name}: close_pull not implemented")

    def create_pull_request(self, repo: str, title: str, head: str, base: str = "main",
                            body: str = "") -> dict:
        """Open a PR on this forge. Only the CANONICAL (Forgejo) forge implements this -- we never
        create PRs on read-only mirrors. Returns the created PR JSON (incl. its number/url)."""
        raise NotImplementedError(
            f"{self.name}: create_pull_request is canonical-only; mirrors are read-only reflections.")

    def _headers(self) -> dict:
        return {"Accept": "application/json"}

    @abc.abstractmethod
    def list_open_prs(self, repo: str) -> "list[PullRequest]":
        ...

    @abc.abstractmethod
    def pr_ref(self, number: int) -> str:
        ...

    @abc.abstractmethod
    def fetch_patch(self, repo: str, number: int) -> str:
        """Return the unified-diff text for a PR (fallback when the head ref is unfetchable)."""
        ...


class ForgeAPIError(RuntimeError):
    pass


class GitHubAdapter(ForgeAdapter):
    name = "github"

    def __init__(self, repo_api_base: str = "https://api.github.com", token=None, http_get=None,
                 http_post=None, http_send=None):
        super().__init__(repo_api_base, token, http_get, http_post, http_send)

    def _headers(self):
        h = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    def add_comment(self, repo: str, number: int, body: str) -> dict:
        # GitHub: PRs are issues for the comment API -> POST /repos/{repo}/issues/{n}/comments.
        return self._post_json(f"{self.base_url}/repos/{repo}/issues/{number}/comments", {"body": body})

    def close_pull(self, repo: str, number: int) -> dict:
        # GitHub: PATCH the pull with state=closed (no merge).
        return self._send_json("PATCH", f"{self.base_url}/repos/{repo}/pulls/{number}",
                               {"state": "closed"})

    def list_open_prs(self, repo: str) -> "list[PullRequest]":
        data = self._get_json(f"{self.base_url}/repos/{repo}/pulls?state=open&per_page=100")
        out = []
        for pr in data:
            head = pr.get("head") or {}
            head_repo = head.get("repo")  # None when the fork was deleted -> head ref may 404 (CR c1)
            user = pr.get("user") or {}
            out.append(PullRequest(
                forge=self.name,
                number=int(pr["number"]),
                title=pr.get("title", ""),
                head_ref=self.pr_ref(int(pr["number"])),
                head_sha=head.get("sha", ""),
                author_login=user.get("login", ""),
                # GitHub PR payload carries no author email (noreply privacy) -> None; relay keeps login.
                author_name=None, author_email=None,
                source_clone_url=(head_repo or {}).get("clone_url"),
                head_fetchable=head_repo is not None,
                web_url=pr.get("html_url", ""),
            ))
        return out

    def pr_ref(self, number: int) -> str:
        return f"refs/pull/{number}/head"

    def fetch_patch(self, repo: str, number: int) -> str:
        h = dict(self._headers()); h["Accept"] = "application/vnd.github.v3.diff"
        status, body = self._http_get(f"{self.base_url}/repos/{repo}/pulls/{number}", h)
        if status < 200 or status >= 300:
            raise ForgeAPIError(f"github diff {repo}#{number} -> HTTP {status}")
        return body.decode("utf-8", "replace")


class GitLabAdapter(ForgeAdapter):
    name = "gitlab"

    def __init__(self, api_base: str = "https://gitlab.com/api/v4", token=None, http_get=None,
                 http_post=None, http_send=None):
        super().__init__(api_base, token, http_get, http_post, http_send)

    def _headers(self):
        h = {"Accept": "application/json"}
        if self.token:
            h["PRIVATE-TOKEN"] = self.token
        return h

    def _proj(self, repo: str) -> str:
        # GitLab wants the project path URL-encoded (group%2Fsub%2Frepo) OR a numeric id.
        return urllib.parse.quote(repo, safe="") if not repo.isdigit() else repo

    def add_comment(self, repo: str, number: int, body: str) -> dict:
        # GitLab: MR note (iid, per CR c3) -> POST /projects/{enc}/merge_requests/{iid}/notes.
        proj = self._proj(repo)
        return self._post_json(
            f"{self.base_url}/projects/{proj}/merge_requests/{number}/notes", {"body": body})

    def close_pull(self, repo: str, number: int) -> dict:
        # GitLab: PUT the MR (iid) with state_event=close.
        proj = self._proj(repo)
        return self._send_json(
            "PUT", f"{self.base_url}/projects/{proj}/merge_requests/{number}", {"state_event": "close"})

    def list_open_prs(self, repo: str) -> "list[PullRequest]":
        proj = self._proj(repo)
        data = self._get_json(f"{self.base_url}/projects/{proj}/merge_requests?state=opened&per_page=100")
        out = []
        for mr in data:
            author = mr.get("author") or {}
            # GitLab uses IID (project-internal), NOT the global MR id, for refs + API paths (CR c3).
            iid = int(mr["iid"])
            out.append(PullRequest(
                forge=self.name,
                number=iid,
                title=mr.get("title", ""),
                head_ref=self.pr_ref(iid),
                head_sha=mr.get("sha", ""),
                author_login=author.get("username", ""),
                author_name=author.get("name"),
                author_email=None,
                source_clone_url=None,
                # MR head ref lives on the TARGET project and is usually fetchable; fork-source deletion
                # can still 404 -> relay falls back to fetch_patch on git-fetch failure.
                head_fetchable=True,
                web_url=mr.get("web_url", ""),
            ))
        return out

    def pr_ref(self, number: int) -> str:
        return f"refs/merge-requests/{number}/head"

    def fetch_patch(self, repo: str, number: int) -> str:
        proj = self._proj(repo)
        # raw_diffs returns the concatenated unified diff for the MR.
        status, body = self._http_get(
            f"{self.base_url}/projects/{proj}/merge_requests/{number}/raw_diffs", self._headers())
        if status < 200 or status >= 300:
            raise ForgeAPIError(f"gitlab diff {repo}!{number} -> HTTP {status}")
        return body.decode("utf-8", "replace")


class ForgejoAdapter(ForgeAdapter):
    """Gitea/Forgejo API. Serves Codeberg AND the canonical git.example.org (same software) by base_url."""
    name = "forgejo"

    def __init__(self, api_base: str, token=None, http_get=None, name: Optional[str] = None,
                 http_post=None, http_send=None):
        super().__init__(api_base, token, http_get, http_post, http_send)
        if name:
            self.name = name  # e.g. "codeberg" so contrib branches read contrib/codeberg/pr-N

    def create_pull_request(self, repo: str, title: str, head: str, base: str = "main",
                            body: str = "") -> dict:
        # Gitea/Forgejo: POST /repos/{owner}/{repo}/pulls  {title, head, base, body}. Used on the
        # CANONICAL server to open the relayed contrib/<forge>/pr-N as a reviewable PR (the relay's
        # write step). head is the canonical-side branch the relay already pushed.
        return self._post_json(f"{self.base_url}/repos/{repo}/pulls",
                               {"title": title, "head": head, "base": base, "body": body})

    def add_comment(self, repo: str, number: int, body: str) -> dict:
        # Gitea/Forgejo: PRs are issues for comments -> POST /repos/{repo}/issues/{n}/comments.
        return self._post_json(f"{self.base_url}/repos/{repo}/issues/{number}/comments", {"body": body})

    def close_pull(self, repo: str, number: int) -> dict:
        # Gitea/Forgejo: PATCH the pull with state=closed.
        return self._send_json("PATCH", f"{self.base_url}/repos/{repo}/pulls/{number}",
                               {"state": "closed"})

    def _headers(self):
        h = {"Accept": "application/json"}
        if self.token:
            h["Authorization"] = f"token {self.token}"
        return h

    def list_open_prs(self, repo: str) -> "list[PullRequest]":
        data = self._get_json(f"{self.base_url}/repos/{repo}/pulls?state=open&limit=50")
        out = []
        for pr in data:
            head = pr.get("head") or {}
            head_repo = head.get("repo")
            user = pr.get("user") or {}
            out.append(PullRequest(
                forge=self.name,
                number=int(pr["number"]),
                title=pr.get("title", ""),
                head_ref=self.pr_ref(int(pr["number"])),
                head_sha=head.get("sha", ""),
                author_login=user.get("login", ""),
                author_name=user.get("full_name") or None,
                author_email=user.get("email") or None,
                source_clone_url=(head_repo or {}).get("clone_url"),
                head_fetchable=head_repo is not None,
                web_url=pr.get("html_url", ""),
            ))
        return out

    def pr_ref(self, number: int) -> str:
        return f"refs/pull/{number}/head"

    def fetch_patch(self, repo: str, number: int) -> str:
        status, body = self._http_get(f"{self.base_url}/repos/{repo}/pulls/{number}.diff", self._headers())
        if status < 200 or status >= 300:
            raise ForgeAPIError(f"forgejo diff {repo}#{number} -> HTTP {status}")
        return body.decode("utf-8", "replace")


# Registry: build an adapter by forge name. base_url lets one ForgejoAdapter serve codeberg + canonical.
def make_adapter(forge: str, base_url: Optional[str] = None, token=None, http_get=None,
                 http_post=None, http_send=None) -> ForgeAdapter:
    f = forge.lower()
    if f == "github":
        return GitHubAdapter(base_url or "https://api.github.com", token, http_get,
                             http_post=http_post, http_send=http_send)
    if f == "gitlab":
        return GitLabAdapter(base_url or "https://gitlab.com/api/v4", token, http_get,
                             http_post=http_post, http_send=http_send)
    if f in ("forgejo", "codeberg", "canonical", "gitea"):
        if not base_url:
            base_url = "https://codeberg.org/api/v1" if f == "codeberg" else None
        if not base_url:
            raise ValueError(f"{forge}: base_url required (e.g. https://git.example.org/api/v1)")
        return ForgejoAdapter(base_url, token, http_get,
                              name=(f if f != "gitea" else "forgejo"),
                              http_post=http_post, http_send=http_send)
    raise ValueError(f"unknown forge: {forge}")


SUPPORTED_FORGES = ("github", "gitlab", "codeberg", "forgejo")


def pr_ref_for(forge: str, number: int) -> str:
    """Forge-static fetchable PR ref -- no adapter/base_url/network needed. GitLab uses
    merge-requests/<iid>/head; everything else uses pull/<N>/head."""
    return (f"refs/merge-requests/{number}/head" if forge.lower() == "gitlab"
            else f"refs/pull/{number}/head")


def _main(argv=None):
    import argparse
    import os
    import sys

    ap = argparse.ArgumentParser(
        description="Sovereign-git L2 forge adapters CLI (list open PRs / fetch a PR diff). "
                    "Tokens are read from an env var (--token-env), NEVER passed on the command line.",
        allow_abbrev=False)  # so `--token X` is a hard error, not an abbreviation of --token-env
    ap.add_argument("action", choices=["list", "patch", "ref"], help="list PRs | fetch diff | print git ref")
    ap.add_argument("forge", choices=list(SUPPORTED_FORGES) + ["canonical", "gitea"])
    ap.add_argument("repo", nargs="?", default="", help="owner/repo (github/forgejo) or group/path|id (gitlab)")
    ap.add_argument("number", nargs="?", type=int, help="PR/MR number (for patch/ref)")
    ap.add_argument("--base-url", default=None, help="API base (required for forgejo/canonical)")
    ap.add_argument("--token-env", default=None, help="name of env var holding the API token")
    args = ap.parse_args(argv)

    # `ref` is forge-static -> resolve without instantiating a (base_url-requiring) adapter.
    if args.action == "ref":
        if args.number is None:
            print("error: ref needs a number", file=sys.stderr)
            return 2
        print(pr_ref_for(args.forge, args.number))
        return 0

    token = os.environ.get(args.token_env) if args.token_env else None
    try:
        adapter = make_adapter(args.forge, args.base_url, token)
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if args.action == "list":
        if not args.repo:
            print("error: list needs a repo", file=sys.stderr)
            return 2
        try:
            prs = adapter.list_open_prs(args.repo)
        except (ForgeAPIError, Exception) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        for pr in prs:
            print(json.dumps({
                "forge": pr.forge, "number": pr.number, "title": pr.title, "head_ref": pr.head_ref,
                "head_sha": pr.head_sha, "author_login": pr.author_login,
                "author_email": pr.author_email, "head_fetchable": pr.head_fetchable,
                "contrib_branch": pr.contrib_branch(), "web_url": pr.web_url}))
        return 0
    if args.action == "patch":
        if not args.repo or args.number is None:
            print("error: patch needs repo + number", file=sys.stderr)
            return 2
        try:
            sys.stdout.write(adapter.fetch_patch(args.repo, args.number))
        except Exception as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        return 0
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(_main())
