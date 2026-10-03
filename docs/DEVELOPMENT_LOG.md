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

## Step 8 — Standalone web configurator authentication client

### Goal

Authenticate the standalone web configurator before it requests privileged state
or performs configuration work, while preserving the existing board editor,
installed-app discovery, icon rendering, and auto-save behavior.

### Changes made

- Added a small pairing-code modal to the standalone web configurator.
- The client waits for `auth_required`, accepts a user-entered pairing code, and
  processes `init_state` only after `auth_success`.
- Successful bearer tokens are stored under `kdedeck.authToken` in browser
  `sessionStorage` and `localStorage`; reconnects retry with the saved token.
- Invalid credentials clear the saved token and return the UI to the pairing
  prompt without displaying or logging the credential.
- Installed-app discovery and `save_config` are gated on authenticated state.
- Updated `docs/protocol.md` with the web client lifecycle and storage key.

### Files changed

- `deckboard_daemon/frontend/app.js`
- `deckboard_daemon/frontend/index.html`
- `deckboard_daemon/frontend/style.css`
- `docs/protocol.md`

### Verification

- `node --check deckboard_daemon/frontend/app.js`: **PASS**.
- `git diff --check`: **PASS**.
- No Flutter or backend source was modified.

### Known limitations

- Browser storage remains client-side bearer-token storage; transport security
  and server-side token persistence are outside this bounded client step.

### Next step

Manually exercise pairing, token reconnect, invalid-token recovery, and editor
auto-save against a running standalone daemon before changing the embedded
Flutter client flow.

## Step 9 — Standalone authentication attempt rate limiting

### Goal

Bound repeated failed authentication attempts in the standalone Dart daemon
without changing the Flutter client, web client, or authenticated action flow.

### Changes made

- Added `auth_rate_limiter.dart`, an in-memory limiter keyed by the WebSocket
  upgrade's remote address.
- Added injectable failure limits, lockout duration, clock, and client identity
  resolver seams for deterministic tests.
- Failed unauthenticated attempts count toward the limit; successful pairing or
  token authentication clears the identity's failure state.
- Rate-limited attempts return only the bounded `rate_limited` auth error. No
  credentials or raw request payloads are logged or echoed.
- Existing authenticated sockets and their normal action/configuration paths do
  not consult the limiter.
- Added focused limiter tests and live-server integration coverage for the
  threshold, expiry, success reset, and no-auth-bypass behavior.

### Verification

- Focused limiter/server auth tests: **PASS**, 8 tests.
- Full backend `dart test`: **PASS**, 37 tests.
- Changed-file `dart analyze`: **PASS**, 8 existing info-level style diagnostics
  only; no warnings or errors.
- `dart format --output=none --set-exit-if-changed` on changed Dart files:
  **PASS**.
- `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-rate-limit`:
  **PASS**.
- `git diff --check`: **PASS**.

### Known limitations

The limiter is in-memory and resets when the standalone daemon restarts. TLS,
distributed state, and account-level identity remain outside this standalone
server slice.

### Next step

Manually exercise pairing and token reconnect from supported clients against a
running daemon before changing the embedded Flutter client flow.

## Step 10 — Strict standalone configuration validation and recovery

### Goal

Validate standalone configuration before it can change active state or reach
disk, while preserving checked-in boards, slider layouts, safe actions,
installed-app payloads, and icon fields.

### Changes made

- Added the pure, injectable `ConfigValidator` and `ConfigLimits` in
  `deckboard_daemon/backend/lib/config_validator.dart`.
- Added bounded validation for maps/lists, IDs, board/item counts, grid values,
  action allowlists and payloads, finite numbers, titles, payloads, icon data,
  base64 data URLs, system icon paths, nesting, and serialized size. Validation
  returns a defensive copy and never exposes the submitted config in errors.
- Standalone `save_config` now validates before changing `configData`, writes a
  flushed temporary file, atomically replaces the primary, and retains the
  previous valid file as `.bak`. Invalid saves return a bounded `config_error`.
- Startup validates the primary, falls back to a valid `.bak`, and otherwise
  uses the safe default. Partial or corrupt configs are never applied.
- Added pure-validator fixtures and live-server tests for valid checked-in
  config, rejection classes, unchanged invalid saves, atomic backup creation,
  and corrupt-primary recovery.

### Documentation updated

- `docs/protocol.md` documents the strict schema, bounded error, and recovery
  behavior.

### Verification

- Full backend `dart test`: **PASS**, 48 tests.
- Changed-file `dart analyze`: **PASS**, no errors; 7 existing info-level style
  diagnostics remain in `dart_server_service.dart`.
- `dart format --output=none --set-exit-if-changed` on changed Dart files:
  **PASS**.
- `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-config-validation`:
  **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

No Flutter/web client, platform action, authentication/rate-limiting, or app/icon
discovery code was changed.

## Step 11 — Bounded in-memory authentication sessions

### Goal

Bound the standalone backend's in-memory bearer-session state and provide safe
administrative revocation without changing clients or transport behavior.

### Changes made

