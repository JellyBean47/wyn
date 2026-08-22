# Security

## Report a vulnerability

Email the maintainer privately. Do not open a public GitHub issue for:

- credential leaks in this repo or in bottles
- accidental inclusion of Apple GPTK or other non-redistributable files
- remote code execution in Wyn or its helpers

## Scope

Wyn launches third-party Windows software under Wine. Game publishers’ ToS and
anti-cheat still apply. This project does not provide security guarantees for
those programs.

## Supply chain

Runtime downloads are SHA-256 pinned in [`DEPENDENCIES.md`](DEPENDENCIES.md).
If a hash fails, do not ignore it — the file is not the pinned artifact.
