# KDE Deck development log

This is the durable record of scoped work on the `main` branch. Each step
records intent, decisions, files, verification, limitations, and the next
approved step so work can resume safely after a long pause.

## Step 1 — Architecture and testing baseline

### Goal

Record the current Dart-first architecture and establish a repeatable testing
baseline before changing security or UI behaviour.

### Scope

- Standalone Dart daemon
- Flutter Android/desktop client
- Web configurator
- Go tray wrapper
- WebSocket/configuration protocol
- Linux app discovery and system icon delivery
- Windows/macOS extension points

### Decisions

- Dart remains the official backend/control plane.
- Existing Linux app discovery and icon behaviour are compatibility requirements.
- Security hardening will restrict unsafe access, not remove valid application or
  icon functionality.
- The standalone and embedded Dart servers are documented separately until their
  shared core is designed.
- No application source was changed in this step.

### Documentation added

- `docs/architecture.md`
- `docs/protocol.md`
- `docs/decisions/ADR-001-dart-backend.md`
- `docs/testing.md`
- `docs/testing-baseline.md`

### Verification

- Dart backend tests: pass, but only the generated sample test exists.
- Dart backend compilation: pass.
- Go tests and vet: pass; no Go tests currently exist.
- Web frontend JavaScript syntax check: pass.
- Flutter widget test: fails because the test omits `WebSocketService`.
- Dart/Flutter analysis: existing diagnostics recorded in the baseline.

### Known limitations

The server has no authentication, transport encryption, request validation, or
safe command boundary. The icon endpoint accepts arbitrary existing filesystem
paths. These are intentionally documented here and are not fixed in the
baseline step.

### Next step

Design the threat model and authentication requirements, then add fixture-based
scanner/icon tests and fake command-executor seams before changing privileged
action behaviour.

## Step 2 — Security threat model and requirements

### Goal

Define the security boundary before implementation so authentication, command
execution, configuration validation, and filesystem protection are testable and
do not remove valid Linux app/icon functionality.

### Scope

- LAN, browser, WebSocket, and client trust boundaries
- Pairing, sessions, revocation, and rate limiting
- Action authorization and sensitive power/session actions
- Structured command execution and URL validation
- Shared configuration schema and recovery
- Installed-app discovery and system icon access
- Logging, privacy, and future Windows/macOS adapters

### Documentation added

- `docs/security/threat-model.md`
- `docs/security/security-requirements.md`

### Decisions

- A LAN is treated as untrusted until a client is paired and authorized.
- Authentication must happen before privileged state or commands are sent.
- Network-controlled values must never reach a shell.
- Valid Debian/Flatpak/Snap discovery and approved PNG/SVG/XPM icon roots are
  explicit P0 compatibility requirements.
- The standalone and embedded Dart servers must converge on shared policy rather
  than implementing separate weaker security checks.

### Verification

- Both security documents were written and re-read by the delegated agent.
- `git diff --check` passed.
- No application source was modified.

### Known limitations

The requirements are not implemented yet. The current server remains
unauthenticated and unsafe for LAN exposure. The next implementation step must
add fixture-based scanner/icon tests and a fake command-executor seam before
privileged command handling is changed.

### Next step

Implement the smallest testable security foundation: shared validation seams,
fixture tests for app discovery/icons, and authentication-state tests without
changing the user-facing board model unnecessarily.

## Step 3 — Discovery fixtures and command-execution seam

### Goal

Create testable boundaries for the two highest-risk Linux features before
implementing authentication: installed-app/icon discovery and host command
execution.

### Changes made

- Added `deckboard_daemon/backend/lib/app_discovery.dart` with a pure desktop
  entry parser and approved-root icon validator.
- Added fixture tests in
  `deckboard_daemon/backend/test/app_discovery_test.dart` for Debian, Flatpak,
  Snap, placeholders, malformed/duplicate entries, valid PNG/SVG/XPM icons,
  traversal, outside-root paths, symlink escapes, and unsupported extensions.
- Added `deckboard_daemon/backend/lib/command_executor.dart` with an injectable
  argv-based executor and production adapter.
- Updated `system_actions_service.dart` to route process calls through the
  executor seam, validate HTTP(S) URLs, avoid shell execution for URLs, and
  allow only fixed KDE action mappings.
- Added focused command tests in
  `deckboard_daemon/backend/test/system_actions_service_test.dart`.

