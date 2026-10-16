# Contributing to KDE Deck

Thanks for helping improve KDE Deck. Contributions are welcome for the Linux
daemon, browser configurator, Flutter client, tray wrapper, documentation, and
tests.

## Before you start

- Read the [README](README.md) for the supported architecture and current
  limitations.
- Read the security requirements in
  [`docs/security/security-requirements.md`](docs/security/security-requirements.md)
  before changing network, authentication, command execution, configuration,
  or filesystem behavior.
- For security vulnerabilities, follow [`SECURITY.md`](SECURITY.md) instead of
  opening a public issue.

## Development setup

The supported toolchain is pinned in the repository:

- Dart `3.13.1`
- Flutter `3.47.1`
- Node.js `22.23.1`
- Go version from `deckboard_daemon/tray/go.mod`

Install component dependencies from the repository root:

```bash
dart pub get --directory deckboard_daemon/backend
flutter pub get --directory kdedeck_mobile
go -C deckboard_daemon/tray mod download
```

On Debian or Ubuntu, the tray checks also need:

```bash
sudo apt-get update
sudo apt-get install --no-install-recommends libayatana-appindicator3-dev
```

Copy `.env.example` only when local environment variables are needed. Never
commit certificates, private keys, pairing tokens, bearer tokens, or local
configuration files.

## Make a change

1. Create a focused branch from `main`.
2. Add or update a meaningful test for behavior that changes.
3. Preserve the existing security boundary and compatibility behavior.
4. Update relevant documentation and `docs/DEVELOPMENT_LOG.md` for a
   substantial change.
5. Run the complete repository check:

   ```bash
   make test
   ```

6. For Dart changes, also run:

   ```bash
   cd deckboard_daemon/backend
   dart analyze
   dart format --output=none --set-exit-if-changed lib test
   ```

## Pull requests

- Keep each pull request focused and explain the user-visible result.
- Describe security, compatibility, and platform implications.
- Include the exact checks you ran and their results.
- Do not include secrets, generated credentials, device captures containing
  private data, or unrelated formatting changes.
- Maintainers may request changes before merging. All contributions are
  accepted under the GNU GPLv3-or-later terms in [`LICENSE`](LICENSE).

## Architecture quick reference

- `deckboard_daemon/backend`: Dart daemon, HTTP/WebSocket protocol, Linux
  actions, persistence, and browser assets.
- `deckboard_daemon/tray`: Go system-tray wrapper.
- `kdedeck_mobile`: Flutter Android/mobile client.
- `docs`: architecture, protocol, threat model, testing, decisions, and the
  durable development log.
