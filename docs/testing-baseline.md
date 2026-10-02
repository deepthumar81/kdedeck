# KDE Deck baseline verification

Date: 2026-10-01  
Branch: `main`  
Commit: `7e939f7`  
Scope: documentation and baseline checks only; no application source changed.

## Results

| Area | Command | Result |
|---|---|---|
| Dart backend tests | `cd deckboard_daemon/backend && dart test` | PASS: 1 generated sample test |
| Dart backend analysis | `cd deckboard_daemon/backend && dart analyze` | FAIL gate: 20 warnings/info diagnostics |
| Dart backend build | `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-baseline` | PASS as part of baseline command sequence |
| Go tray tests | `cd deckboard_daemon/tray && go test ./...` | PASS: no test files |
| Go tray vet | `cd deckboard_daemon/tray && go vet ./...` | PASS |
| Flutter dependencies | `cd kdedeck_mobile && flutter test` | Dependencies resolved; 21 compatible updates available |
| Flutter widget tests | `cd kdedeck_mobile && flutter test` | FAIL: `ProviderNotFoundException` for `WebSocketService` |
| Flutter analysis | `cd kdedeck_mobile && flutter analyze` | FAIL gate: 96 diagnostics, primarily deprecations and lint warnings |
| Web JavaScript syntax | `node --check deckboard_daemon/frontend/app.js` | PASS |

The backend test currently verifies only the generated `calculate()` sample;
there are no protocol, scanner, icon, authentication, or integration tests yet.

## Known baseline defects

- Both Dart servers report `pin_required: false` and accept actions without
  authentication.
- The standalone icon route accepts a caller-provided filesystem path.
- Launch and KDE action handling still contains shell-based execution paths.
- The Flutter smoke test does not provide the required `WebSocketService`.
- Standalone and embedded servers have different routes, persistence, and
  validation behaviour.
- Flutter and Dart analysis have existing warnings that should be separated from
  new regressions in later steps.

## Feature-preservation baseline

The current architecture documentation records the Linux features that must be
regression-tested: Debian/Flatpak/Snap app discovery, system icon lookup and
delivery, audio, brightness, MPRIS, KDE actions, metrics, and board persistence.
The next test implementation should add fixtures and fake executors before
authentication or command hardening changes are made.
