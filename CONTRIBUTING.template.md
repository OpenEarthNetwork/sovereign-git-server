<!--
TEMPLATE: copy into each PUBLIC mirror repo as CONTRIBUTING.md. Replace {{PLACEHOLDERS}}. Zero build (L0).
-->

# Contributing to {{PROJECT_NAME}}

Thank you for contributing. This project develops on a **sovereign git server** and mirrors out to
several public forges for reach. **You may open a pull/merge request on whichever mirror you already
use** — we relay it back to the canonical server, review and merge it there, and the merge flows back
out to every mirror.

## Where the code lives

- **Canonical (source of truth, final merge):** {{CANONICAL_URL}}  (self-hosted {{FORGE_SOFTWARE}})
- **Public mirrors (read-only reflections; pick any to contribute):**
  - GitHub: {{GITHUB_URL}}
  - GitLab: {{GITLAB_URL}}
  - Codeberg: {{CODEBERG_URL}}

> The mirrors are **push-mirrored** from the canonical server, so a merge on a mirror would be
> overwritten on the next sync. That is why contributions are **relayed to canonical and merged
> there** — never merged on a mirror.

## How to contribute

1. Fork on any mirror above and open a PR/MR against its `main` branch, as you normally would.
2. A maintainer relays your PR to the canonical server (`{{CANONICAL_URL}}`), where review + CI happen.
3. When merged on canonical, the change mirrors back out to every forge automatically. We comment on
   your original PR with the upstream link and the merged commit.

Prefer to avoid a forge entirely? You can also send a patch series
(`git format-patch` / `git request-pull`) to {{PATCH_CONTACT}} — the most forge-neutral path.

## Sign your work (DCO)

We use the **Developer Certificate of Origin** (DCO), not a CLA. Add a `Signed-off-by` line to each
commit certifying you have the right to submit it under the project licence:

```
git commit -s -m "your message"
```

This appends `Signed-off-by: Your Name <your@email>`. Contributions are accepted under the project's
**{{LICENSE}}** licence (Apache-2.0 already makes inbound = outbound). Unsigned commits are asked to
add the sign-off before merge.

> If you contribute through a forge whose PR is relayed by our bot, keep your `Signed-off-by` on each
> commit — the relay preserves it. If your contribution is imported as a flat diff (rare; when your
> fork's branch isn't fetchable), a maintainer will ask you to confirm the sign-off, since a flat diff
> cannot carry it.

## Questions

Open an issue on any mirror, or reach us at {{CONTACT}}.
