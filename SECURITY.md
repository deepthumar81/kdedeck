# Security policy

## Supported versions

The `main` branch is the actively maintained development line. Published
releases will document their support status in the release notes.

## Reporting a vulnerability

Please do not open a public issue for an undisclosed security vulnerability.
Use GitHub's private security advisory/reporting flow for this repository. If
that option is unavailable, contact the repository maintainer privately through
GitHub and include the minimum information needed to reproduce the issue.

Do not include passwords, pairing codes, bearer tokens, private keys, personal
data, or production configuration in a report.

Useful reports include:

- affected commit, release, or component;
- a concise impact statement;
- reproduction steps or a minimal proof of concept;
- any relevant platform and toolchain details; and
- a suggested mitigation, if known.

Please allow maintainers reasonable time to investigate and prepare a fix
before publicly disclosing the issue. We will acknowledge reports, coordinate a
fix where practical, and document security fixes in release notes.

## Security boundaries

KDE Deck is Linux-first. LAN mode requires TLS/WSS, clients must be paired, and
the daemon defaults to loopback. Review
[`docs/security/tls-setup.md`](docs/security/tls-setup.md) before exposing a
daemon beyond the local machine.