- Added injectable `maxActiveSessions` with a safe default of 100.
- Removed expired sessions opportunistically and before issuing a new session.
- Added the bounded `AuthAuthenticationResult` status path for invalid pairing
  and capacity rejection while preserving the existing nullable `authenticate`
  API for server callers.
- Added revoke-all and exact-role (or more-privileged-role) operations that
  return counts and never expose tokens.
- Added tests for expiry cleanup before capacity checks, capacity rejection and
  pairing-code retention, role-selective revocation, active-session
  preservation, and diagnostic redaction.

### Verification

- Full backend `dart test`: **PASS**, 50 tests.
- Changed-file `dart analyze`: **PASS**, no issues.
- `dart format --output=none --set-exit-if-changed` on changed Dart files:
  **PASS**.
- `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-bounded-sessions-final`:
  **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

No Flutter/web client, configuration validation, platform action, app/icon
discovery, or transport/TLS code was changed. Capacity-specific server protocol
wiring was completed in Step 12; current server behavior remains bounded and
credential-neutral.

## Step 12 — Bounded WebSocket session-capacity authentication error

### Goal

Expose the existing bounded session-manager capacity result through the
standalone WebSocket protocol without changing clients or authentication policy.

### Changes made

- Pairing now uses `authenticateWithStatus` so an active-session capacity
  rejection returns only `{ "type": "auth_error", "code": "session_capacity" }`.
- Invalid pairing codes and bearer tokens remain `invalid_credentials`; failed
  attempts continue through the existing rate limiter unchanged.
- Capacity rejection does not consume the pairing code. After a manager-seam
  revocation, the retained code can pair successfully.
- Added live-server integration coverage for full capacity, error redaction,
  pairing-code retention, revocation, and retry success.
- Updated `docs/protocol.md` with the new bounded authentication error.

### Verification

- Full backend `dart test`: **PASS**, 51 tests.
- Changed-file `dart analyze`: **PASS**, no errors; 7 existing info-level style
  diagnostics remain in `dart_server_service.dart`.
- `dart format --output=none --set-exit-if-changed` on changed Dart files:
  **PASS**.
- `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-session-capacity`:
  **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

No Flutter/web client, TLS, configuration validation, platform action, or
app/icon discovery code was changed.

## Step 13 — Explicit standalone bind mode

### Goal

Make standalone daemon network exposure loopback-safe by default while retaining
an explicit LAN opt-in for phone users, without changing the WebSocket protocol
or Flutter/desktop clients.

### Changes made

- Production startup now binds `127.0.0.1` when no bind setting is present.
- Added the top-level `allow_lan` boolean opt-in; only `true` selects
  `anyIPv4`/LAN binding. Invalid values fail closed to loopback, and arbitrary
  remote bind addresses are ignored.
- Preserved the injectable `forTesting` bind address and ephemeral-port test
  seam. Startup logs report loopback versus LAN mode without config contents or
  credentials.
- Added focused tests for default loopback, LAN opt-in, invalid-setting
  fallback, config preservation, and injected test-address precedence.
- Updated `docs/protocol.md` with the setting, restart behavior, and phone-user
  migration note. TLS remains out of scope.

### Verification

- Focused bind/config tests: **PASS**, 8 tests.
- Full backend `dart test`: **PASS**, 56 tests.
- Changed-file `dart analyze`: **PASS**, no errors; 7 existing info-level style
  diagnostics remain in `dart_server_service.dart`.
- `dart format --output=none --set-exit-if-changed` on changed Dart files:
  **PASS**.
- `dart compile exe bin/backend.dart -o /tmp/kdedeck-daemon-bind-mode`:
  **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

No Flutter/web client, platform action, config-validator, auth, or app/icon
discovery code was changed.

## Step 14 — Standalone HTTPS/WSS and TLS-required LAN

Date: 2026-10-03. This step preserves all previous uncommitted work on main.

### Goal and changes

- Added `deckboard_daemon/backend/lib/server_tls.dart` for local environment-only
  certificate loading. Board config does not carry TLS credentials or paths.
- Updated `dart_server_service.dart` to use `HttpServer.bindSecure` when TLS is
  configured and require TLS on every non-loopback bind.
- Missing, partial, invalid, or mismatched credentials refuse startup without
  opening a listener or silently falling back to plaintext.
- Loopback HTTP/WS remains available only when no TLS settings are supplied.
- Startup reports transport type; errors omit certificate paths/key contents.
- Added `test/dart_server_tls_test.dart`; updated bind tests in
  `test/dart_server_config_test.dart` to expect LAN startup refusal without TLS.
- Updated `docs/protocol.md` and added `docs/security/tls-setup.md`.

### Verification

From `deckboard_daemon/backend`, using the existing Flutter-bundled Dart SDK:

- `dart test -r compact`: **63 tests passed**.
- `dart analyze lib/server_tls.dart lib/dart_server_service.dart
  test/dart_server_tls_test.dart test/dart_server_config_test.dart`: no errors or
  warnings; seven existing informational style diagnostics remain.
