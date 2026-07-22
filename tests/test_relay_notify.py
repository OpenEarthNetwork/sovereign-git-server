#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# OFFLINE/MOCKED relay-level tests for Fix A (canonical push before create_pull_request) + Fix B
# (notify subcommand -> add_comment then close_pull). No real forge, no real push, no real git.example.org:
#   * notify subcommand arg-parse + calls add_comment then close_pull with the right args (adapter mocked).
#   * _canonical_push_url derivation (strip /api/v1, inject <user>:<token>) + token-never-leaked helpers.
#   * relay enact path pushes the contrib branch (via a monkeypatched subprocess) BEFORE create_pull_request,
#     aborts the PR if the push fails, and never leaks the token to stdout/argv-log.
import importlib.util
import io
import os
import sys
import types
import unittest
from contextlib import redirect_stdout, redirect_stderr

_HERE = os.path.dirname(os.path.abspath(__file__))
# bundle-root-relative: test lives at <bundle>/tests/, so .. is the bundle root
_RELAY = os.path.join(_HERE, "..", "relay", "ias-git-relay.py")
_FA = os.path.join(_HERE, "..", "relay", "forge_adapters.py")

# Load forge_adapters first (relay imports it as a sibling).
_fspec = importlib.util.spec_from_file_location("forge_adapters", _FA)
fa = importlib.util.module_from_spec(_fspec)
sys.modules["forge_adapters"] = fa
_fspec.loader.exec_module(fa)

_spec = importlib.util.spec_from_file_location("ias_git_relay", _RELAY)
relay = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(relay)


class CanonicalPushUrl(unittest.TestCase):
    def test_strip_api_v1_and_inject_credentials(self):
        url = relay._canonical_push_url("https://git.example.org/api/v1", "o/r", "git", "TOK")
        self.assertTrue(url.startswith("https://git:TOK@git.example.org/"))
        self.assertTrue(url.endswith("/o/r.git"))
        self.assertNotIn("/api/v1", url)

    def test_url_form(self):
        url = relay._canonical_push_url("https://git.example.org/api/v1", "OpenEarthNetwork/openearth-gryph",
                                        "git", "TOK")
        self.assertEqual(url, "https://git:TOK@git.example.org/OpenEarthNetwork/openearth-gryph.git")

    def test_no_token_no_credentials(self):
        url = relay._canonical_push_url("https://git.example.org/api/v1", "o/r", "git", None)
        self.assertEqual(url, "https://git.example.org/o/r.git")
        self.assertNotIn("@", url)

    def test_trailing_slash_and_api_v4(self):
        url = relay._canonical_push_url("https://g.example.org/api/v4/", "o/r", "bot", "T")
        self.assertEqual(url, "https://bot:T@g.example.org/o/r.git")


class PushHelperRedaction(unittest.TestCase):
    def test_push_redacts_token_in_git_output(self):
        # Simulate git echoing the credential URL in its error, and assert we redact it.
        calls = {}

        def fake_run(argv, capture_output=False, text=False):
            calls["argv"] = argv
            return types.SimpleNamespace(
                returncode=1,
                stderr="fatal: could not read from https://git:SECRET@git.example.org/o/r.git\n",
                stdout="")
        orig = relay.subprocess.run
        relay.subprocess.run = fake_run
        try:
            rc, err = relay._push_contrib_to_canonical(
                "https://git:SECRET@git.example.org/o/r.git", "contrib/github/pr-7")
        finally:
            relay.subprocess.run = orig
        self.assertEqual(rc, 1)
        self.assertNotIn("SECRET", err)              # token scrubbed from surfaced git output
        self.assertIn("***@", err)
        # token IS in argv (that is how git auth works) but we never print argv ourselves.
        self.assertIn("https://git:SECRET@git.example.org/o/r.git", calls["argv"])


class _FakeAdapter:
    def __init__(self):
        self.calls = []

    def add_comment(self, repo, number, body):
        self.calls.append(("add_comment", repo, number, body)); return {}

    def close_pull(self, repo, number):
        self.calls.append(("close_pull", repo, number)); return {}


class NotifySubcommand(unittest.TestCase):
    def test_notify_argparse_and_calls_comment_then_close(self):
        fake = _FakeAdapter()
        orig = relay.fa.make_adapter
        relay.fa.make_adapter = lambda *a, **k: fake
        out, err = io.StringIO(), io.StringIO()
        try:
            with redirect_stdout(out), redirect_stderr(err):
                rc = relay.main([
                    "notify", "OpenEarthNetwork/openearth-gryph", "--forge", "github", "--pr", "7",
                    "--merged-sha", "deadbeef",
                    "--canonical-url", "https://git.example.org/OpenEarthNetwork/openearth-gryph"])
        finally:
            relay.fa.make_adapter = orig
        self.assertEqual(rc, 0)
        kinds = [c[0] for c in fake.calls]
        self.assertEqual(kinds, ["add_comment", "close_pull"])            # order: comment THEN close
        _, repo, num, body = fake.calls[0]
        self.assertEqual((repo, num), ("OpenEarthNetwork/openearth-gryph", 7))
        self.assertIn("deadbeef", body)
        self.assertIn("ABSORBED", body)
        self.assertIn("https://git.example.org/OpenEarthNetwork/openearth-gryph", body)
        self.assertEqual(fake.calls[1], ("close_pull", "OpenEarthNetwork/openearth-gryph", 7))

    def test_absorbed_comment_says_not_rejected(self):
        body = relay._absorbed_comment("https://git.example.org/o/r", "abc123")
        self.assertIn("not rejected", body.lower())
        self.assertIn("abc123", body)


