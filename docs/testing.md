# KDE Deck testing strategy

## Purpose

This document defines the quality gates for security, Linux compatibility, and
future cross-platform work. Security changes must not remove supported installed
applications, system icons, boards, or Linux actions.

## Test layers

### Static checks

- `dart format --output=none --set-exit-if-changed .`
- `dart analyze`
- `flutter analyze`
- `go test ./...`
- `go vet ./...`
- `node --check deckboard_daemon/frontend/app.js`

Static checks are quality signals. Existing warnings are recorded in the
baseline before being treated as new regressions.

### Unit tests

Unit tests will cover protocol parsing, configuration validation, authentication
state, rate limiting, action allowlists, URL validation, desktop-entry parsing,
icon-root validation, and platform capability reporting. Host commands must be
injected behind a fake executor; unit tests must not suspend, shut down, launch
applications, or modify the real desktop.

### Server integration tests

The Dart daemon will run on an ephemeral local port. WebSocket tests will cover
connection lifecycle, initial state, authentication, rejected unauthenticated
actions, accepted authenticated actions, configuration writes, malformed input,
oversized messages, disconnect cleanup, and multi-client broadcasts.

### Linux compatibility tests

Fixture desktop entries will represent Debian/APT, Flatpak, Snap, placeholders
such as `%U` and `%F`, duplicate entries, missing icons, and malformed entries.
The scanner must still discover valid applications after security hardening.

Icon tests will verify valid PNG/SVG/XPM files under approved system, Flatpak,
Snap, and user icon roots. Traversal, absolute paths outside approved roots,
non-icon extensions, and symlink escapes must be rejected. The feature remains
available; only arbitrary filesystem reads are removed.

Launch tests will assert that discovered applications become structured
executable-plus-arguments requests. Shell metacharacters must never be passed to
a shell. Flatpak and Snap launches must retain their supported command forms.

### Flutter tests

Widget and service tests will use fake WebSocket and system-action services.
They will cover onboarding, authentication, reconnecting/offline states, board
rendering, sliders, installed-app entries, icon fallback, capability-based UI,
and small/large layouts.

Physical Android UI testing follows the slow-device procedure in
[`android-device-testing.md`](android-device-testing.md). Text input must wait
for field focus, keyboard visibility, and the rendered value before the next
action; coordinate taps and fixed `adb shell input` sequences are not reliable
on older phones.

### End-to-end checks

On a controlled Linux machine, verify:

```text
Dart daemon -> web configurator
Dart daemon -> Android client
Dart daemon -> installed-app scanner
Dart daemon -> icon route
Dart daemon -> Linux actions
```

Destructive actions such as shutdown, logout, and suspend are never run against
the developer workstation during automated tests.

### TLS and Android forwarding smoke check

Run the portable offline smoke check from the repository root after Dart
dependencies are installed:

```bash
make tls-smoke
```

The check creates a one-day self-signed certificate and private key below a
runtime temporary directory, starts an isolated Dart daemon on an ephemeral
port, verifies a trusted WSS handshake and one-time pairing exchange, and then
removes all temporary material. If `adb` is installed and reports an authorized
device, it temporarily runs `adb reverse` for that ephemeral port and removes
the reverse rule during cleanup. Device identifiers, pairing codes, bearer
tokens, certificate paths, and command output are not written to the
repository. The Android application still requires a physical-device UI and
keystore pass; this smoke check only proves daemon transport/auth and forwarding
setup.

### Repository test command and environment failures

`make test` first checks that the pinned command-line tools (`dart`, `flutter`,
`node`, `go`, and `timeout`) are available. It does not install dependencies;
run the locked dependency setup from the README first. Each test subprocess is
bounded by `TEST_TIMEOUT` (180 seconds by default), and a timeout exits nonzero
with the original command visible rather than being treated as a pass or skip.
For a slower but still bounded environment, override it explicitly, for example
`TEST_TIMEOUT=300s make test`. An unavailable Android device is not a reason to
skip the daemon/client tests; the TLS smoke check reports its optional ADB
forwarding result separately.

## Regression gates

Every security step must demonstrate that:

1. Existing valid boards still load and save.
2. Installed applications still appear in the configurator.
3. Valid system icons still render on the phone and web UI.
4. Valid Linux audio, brightness, media, and KDE actions remain available.
5. Invalid or dangerous payloads are rejected with a visible error.
6. Windows and macOS placeholders remain isolated behind platform branches.
7. No new credentials or sensitive paths appear in logs or protocol state.

## Test environment policy

Tests should use temporary directories, ephemeral ports, fixture configs, and
fake command runners. A real Linux integration pass is required before a
security or platform adapter step is declared complete, but it must be an
explicitly controlled manual check.