### Features preserved

- Existing Linux process names and argument forms remain available through the
  production executor.
- App discovery fixtures retain Debian/Flatpak/Snap semantics.
- Approved PNG/SVG/XPM icons remain resolvable.
- Windows/macOS branches remain explicit and unchanged as future extension
  points.

### Verification

- `dart test`: **PASS**, 15 tests.
- `dart analyze` on changed backend files: no errors; 9 existing style/info
  diagnostics remain in `system_actions_service.dart`.
- `dart format --output=none --set-exit-if-changed ...`: **PASS**.
- `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-step3`: **PASS**.
- `git diff --check`: **PASS**.

### Known limitations

- The new discovery helper is not wired into the existing scanner yet; the
  current scanner still needs an integration step using these helpers.
- Non-URL application launches still preserve the legacy shell-based desktop
  entry payload path for compatibility. This is deliberately not declared
  secure yet and must be replaced with structured executable/argv handling in
  the next command-hardening step.
- Authentication and authorization remain unimplemented.

### Next step

Wire the discovery helper into the standalone daemon without changing valid
app/icon results, then replace legacy application launch payloads with safe
structured argv records and add server-level authentication tests.

## Step 4 — Integrate safe discovery and icon serving

### Goal

Use the new discovery and icon validation helpers in the live standalone Dart
daemon without changing the existing client-facing app/icon result shape.

### Changes made

- `system_actions_service.dart` now parses `.desktop` files through
  `DesktopEntryParser`.
- Linux icon roots are centralized for reuse by discovery and HTTP serving.
- `dart_server_service.dart` now resolves `/system_icons` requests through
  `IconPathValidator` before reading any file.
- Valid PNG/SVG/XPM icons remain supported; traversal, outside-root absolute
  paths, and symlink escapes are rejected.

### Verification

- `dart test`: **PASS**, 15 tests.
- `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-step4`: **PASS**.
- `git diff --check`: **PASS**.

### Known limitations

- Snap-specific icon directories are not yet included in the live icon index;
  the existing placeholder behavior remains unchanged.
- Regular app launches still use the legacy shell-based payload path and are
  not yet secure.
- Authentication and authorization remain unimplemented.

### Next step

Replace the legacy application launch payload with structured executable/argv
data while preserving Debian, Flatpak, and Snap launches. Add live-server tests
for authorized icon serving before implementing broader authentication.

## Step 5 — Structured application launches

### Goal

Remove shell execution from regular application launches while retaining the
existing `payload` field used by current clients and preserving Linux app,
Flatpak, and Snap launch behaviour.

### Changes made

- Added `LaunchCommand` and a strict quoted-argv parser to
  `deckboard_daemon/backend/lib/app_discovery.dart`.
- The parser strips desktop-entry field codes safely and rejects shell
  operators, substitutions, control characters, empty commands, and malformed
  quoting.
- `system_actions_service.dart` now launches applications through
  `CommandExecutor.run(executable, arguments)` rather than `sh -c`, `cmd /c`,
  or another shell fallback.
- Discovery responses retain the legacy `payload` and now also include
  structured `executable` and `arguments` fields when parsing succeeds.
- Explicit `flatpak run ...` and `snap run ...` payloads remain supported.
- URL launching remains restricted to HTTP(S) and continues to pass the URL as
  one argument.

### Verification

- `dart test`: **PASS**, 20 tests.
- Focused changed-file `dart analyze`: **PASS**, no issues.
- `dart format --output=none --set-exit-if-changed ...`: **PASS**.
- `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-step5`: **PASS**.
- `git diff --check`: **PASS**.

The normal `dart` command through `/snap/bin/dart` was unavailable during one
check because the host snap confinement lacked `cap_dac_override`; the same
checks were rerun successfully with the Flutter-bundled Dart SDK at
`/home/kaily/snap/flutter/common/flutter/bin/cache/dart-sdk/bin/dart`.

### Features preserved

- Existing clients can continue sending legacy `payload` strings.
- Valid simple commands, quoted arguments, Flatpak, and Snap launch forms still
  produce argv calls.
- Windows/macOS branches remain explicit and do not add shell fallbacks.

### Known limitations

- Any authenticated caller that can submit a syntactically valid executable
  name can still request that executable; capability authorization and a
  discovered-application allowlist belong to the authentication/authorization
  phase.
