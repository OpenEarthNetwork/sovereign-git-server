#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright 2026 VakeWorks AB
#
# ias-git-scrub-provenance.sh <dir> -- scrub internal PROVENANCE (NOT secrets) from a
# declassification staging tree, IN PLACE, so the public snapshot carries no build-tooling
# headers or agent identities.
#
# This is NOT a secret-scrubber: the leak-gate (check-confidentiality.sh +
# check-no-internal-leak.py, run by ias-git-declassify.sh) remains the authoritative
# secret guarantee and BACKSTOPS this step -- anything this misses simply re-fails the
# gate fail-closed (no leak, no flip). This step removes internal PROVENANCE so the
# leak-gate can PASS on a genuinely-public tree.
#
# WHAT IT DOES (idempotent):
#   (a) strips the WB-061 provenance header block -- the checked-against /
#       checked-by / checked-at header lines -- in BOTH `#`-comment files
#       (.sh/.py/.yaml/...) AND `` markdown front-comments, then removes
#       any now-empty `` husk left behind;
#   (b) maps agent tokens to neutral roles:
#         maintainer / maintainer / (maintainer) / the maintainer  -> maintainer
#         contributor / contributor / (contributor) / the contributor -> contributor
#       (most-specific first so 0-0-1 is not partially matched by 0-0).
#
# USAGE: ias-git-scrub-provenance.sh <staging-dir>
# EXIT:  0 ok; 2 usage/operational error. Prints a one-line summary of what changed.
set -euo pipefail
SELF="$(basename "$0")"
DIR="${1:?usage: ${0##*/} <staging-dir>}"
[ -d "$DIR" ] || { echo "${SELF}: ERROR: not a directory: ${DIR}" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "${SELF}: ERROR: python3 required" >&2; exit 2; }

SELF="$SELF" python3 - "$DIR" <<'PY'
import os, re, sys
self = os.environ.get("SELF", "ias-git-scrub-provenance.sh")
root = sys.argv[1]

HEADER_RE = re.compile(r'^\s*#\s*checked-(against|by|at):.*$')
# (regex, replacement) -- most-specific agent tokens FIRST
SUBS = [
    (re.compile(r'A\^1_\{0-0-1\}'), 'contributor'),
    (re.compile(r'contributor'),       'contributor'),
    (re.compile(r'A\^1_\{0-0\}'),   'maintainer'),
    (re.compile(r'maintainer'),         'maintainer'),
    (re.compile(r'\(the contributor\)'),        '(contributor)'),
    (re.compile(r'\(the maintainer\)'),        '(maintainer)'),
    (re.compile(r'\bAnu\b'),        'the contributor'),
    (re.compile(r'\bmom\b'),        'the maintainer'),
]
# process text files by extension; also extensionless files (LICENSE/NOTICE/etc.)
TEXT_EXT = {'.sh', '.py', '.md', '.txt', '.json', '.yaml', '.yml',
            '.html', '.css', '.js', '.toml', '.cff', '.cfg', '.ini', '.rs', '.kt'}
stripped = mapped = files = 0
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d != '.git']
    for fn in fns:
        p = os.path.join(dp, fn)
        base, ext = os.path.splitext(fn)
        ext = ext.lower()
        if '.' in fn and ext not in TEXT_EXT:
            continue
        try:
            with open(p, encoding='utf-8') as f:
                orig = f.read()
        except (UnicodeDecodeError, OSError):
            continue  # binary / unreadable -> leak-gate binary guard handles these
        out_lines, s_here, m_here = [], 0, 0
        for ln in orig.splitlines(keepends=True):
            if HEADER_RE.match(ln):
                s_here += 1
                continue
            new = ln
            for rx, repl in SUBS:
                new, n = rx.subn(repl, new)
                m_here += n
            out_lines.append(new)
        text = ''.join(out_lines)
        # remove now-empty  comment husks (header block lived inside)
        text = re.sub(r'<!--\s*-->\n?', '', text)
        if text != orig:
            with open(p, 'w', encoding='utf-8') as f:
                f.write(text)
            files += 1
            stripped += s_here
            mapped += m_here
print(f"{self}: scrubbed {stripped} provenance-header line(s) + {mapped} agent-token(s) across {files} file(s)")
PY