class _StubPR:
    forge = "github"
    number = 7
    title = "Fix bug"
    head_sha = "sha7"
    author_login = "forker"
    web_url = "https://github.com/o/r/pull/7"
    head_fetchable = True

    def contrib_branch(self):
        return "contrib/github/pr-7"


class RelayEnactPushesBeforePR(unittest.TestCase):
    def test_push_attempted_with_contrib_branch_then_pr_opened_no_token_leak(self):
        events = []

        class StubAdapter:
            def list_open_prs(self, repo):
                return [_StubPR()]

        class StubCanonical:
            def create_pull_request(self, repo, title, head, base="main", body=""):
                events.append(("create_pr", repo, head, base)); return {"number": 1}

        # Monkeypatch make_adapter: mirror -> StubAdapter, canonical(forgejo) -> StubCanonical.
        def fake_make_adapter(forge, base_url=None, token=None, **k):
            return StubCanonical() if forge == "forgejo" else StubAdapter()

        # L1 delegate + git push both mocked -> NO real fetch/push.
        def fake_subrun(argv, capture_output=False, text=False):
            if argv[:2] == ["git", "push"]:
                events.append(("git_push", argv))
                return types.SimpleNamespace(returncode=0, stderr="", stdout="")
            events.append(("l1", argv))            # bash L1 ...
            return types.SimpleNamespace(returncode=0)

        args = types.SimpleNamespace(
            actually_relay=True, forge=["github"], repo="o/r", base_url=None, token_env=None,
            mirror_remote=None, state_file="/tmp/_relay_state_test.json",
            canonical_base_url="https://git.example.org/api/v1",
            canonical_repo="OpenEarthNetwork/openearth-gryph",
            canonical_token_env="CANTOK", canonical_push_user="git")
        os.environ["CANTOK"] = "SUPERSECRET"
        orig_make, orig_run = relay.fa.make_adapter, relay.subprocess.run
        relay.fa.make_adapter = fake_make_adapter
        relay.subprocess.run = fake_subrun
        out, err = io.StringIO(), io.StringIO()
        try:
            with redirect_stdout(out), redirect_stderr(err):
                rc = relay.relay(args)
        finally:
            relay.fa.make_adapter, relay.subprocess.run = orig_make, orig_run
            os.environ.pop("CANTOK", None)
            try:
                os.remove("/tmp/_relay_state_test.json")
            except OSError:
                pass
        self.assertEqual(rc, 0)
        kinds = [e[0] for e in events]
        self.assertIn("git_push", kinds)
        self.assertIn("create_pr", kinds)
        # ORDER: push happens BEFORE create_pr.
        self.assertLess(kinds.index("git_push"), kinds.index("create_pr"))
        push_argv = next(e[1] for e in events if e[0] == "git_push")
        self.assertIn("contrib/github/pr-7:contrib/github/pr-7", push_argv)
        # create_pr uses the contrib branch as head.
        cpr = next(e for e in events if e[0] == "create_pr")
        self.assertEqual(cpr[2], "contrib/github/pr-7")
        # TOKEN must not leak to our own stdout/stderr (it may be in git argv, which we never print).
        self.assertNotIn("SUPERSECRET", out.getvalue())
        self.assertNotIn("SUPERSECRET", err.getvalue())

    def test_push_failure_aborts_pr(self):
        events = []

        class StubAdapter:
            def list_open_prs(self, repo):
                return [_StubPR()]

        class StubCanonical:
            def create_pull_request(self, *a, **k):
                events.append("create_pr"); return {}

        def fake_make_adapter(forge, base_url=None, token=None, **k):
            return StubCanonical() if forge == "forgejo" else StubAdapter()

        def fake_subrun(argv, capture_output=False, text=False):
            if argv[:2] == ["git", "push"]:
                return types.SimpleNamespace(returncode=1, stderr="denied", stdout="")
            return types.SimpleNamespace(returncode=0)

        args = types.SimpleNamespace(
            actually_relay=True, forge=["github"], repo="o/r", base_url=None, token_env=None,
            mirror_remote=None, state_file="/tmp/_relay_state_test2.json",
            canonical_base_url="https://git.example.org/api/v1", canonical_repo="o/r",
            canonical_token_env=None, canonical_push_user="git")
        orig_make, orig_run = relay.fa.make_adapter, relay.subprocess.run
        relay.fa.make_adapter = fake_make_adapter
        relay.subprocess.run = fake_subrun
        out, err = io.StringIO(), io.StringIO()
        try:
            with redirect_stdout(out), redirect_stderr(err):
                rc = relay.relay(args)
        finally:
            relay.fa.make_adapter, relay.subprocess.run = orig_make, orig_run
            try:
                os.remove("/tmp/_relay_state_test2.json")
            except OSError:
                pass
        self.assertEqual(rc, 0)                      # relay completes, just relays 0
        self.assertNotIn("create_pr", events)        # PR NOT opened when the push failed


if __name__ == "__main__":
    unittest.main(verbosity=2)
