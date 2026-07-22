# Privacy

**This software collects no personal data.**

It is a set of scripts you run on infrastructure **you** own and control to
operate your own git server and mirrors. It has no backend operated by us, no
telemetry, no analytics, and no phone-home.

- Any data it touches (git repositories, their history, and your own
  configuration) stays on your servers and the git hosts you point it at.
- Credentials (API tokens, SSH keys, GPG keys) are read from your environment
  or files you control and are never transmitted anywhere except the git hosts
  you configure, over authenticated channels.
- The confidentiality leak-gate exists precisely to keep secrets and personal
  data **out** of any repository you publish.

Because there is no data controller or processor role created by using these
scripts, no privacy-law registration applies to the tool itself; your
obligations are those that already apply to the repositories and servers you
operate.