- Format check for those four files: passed, zero files changed.
- `dart compile exe bin/backend.dart -o /tmp/opencode/kdedeck-tls-verified`: passed.
- Tests cover trusted HTTPS/WSS auth, untrusted certificate rejection, plaintext
  refusal, loopback compatibility, invalid/missing/partial/mismatched credentials,
  and valid encrypted LAN binding. Temporary test keys are deleted, never committed.

### Remaining required work

TLS listener implementation is complete, but secure device onboarding is not.
Certificate provisioning/trust, Flutter WSS, certificate expiry/rotation handling,
and physical LAN end-to-end verification remain mandatory tasks (see TLS setup).
Existing pairing codes are still not exposed through a local provisioning UI;
existing clients therefore cannot yet complete a normal production pairing flow.
The embedded Flutter server is unchanged and is not secured by this step.

### Next bounded step

Provide an explicit local-only pairing-code issuance/display mechanism, without
logging secrets or exposing them through unauthenticated network endpoints. Then
integrate Flutter authentication/WSS and verify app/icon compatibility on devices.

## Step 15 — Explicit local terminal pairing

### Goal and changes

- Added `lib/local_pairing_console.dart` and `test/local_pairing_console_test.dart`
  under `deckboard_daemon/backend`.
- Updated `bin/backend.dart` with `--pair` and same-terminal `pair` command.
- Both input and output must be real terminals; refused redirected/piped requests
  exit before startup with status 2. Invalid arguments and startup failures also
  exit instead of hanging.
- Added server-local `issueLocalPairingCode()`; stopped servers reject issuance.
- Production and default test servers create no code until local issuance;
  `AuthSessionManager` keeps optional eager issuance for existing explicit users.
- Rotation invalidates old codes, preserves current tokens, and returns expiry
  information only to the local display. No new network endpoint was added.
- SIGTERM handling is skipped on Windows rather than assuming Unix signals.
- Updated `docs/protocol.md`; pending limitations are indexed in
  `docs/PENDING_WORK.md` and are required follow-up work, not optional exclusions.

### Verification

From `deckboard_daemon/backend` using the bundled Dart SDK:

- `dart test -r compact`: **71 tests passed**.
- Focused analysis of entry point, console, manager, server, and tests: no errors
  or warnings; 11 informational style diagnostics.
- Formatting check of those six files: passed, no changes.
- `dart compile exe bin/backend.dart -o /tmp/opencode/kdedeck-local-pair-verified`:
  passed.
- Compiled `--pair` with redirected stdin/stdout: exit 2, empty stdout, only the
  bounded terminal-required error. No server started or secret generated.
- Tests use captured dummy codes; they verify refusal, rotation, expiry hint,
  existing-token preservation, and successful WebSocket pairing with no challenge
  secret disclosure. Real interactive TTY/device testing was not performed.

### Next step

Close active-session expiry/revocation broadcast leakage with protocol regression
tests, then implement the Flutter auth/WSS client. Terminal pairing is available
now; background/tray pairing remains required work.

## Step 16 — Revalidate broadcast sessions

- Small scope: `_broadcast` now revalidates each token's expiry/revocation before
  sending, rather than trusting the cached socket association.
- Added two protocol regression tests (revoked and expired admin sessions). A
  valid admin still receives the config broadcast; the old socket receives no
  config and its subsequent privileged request is denied, with no executor calls.
- Full `dart test -r compact`: **73 tests passed**. Changed files formatted.
- Changed: `deckboard_daemon/backend/lib/dart_server_service.dart` and
  `deckboard_daemon/backend/test/dart_server_auth_test.dart`.
- Async requester-response revalidation and immediate socket closure remain
  required follow-ups; this slice fixes broadcasts only. No commit/push.

## Step 17 — Delayed app-discovery authorization

- `_sendSystemApps` now rechecks connection membership, current session validity,
  and configAdmin capability after awaiting discovery and before sending results.
- Added deterministic delayed-discovery tests using a paused fake Snap command
  (Linux adapter): revoke or expire the session during discovery; only a bounded
  authentication error is delivered, not app inventory. Existing valid discovery
  tests remain unchanged.
- Changed: `deckboard_daemon/backend/lib/dart_server_service.dart` and
  `deckboard_daemon/backend/test/dart_server_auth_test.dart`.
- Full `dart test -r compact`: **75 tests passed**; changed files formatted.
- Immediate revoked-socket closure and real-device tests remain required. No
  commit or push. This step adds no UI or protocol changes for valid users.

## Step 18 — Prompt revoked-session closure

- Added token-free in-process revocation listeners for single, role-selective,
  and all-session revocation in `auth_session_manager.dart`.
- Standalone server immediately clears invalid socket authorization and closes
  affected connections with code 1008 and generic `Session invalid` reason.
  Listener registration is tied to start/stop; valid survivor sessions stay open.
- Updated auth manager/server tests, including revoked broadcast/discovery tests
  to expect closure with no state disclosure; expiry denial behavior remains.
- Agent ran full `dart test`: **80 passed**; focused analysis: no errors,
  nine informational lints; format and `git diff --check` passed.
- No UI changes, expiry timer, public revocation endpoint, commit or push.
  Administrative UI/local revocation controls remain required follow-ups.