- The web and Flutter clients do not yet consume the new structured fields.
- Authentication and authorization remain unimplemented.

### Next step

Add standalone-server authentication state and protocol tests, beginning with
rejecting unauthenticated actions/configuration while allowing the public client
to complete pairing.

## Step 6 — Authentication/session state core

### Goal

Introduce a reusable authentication state component before wiring authentication
into either Dart server or changing the mobile/web clients.

### Changes made

- Added `deckboard_daemon/backend/lib/auth_session_manager.dart`.
- Added `deckboard_daemon/backend/test/auth_session_manager_test.dart`.
- Added one-time pairing code generation/expiry and successful-pair consumption.
- Added high-entropy in-memory bearer sessions with expiry and revocation.
- Added `viewer`, `control`, and `configAdmin` roles with explicit capabilities.
- Added constant-time pairing-code comparison.
- Redacted pairing codes and tokens from diagnostic `toString()` output.

### Verification

- Full backend `dart test`: **PASS**, 29 tests.
- Focused `dart analyze` for the new manager/tests: **PASS**, no issues.
- Focused `dart format --output=none --set-exit-if-changed ...`: **PASS**.
- `git diff --check`: **PASS**.

### Known limitations

- This component is currently in-memory and is not wired into the server.
- Pairing-code display, secure client storage, TLS, rate limiting, persistence,
  and client authentication messages remain future steps.
- The current server still sends state immediately and accepts actions without
  authorization; this step deliberately does not change that behaviour yet.

### Next step

Wire this manager into the standalone server's WebSocket lifecycle: send only a
minimal authentication challenge before pairing, reject unauthenticated action,
configuration, and discovery messages, and add protocol tests without exposing
the PIN or pairing secret.

## Step 7 — Standalone server authentication wiring

### Goal

Wire the in-memory auth/session manager into the standalone Dart WebSocket
server without changing the Flutter client/server or existing discovery/icon
behavior.

### Changes made

- Each standalone WebSocket now starts unauthenticated and receives only an
  `auth_required` challenge.
- Pairing accepts the one-time `pairing_code`; reconnect accepts an existing
  bearer `token`. Successful authentication sends `auth_success` and then the
  existing `init_state`.
- Bootstrap pairing is assigned `configAdmin` in this first server slice for
  compatibility. Caller-supplied roles are ignored and cannot elevate a
  session.
- `trigger_action` requires `control`; `save_config` and `get_system_apps`
  require `configAdmin`. Rejected requests return bounded `auth_error` messages
  and do not reach command execution, persistence, or discovery.
- Background state broadcasts now target authenticated sockets only. Per-socket
  auth associations are removed on disconnect while bearer sessions remain
  available for reconnect until expiry/revocation.
- Added `DartServerService.forTesting` for an ephemeral loopback server with
  injected auth state, config path, and fake `CommandExecutor`.
- Added `test/dart_server_auth_test.dart` covering challenge/rejection,
  pairing, token reconnect, and role gates.

### Documentation updated

- `docs/protocol.md` now defines the standalone authentication lifecycle,
  messages, capabilities, and bootstrap limitation.

### Verification

- Focused `dart test test/dart_server_auth_test.dart`: **PASS**, 4 tests.
- Full backend `dart test`: **PASS**, 33 tests.
- Focused changed-file `dart analyze`: **PASS**, info-level style diagnostics
  only; no warnings or errors.
- `dart format --output=none --set-exit-if-changed` on changed Dart files:
  **PASS**.
- `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-step7`:
  **PASS**.
- The host `/snap/bin/dart` command remains unavailable because snap
  confinement lacks `cap_dac_override`; all checks above used the Flutter-bundled
  Dart SDK at `/home/kaily/snap/flutter/common/flutter/bin/cache/dart-sdk/bin`.

- The legacy `pin_required` field is now `true` after successful standalone
  authentication, and configuration broadcasts are limited to authenticated
  clients with the `configAdmin` capability.

### Known limitations

- Bootstrap pairing is intentionally always `configAdmin`; there is no remote
  role-provisioning workflow yet.
- Authentication is in-memory and bearer tokens are not persisted across a
  daemon restart. TLS, rate limiting, and secure client credential storage
  remain future work.

### Next step

Update the standalone/web client flows to authenticate before requesting state,
then converge the embedded server on the same authorization policy when client
compatibility work is approved.
