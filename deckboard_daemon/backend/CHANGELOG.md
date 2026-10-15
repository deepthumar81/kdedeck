## Unreleased

- Hardened the standalone daemon with authenticated WebSocket sessions, pairing,
  bounded requests, revision-aware configuration saves, and TLS/WSS support for
  LAN deployments.
- Restricted application launches to locally approved application identities.
- Hardened system icon serving for approved PNG, SVG, and XPM roots, including
  traversal, symlink, content, size, and unsafe SVG checks.
- Added Flutter pairing, secure credential storage, reconnect fencing, and
  revision-conflict recovery UI.
- Added embedded-server authentication and HTTPS/WSS fail-closed behavior.

## 1.0.0

- Initial version.
