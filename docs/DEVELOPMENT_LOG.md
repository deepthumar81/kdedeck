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

## Step 19 — Bounded authentication identity state

### Goal and changes

- Added an injectable `maxTrackedIdentities` limit to `AuthRateLimiter`, with a
  safe default of 1024 identities.
- Unlocked failure state expires after one lockout duration of inactivity and
  expired or stale entries are removed opportunistically on limiter access.
- At capacity, the limiter evicts only the oldest unlocked identity. If all
  retained identities are actively locked, new identities fail closed until a
  lockout expires; active locked identities are never evicted.
- Existing per-peer failure counting, successful-authentication reset, and
  credential/payload redaction behavior remain unchanged.
- Added deterministic focused tests for stale cleanup, identity capacity,
  active-lockout preservation, and metadata-only state.

### Changed files

- `deckboard_daemon/backend/lib/auth_rate_limiter.dart`
- `deckboard_daemon/backend/test/auth_rate_limiter_test.dart`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- Focused limiter test `dart test test/auth_rate_limiter_test.dart`: **PASS**, 7
  tests.
- Full backend `dart test -r compact`: **PASS**, 84 tests.
- Changed-file `dart analyze lib/auth_rate_limiter.dart
  test/auth_rate_limiter_test.dart`: **PASS**, no issues found.
- `dart format --output=none --set-exit-if-changed` on the two changed Dart
  files: **PASS**, no files changed.
- `dart compile exe bin/backend.dart -o
  /tmp/opencode/kdedeck-auth-rate-limiter-verified`: **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

Global connection/action/request limits and the embedded Flutter server remain
required follow-up work.

## Step 20 — Bounded standalone WebSocket traffic

### Goal and changes

- Added injectable, fixed-window per-client WebSocket limits with safe defaults:
  simultaneous sockets, message frames, action requests, and repeated-violation
  close threshold.
- Socket capacity is reserved before WebSocket upgrade completion and rejected
  sockets receive only a bounded policy close before authentication state is
  created. Pending reservations prevent concurrent handshakes from bypassing
  the cap.
- Message frames are limited before JSON dispatch. `trigger_action` frames have
  a separate action-request limit, including for unauthenticated sockets, so
  auth gates cannot be bypassed by flooding action requests.
- Authenticated and unauthenticated violators receive only the bounded
  `rate_limited` protocol error; repeated violations close the socket with a
  fixed policy reason. No payloads, credentials, or raw frames are logged.
- Per-socket counters are removed on disconnect and all limiter state is reset
  on server stop/restart. Injected clocks and limits make boundary behavior
  deterministic in tests.

### Changed files

- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/lib/websocket_rate_limiter.dart`
- `deckboard_daemon/backend/test/dart_server_auth_test.dart`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- Focused auth/server test `dart test test/dart_server_auth_test.dart -r
  compact`: **PASS**, 20 tests.
- Full backend `dart test -r compact`: **PASS**, 90 tests.
- Changed-file `dart analyze lib/auth_rate_limiter.dart
  lib/dart_server_service.dart lib/websocket_rate_limiter.dart
  test/auth_rate_limiter_test.dart test/dart_server_auth_test.dart`: **PASS**;
  no errors, with nine existing informational lint diagnostics in the server
  and auth test files.
- `dart format --output=none --set-exit-if-changed` on all changed Dart files:
  **PASS**, no files changed.
- `dart compile exe bin/backend.dart -o
  /tmp/opencode/kdedeck-websocket-limits-verified`: **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

This slice changes only the standalone Dart WebSocket server and tests. TLS,
Flutter/UI behavior, config validation, and app discovery implementation were
not changed.

## Step 21 — Bounded WebSocket frame decoding

### Goal and changes

- Added an injectable standalone-server maximum WebSocket text-frame size of 64
  KiB by default.
- Frame size is measured from UTF-8 bytes and checked before `jsonDecode` or
  protocol dispatch. Binary frames are rejected rather than coerced to text.
- Oversized and binary frames receive only the bounded `message_too_large`
  protocol error; the frame contents are never echoed or logged.
- Repeated frame-size violations close only the offending socket with a policy
  violation code and fixed, bounded reason. Per-socket violation counters and
  close state are removed on disconnect and server stop.
- Added deterministic boundary, unauthenticated/authenticated rejection,
  binary-frame, repeated-close, and surviving-socket tests. Existing auth,
  action, config, and discovery flows remain unchanged for accepted frames.

### Changed files

- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/test/dart_server_auth_test.dart`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- Focused frame/auth tests `dart test test/dart_server_auth_test.dart -r
  compact --name '^((accepts a text|rejects an oversized|rejects binary|closes
  after repeated oversized|an oversized client).*)'`: **PASS**, 6 tests.
- Full backend `dart test -r compact`: **PASS**, 96 tests.
- Full backend `dart analyze`: **PASS**, no errors; 13 existing informational
  diagnostics remain.
- `dart format --output=none --set-exit-if-changed lib test`: **PASS**, no files
  changed.
- `dart compile exe bin/backend.dart -o
  /tmp/opencode/kdedeck-frame-limits-verified`: **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

This slice changes only standalone Dart WebSocket frame handling and focused
tests/docs. It does not change HTTP/TLS handling, config validation, discovery,
Flutter/UI behavior, or the embedded Flutter server.

## Step 22 — Standalone static frontend path containment

### Goal and changes

- Added a testable frontend-root seam to `DartServerService`; the production
  default remains `../frontend`.
- The frontend root is canonicalized once per server start and must resolve to a
  directory before static serving is enabled.
- Static requests canonicalize the requested file, require it to remain beneath
  the canonical root, and require a regular file. Missing files, traversal,
  encoded traversal, absolute-looking paths, malformed paths, and symlink
  escapes return only `404 Not Found`.
- Preserved `/` as the `index.html` route and retained HTML, CSS, JavaScript,
  JSON, image, and common font asset content types. `/system_icons` continues to
  use its separate approved-root validator.
- Static filesystem failures are not logged or exposed in HTTP responses.

### Changed files

- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/test/dart_server_static_test.dart`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- Focused static-server integration tests: **PASS**, 5 tests.
- Full backend `dart test -r compact`: **PASS**, 101 tests.
- Full backend `dart analyze`: **PASS**, no errors; existing informational
  diagnostics remain in the server, pairing-console, and auth tests.
- `dart format --output=none --set-exit-if-changed` on changed Dart files:
  **PASS**.
- `dart compile exe bin/backend.dart -o
  /tmp/opencode/kdedeck-static-containment-verified`: **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

This slice changes only standalone static frontend serving and its focused tests.
HTTP request limits, origin policy, frontend XSS-safe rendering, TLS, Flutter/UI
behavior, configuration, and `/system_icons` authorization remain outside scope.

## Step 23 — Standalone HTTP response security policy

### Goal and changes

- Applied `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
  `Referrer-Policy: no-referrer`, and a restrictive Content Security Policy to
  every standalone HTTP response before route handling, including missing and
  error responses and the WebSocket upgrade path.
- The CSP allows only same-origin resources plus the two exact Google Fonts
  origins used by the current frontend. It retains narrowly scoped
  `unsafe-inline` allowances because the existing frontend contains inline
  scripts and style attributes; replacing those with nonces/external styles is
  a separate frontend hardening task.
- Set `Cache-Control: no-store` on all standalone HTTP responses. Frontend
  assets are not content-addressed, and `/system_icons` is deliberately not
  permissively cached; a future fingerprinted asset pipeline can introduce a
  bounded public cache policy safely.
- Added focused assertions for the root HTML, a valid static asset, missing
  paths, and an icon error response. No CORS headers were added.

### Changed files

- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/test/dart_server_static_test.dart`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- Focused static-server tests `dart test test/dart_server_static_test.dart -r
  compact`: **PASS**, 5 tests.
- Full backend `dart test -r compact`: **PASS**, 101 tests.
- Full backend `dart analyze`: **PASS**, no errors; 14 existing informational
  diagnostics remain in the server, pairing-console, and auth test files.
- `dart format --output=none --set-exit-if-changed lib test`: **PASS**, no files
  changed.
- `dart compile exe bin/backend.dart -o
  /tmp/opencode/kdedeck-http-policy-verified`: **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

This slice changes only standalone HTTP response headers/cache policy and its
focused tests/docs. It does not change frontend/UI files, TLS, authentication,
WebSocket protocol behavior, CORS, or config handling.

## Step 24 — Standalone WebSocket Origin validation

### Goal and changes

- Validated a supplied WebSocket `Origin` before capacity checks, client
  identity resolution, or WebSocket upgrade.
- Accepted only `http`/`https` origins whose normalized scheme, host, and
  effective port match the request's transport and `Host` header, including
  default ports 80 and 443.
- Rejected malformed and cross-origin browser upgrades with HTTP 403 and a
  bounded response. Origin-less upgrades remain accepted for native/mobile
  clients.
- Kept static GET and system-icon routes unchanged and added an integration
  assertion that same-origin static GETs remain served.

### Changed files

- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/test/dart_server_auth_test.dart`
- `deckboard_daemon/backend/test/dart_server_static_test.dart`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- Focused auth/static Origin integration tests `dart test
  test/dart_server_auth_test.dart test/dart_server_static_test.dart -r compact`:
  **PASS**, 35 tests.
- Full backend `dart test -r compact`: **PASS**, 105 tests.
- Full backend `dart analyze`: **PASS**, no errors; 14 existing informational
  diagnostics remain.
- `dart format --output=none --set-exit-if-changed lib test`: **PASS**, no files
  changed.
- `dart compile exe bin/backend.dart -o
  /tmp/opencode/kdedeck-origin-verified`: **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

This slice changes only standalone WebSocket upgrade Origin validation and its
focused tests/docs. It does not add CORS or change TLS, authentication,
configuration, actions, icon behavior, or frontend/UI files.

## Step 25 — Frontend text-safe rendering

### Goal and changes

- Replaced user-controlled `innerHTML` interpolation in the standalone frontend
  with DOM construction and `textContent` for board titles, item titles and
  labels, material icon names, installed-app names/payloads, and imported
  configuration values.
- Replaced dynamic image and icon markup with element property/style updates;
  static layout classes and existing visual styling remain unchanged.
- Removed all `innerHTML` use from `deckboard_daemon/frontend/app.js`, including
  the static save/add icon fragments and container clearing.

### Changed files

- `deckboard_daemon/frontend/app.js`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- `node --check deckboard_daemon/frontend/app.js`: **PASS**.
- `grep` audit confirms no `innerHTML`, `outerHTML`, or
  `insertAdjacentHTML` use remains in `app.js`.
- `git diff --check`: **PASS**.

### Manual cases to verify in a browser

- A board title containing `<img src=x onerror=alert(1)>` displays as literal
  text in the sidebar and delete confirmation.
- An item title/icon containing HTML-like text displays as literal text on the
  tile and remains literal after reopening the editor.
- Installed app names and payloads containing HTML-like text remain literal in
  the search dropdown.
- Imported custom image data and system icon paths still render through the
  existing image endpoints without changing the surrounding tile layout.

### Scope boundary

This slice changes only standalone frontend rendering. HTTP limits, image/SVG
content authorization, backend/Flutter/TLS/auth behavior, and browser end-to-end
coverage remain separate work.

## Step 26 — Bounded standalone HTTP requests

### Goal and changes

- Added injectable standalone-server limits for request-target bytes, normalized
  request-header bytes, header-field count, and HTTP body bytes. Safe defaults
  are 8 KiB, 32 KiB, 100 fields, and 1 MiB respectively.
- Envelope checks run before static, icon, or WebSocket route handling. Oversized
  targets, headers, and bodies return only a bounded `413 Payload Too Large`;
  malformed application-visible targets return only `400 Bad Request`.
- Known oversized bodies are rejected from their declared `Content-Length`
  without draining the body. Chunked/unknown bodies are consumed only until the
  configured limit is crossed, then the connection is closed after the bounded
  response. Accepted bodies are fully consumed before existing route handling.
- HTTP upgrade requests are not consumed by the body gate, allowing
  `WebSocketTransformer.upgrade` and the existing WebSocket frame limits to
  remain unchanged. Valid static, icon, and WebSocket routes retain their
  behavior.
- No raw target, headers, body data, parser exception text, or filesystem
  details are logged or returned.

### Changed files

- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/test/dart_server_static_test.dart`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- Focused static/request-limit tests `dart test
  test/dart_server_static_test.dart -r compact`: **PASS**, 12 tests.
- Focused WebSocket/auth tests `dart test test/dart_server_auth_test.dart -r
  compact`: **PASS**, 29 tests; valid native and same-origin upgrades remain
  usable and existing frame-limit coverage passes.
- Dart parser malformed request-line/header handling is platform-enforced: the
  Dart `HttpServer` parser rejects those inputs and closes the connection before
  the application callback, so this slice cannot send an application-generated
  400 for those cases through the public `HttpServer` API. The testable
  application-visible malformed-target case returns bounded 400; parser errors
  are handled with a silent server error callback.
- Full backend `dart test -r compact`: **PASS**.
- Full backend `dart analyze`: **PASS**, with only existing informational
  diagnostics.
- `dart format --output=none --set-exit-if-changed lib test`: **PASS**.
- `dart compile exe bin/backend.dart -o
  /tmp/opencode/kdedeck-http-request-limits-verified`: **PASS**.
- `git diff --check`: **PASS**.

### Scope boundary

This slice changes only standalone Dart HTTP request admission and focused
tests/docs. It does not change UI/frontend, TLS, authentication, configuration,
WebSocket frame policy, or the embedded Flutter server.

## Step 27 — Opt-in backend session-store boundary

### Goal and changes

- Added `lib/session_store.dart` with an injected synchronous `SessionStore`
  interface and `FileSessionStore`, optionally passed to `AuthSessionManager`.
  No server constructor or production startup was changed: without a store, the
  existing manager remains in-memory.
- File contents contain only SHA-256 bearer-token fingerprints, role and UTC
  issued/expiry timestamps; neither bearer tokens nor pairing codes are written.
  The `crypto` 3.0.7 package was already present transitively and is now a direct
  dependency. The factory path is under XDG_CONFIG_HOME/kdedeck or
  HOME/.config/kdedeck, with an explicit absolute path available for tests.
- A store read failure or corrupt/oversized snapshot makes the opted-in manager
  deny token validation and new pairing. A write failure clears its active
  authorization and notifies revocation listeners; it never silently continues
  as a memory-only store. Stored entries are limited by `maxActiveSessions` and
  file size. Expired records are removed during restore; revocations persist.
- Writes flush a unique temporary file then rename it over the primary; on
  POSIX the store directory is chmod 0700 and the file is chmod 0600. Failure
  results and diagnostics do not include paths or secrets.
- Added focused tests for plaintext absence, permissions, restart and role
  recovery, expiry, revocation, capacity, corrupt-store rejection, interrupted
  replacement and write failure. Existing server tests remain unchanged.

### Verification

- Full backend `dart test -r compact`: **PASS**, 122 tests.
- Full backend `dart analyze`: **PASS**, 18 informational style diagnostics,
  including two initializing-formal suggestions for the public store/test seam.
- `dart format --output=none --set-exit-if-changed lib test`: **PASS**.
- `dart compile exe bin/backend.dart -o
  /tmp/opencode/kdedeck-session-store-verified`: **PASS**.
- `git diff --check`: **PASS**. Checks used the Flutter-bundled Dart SDK.

### Limitations and next step

- This is not wired into the production standalone server; restart recovery is
  available only when a caller explicitly supplies a shared store/path. The
  embedded Flutter server and client token storage are unchanged.
- If a disk write fails during revocation, this manager denies tokens immediately
  but the last complete snapshot may still contain the token on restart. Do not
  re-enable that snapshot without an explicit local recovery/rekey policy. A
  storage failure cannot guarantee durable revocation by itself.
- Directory fsync/crash-durability, Windows atomic replacement/ACL verification,
  symlink races in parent paths, and concurrent managers/processes sharing one
  path are not addressed. Next wire production startup only alongside a durable
  failed-revocation recovery policy and cross-platform persistence checks.

## Step 28 — Session-write restart recovery barrier

### Scope and changes

- Updated `deckboard_daemon/backend/lib/session_store.dart` and
  `deckboard_daemon/backend/test/session_store_test.dart` only for this code slice.
- Writes first create and flush a private, token-free `.pending` marker before
  replacing the session snapshot. Marker is removed only after replacement.
- Reads/writes refuse any existing marker, including malformed and symlinked
  markers. Failed/interrupted writes therefore cannot silently restore an old
  token snapshot on ordinary process restart once the barrier exists.
- Revocation failures do not report success; manager clears authorization in
  the running process. Tests cover single, role, and all-session revocation.
- Successful revocation clears the marker and preserves other valid sessions.

### Verification

- Agent ran full `dart test`: **130 passed**, build/format/diff checks passed.
- Parent reran `dart test test/session_store_test.dart -r compact`: **19 passed**.
- Focused analysis: no errors/warnings, four informational style suggestions.

### Recovery and residual limits

- Do not just delete a pending marker and reuse the old snapshot. Local recovery
  must invalidate/reset the session snapshot and re-pair devices; the recovery
  command/UI is still required before production wiring.
- If storage refuses marker creation, durable invalidation is impossible; the
  operation reports failure, but the previous snapshot remains. Do not claim
  successful durable revocation or enable unattended restoration after that case.
- Directory fsync/power-loss durability, Windows ACL/replacement tests, and shared
  store locking remain required. This mechanism covers tested write/process
  interruption, not every OS/storage failure. Production persistence stays off.
- No commit/push. Next: explicit safe local reset/recovery and production wiring
  only after storage-failure policy is resolved.

## Step 29 — Confirmed offline session recovery

- Added `deckboard_daemon/backend/lib/local_session_recovery.dart` and
  `test/local_session_recovery_test.dart`; added `--reset-sessions` dispatch to
  `bin/backend.dart` and `FileSessionStore.resetSessions()`.
- Requires interactive stdin/stdout and exact `RESET` confirmation before any
  store access. Starts no daemon and creates no remote recovery endpoint.
- Commits an empty version-1 snapshot before clearing the pending marker. Failed
  replacement retains the barrier; symlink paths are refused. Old tokens cannot
  validate against the empty store after restart. No credentials/path details in
  command output.
- Agent: full backend tests **138 passed**; build, format and diff checks passed;
  analysis no errors, informational suggestions only.
- Parent: `dart test test/local_session_recovery_test.dart
  test/session_store_test.dart -r compact`: **27 passed**.
- Production persistence remains disabled. Operator MUST stop the daemon first;
  enforcement via shared-store locking, Windows protections, directory durability
  and marker-creation failure policy remain mandatory before production wiring.
- No real user session store was reset; tests use temporary fixtures only.

### Usage (offline only)

After stopping all daemon instances, from `deckboard_daemon/backend`:
`dart run bin/backend.dart --reset-sessions` (or the compiled binary with the
same flag). Confirm RESET in the local terminal. Start the daemon again and use
`--pair` for re-pairing when persistence is enabled. This currently resets the
opt-in store at the user-config path, not the live in-memory singleton.

## Step 30 — Exclusive session-store ownership

- Added lazy, lifetime nonblocking OS locking to `FileSessionStore` before
  reads/writes/reset. Private sibling `.lock` remains on disk; never delete it
  to force access because that would allow split ownership of different inodes.
- Same-isolate duplicate instances are guarded in memory as well. Each owner
  must call idempotent `close()`; closed stores refuse reuse. A new instance can
  acquire ownership after release. Local recovery closes its store in `finally`.
- Unsafe lock-file/parent paths are refused; lock is mode 0600 and directory 0700
  on POSIX. Contending read/write/reset operations fail without changing the
  primary snapshot or pending marker. Existing recovery barrier remains intact.
- Added `test/session_store_lock_test.dart` and
  `test/support/session_store_lock_probe.dart`, updated persistence/reset tests
  to release owners and account for the retained lock file.
- Agent full backend `dart test`: **144 passed**; compile/format/diff checks
  passed; analysis no errors, informational lints only.
- Parent reran lock/store/recovery suites: **33 passed**, including real child
  process contention and release after child exit. Fixtures only; no live user
  session store accessed.

### Required remaining work

Production persistence remains disabled. Integrate store ownership/release with
the server lifecycle before enabling it. Linux process/isolate ownership tested;
Windows/macOS runtime locking/ACLs and multiple isolates within one daemon still
need verification. Cooperative locks do not protect against a hostile same-user
process replacing paths, and directory fsync/power-loss safety and unwriteable
storage policy remain mandatory. No commit/push.

## Step 31 — Opt-in server session-store lifecycle

- Added an injected `sessionStoreFactory` to standalone `forTesting` construction.
  Production singleton remains in-memory; no persistent user store is opened.
- Server acquires/restores its owned store before opening the listener. Corrupt,
  pending, busy, or unavailable storage refuses startup without memory fallback.
- Stop/startup failure removes listeners, disconnects clients and releases store
  ownership; restart constructs a fresh manager/store. Supplying both an injected
  auth manager and a store factory is rejected to avoid ownership ambiguity.
- Added a manager persistence-health getter and
  `deckboard_daemon/backend/test/server_session_lifecycle_test.dart`.
- Focused lifecycle tests: **8 passed**, independently rerun by the parent.
- Agent full backend suite, serial run: **152 passed**; compile, formatting and
  diff checks passed; analysis informational notices only.
- One parallel suite run timed out in the existing subprocess lock probe; it
  passed in isolation and serially. This environment-dependent flake is tracked,
  not treated as a clean parallel-suite pass.
- Tests cover contention/reset refusal, valid-token restart, revoked-token
  rejection, pairing-secret non-restoration, storage/TLS/bind failure cleanup,
  and revocation listener start/stop balance. Temporary fixtures only.

### Next required work

Production persistence enablement still requires an explicit storage-failure
policy, directory durability safeguards and Windows/macOS verification. Shared
state async-operation shutdown ordering also requires further auditing. No
client/UI changes, commit or push.

## Step 32 — Fence stale WebSocket continuations across restart

### Goal

Prevent asynchronous work started by an old standalone WebSocket generation from
attaching sockets to a restarted listener or mutating/broadcasting state after
shutdown.

### Changes made

- Added a lifecycle generation barrier invalidated at the beginning of server
  disposal. In-flight WebSocket upgrades now close instead of joining a newer
  generation, and stale upgrade callbacks cannot corrupt the pending-connection
  count.
- Captured the generation for each accepted socket and ignored stale message
  callbacks after stop/restart.
- Revalidated the socket generation after awaited action, configuration-save,
  and installed-app discovery work. Volume, mute, and brightness state now
  change only after the awaited command completes while the original client is
  still live.
- Prevented delayed configuration continuations from assigning `configData`
  after their generation has been disposed.
- Added a deterministic regression test that blocks a mute command, stops and
  restarts the server, then verifies the old continuation cannot change the new
  server state or broadcast to the restarted client.

### Verification

- Focused stale-action regression: **PASS**.
- Focused delayed-discovery regression: **PASS**.
- Full backend suite serially with `dart test -j 1`: **PASS**, 153 tests.
- `dart analyze`: **PASS** with 21 existing informational style notices and no
  errors.
- `dart format` and `git diff --check`: **PASS**.

### Remaining limitations

- Metrics ticks, queued configuration writes, and overlapping stop/start calls
  still need a separate quiescence/serialization audit; this step fences the
  WebSocket upgrade/message paths only.
- Production session persistence remains disabled pending storage-failure,
  durability, ACL, and cross-platform locking policy and verification.
- Client authentication/UI, browser E2E, and physical platform QA remain
  outstanding.

### Next step

Audit metrics callbacks and concurrent stop/start serialization, then continue
with the highest-priority standalone security gap without enabling production
persistence prematurely.

## Step 33 — Serialize standalone lifecycle requests

### Repository state and reproduced failure

- Fetched `origin`: local HEAD and `origin/main` both remained at `a9d7c71`.
  The four existing Step 32 modified files were still local; preserved them.
- Starting a running server immediately after requesting stop, without awaiting
  stop first, returned successfully but left `isRunning == false`. The old
  `startServer()` fast path observed the pre-shutdown running flag.

### Changes

- Replaced startup-only tracking with a private lifecycle future queue. Every
  start/stop request is enqueued at invocation time, and the running-state check
  happens inside the queued start operation.
- Startup failure still disposes directly, avoiding a queue self-deadlock.
  An operation's error does not poison later queued lifecycle requests.
- Added five regressions covering stop/start overlap, start/stop/start during
  initial startup, duplicate stops with persistent-store and listener ownership,
  and failed-bind cleanup followed by restart. Tests verify an actual WebSocket
  connection, not only the running flag.
- No change to production persistence enablement, clients, or app discovery.

### Verification

- Original isolated stop/start reproduction failed before the change and passed
  after it (`isRunning == true`).
- Lifecycle test file: **13 passed**.
- Full backend `dart test -j 1 -r expanded`: **158 passed**.
- `dart analyze`: no errors or warnings; **21 informational notices** remain.
- Changed Dart files: format check passed; daemon executable compilation passed.
- `git diff --check`: passed. No commit or push was performed at that point;
  the Step 33 work was subsequently included in pushed commit `719a454`.

### Remaining work and next slice

Lifecycle command serialization does not drain all asynchronous work. Next:
generation-fence metrics ticks (including awaited subprocess/file reads), prevent
overlapping probes, and audit HTTP requests delayed in preparation before routing.
Queued config saves also need an explicit drain/cancel policy: Step 32 prevents
stale in-memory assignment but not stale disk writes after restart. Production
persistence remains off until storage-failure, durability, and platform-safety
requirements are resolved. Parallel lock-probe stability and browser/device QA
were not reverified in this step.

## Step 34 — Fence metrics probes across lifecycle generations

### Goal

Prevent a periodic Linux metrics probe from mutating the state of a restarted
server, and prevent timer ticks from launching overlapping external probes.

### Changes

- Added a validated test-only metrics interval while keeping the production
  interval at four seconds.
- Captured the lifecycle generation when the metrics loop starts and rejected
  stale or stopped ticks before work begins and after each awaited operation.
- Added an identity-based in-flight probe token. It remains owned by an old
  generation until that probe actually finishes, so an old completion cannot
  clear a newer probe's guard after restart.
- Routed metrics `pactl` reads through the existing command-executor seam for
  deterministic tests. Stop remains non-blocking; blocked external work is
  fenced rather than falsely claimed to be cancelled.
- Added a Linux regression that blocks `pactl`, verifies repeated timer ticks
  never overlap, restarts the server, and verifies stale output cannot mutate
  the new generation's volume, mute, or brightness state.

### Verification

- Lifecycle test file: **14 passed**.
- Full backend `dart test -j 1 -r compact`: **159 passed**.
- `dart analyze`: no errors; **21 informational notices** remain.
- Changed Dart files passed format checks; `git diff --check` passed.
- No commit or push performed for Step 34.

### Remaining work and next slice

HTTP requests can still be delayed in `_prepareHttpRequest` and then reach
routing after stop/restart; the next bounded slice should generation-fence that
preparation/routing boundary. Queued configuration saves still need an explicit
drain/cancel policy so an old write cannot overwrite configuration loaded by a
new generation. Production persistence remains disabled pending its listed
storage and platform-safety prerequisites.

## Step 35 — Fence delayed HTTP requests across lifecycle generations

### Goal

Prevent an HTTP request that is waiting in body preparation or filesystem
routing from entering an old server generation after stop/restart.

### Changes

- Captured the listener generation before request preparation and rejected
  stopped/stale requests before preparation, after envelope/body validation, and
  before routing.
- Added generation checks around frontend and icon filesystem awaits and bounded
  file streaming so stale work closes without serving an old response.
- Preserved the existing security headers, request limits, WebSocket upgrade
  checks, and non-blocking shutdown behavior.
- Added a deterministic held-body regression proving shutdown completes and a
  restarted server still serves the current generation correctly.

### Verification

- Focused static/lifecycle tests: **27 passed**.
- Full backend serial suite: **160 passed**.
- `dart analyze`: no errors; existing informational notices remain.
- Format and `git diff --check` passed. No commit or push performed for Step 35.

### Newly tracked release requirement

The repository did not yet define a complete upgrade contract. Current version
metadata is inconsistent (`kdedeck_mobile/pubspec.yaml` is `1.0.0+1`, the
backend package is `1.0.0`, and `ROADMAP.md` describes `v2.0.0`), and there is no
implemented updater or migration policy. Added a required release task to
`PENDING_WORK.md` for monotonic version/build metadata, stable package identity,
preserved configuration and session data, migrations, protocol compatibility,
signed artifacts, atomic replacement/rollback, and clean-install/upgrade tests.
The intended user flow is an in-place update that keeps the older installation's
data and does not require uninstalling it first.

This is a planning task only; version values, packaging, and updater behavior
were not changed in this step. Next implementation work should design the
platform-specific update path and its recovery tests before launch packaging.

## Step 36 — Drain and fence queued configuration saves

### Goal

Ensure configuration writes from an old server generation cannot race a restart,
overwrite configuration loaded by the new generation, or continue reaching disk
after a queued save has become stale.

### Changes

- Startup/test construction now has a private-backed config-writer seam; normal
  production construction still uses the existing atomic file writer.
- Each queued save checks its lifecycle generation and running state before disk
  I/O, then checks again after the awaited write before changing `configData` or
  reporting success. Stale queued saves therefore return without invoking the
  writer.
- Disposal invalidates the generation first and drains `_saveOperation` before
  releasing the old server/store and allowing a queued restart to load config.
  Failed writes remain error-safe and do not poison later lifecycle operations.
- Added a deterministic blocked-write regression covering an in-flight save,
  a queued stale save, shutdown waiting, restart, and preservation of the
  existing configuration on disk.

### Verification

- Config tests: **9 passed**.
- Lifecycle tests: **14 passed**.
- Full backend serial suite: **161 passed**.
- `dart analyze`: no errors; **21 informational notices** remain.
- Format, compilation, and `git diff --check` passed. No commit or push
  performed for Step 36.

### Remaining work and next slice

The lifecycle queue now covers HTTP, metrics, and configuration writes. Remaining
release blockers include production persistence policy and platform safety,
action timeouts/error reporting, embedded Flutter auth/WSS, and the new
versioned in-place updater task. The next bounded backend slice should address
the highest-priority persistence or action-execution gap without enabling
production persistence prematurely.

## Step 37 — Report action outcomes and reject failed state changes

### Goal

Make system-action failures observable to the authenticated client without
leaking command details, and prevent optimistic volume, mute, or brightness
state from claiming a command succeeded when it did not.

### Changes

- `SystemActionsService` launch, MPRIS, and KDE action methods now return a
  boolean outcome. Invalid payloads, unsupported actions, nonzero exit codes,
  and executor exceptions fail closed without exposing exception or command
  details.
- The standalone protocol now sends bounded `action_result` or `action_error`
  messages only while the originating socket and lifecycle generation remain
  current. Error responses contain only the action name and stable
  `action_failed` code.
- Volume, mute, and brightness state is updated/broadcast only after the
  corresponding command succeeds. Unknown actions and invalid values fail
  instead of silently succeeding.
- Added deterministic executor-backed tests for failed state actions, successful
  result ordering, invalid media/KDE actions, nonzero exits, and thrown command
  failures.

### Verification

- Focused system-action/auth tests: **47 passed**.
- Full backend serial suite: **170 passed**.
- `dart analyze`: no errors; **21 informational notices** remain.
- Format, compilation, and `git diff --check` passed. No commit or push
  performed for Step 37.

### Remaining work and next slice

This slice does not cancel or kill an OS process whose future is slow or stuck;
`Future.timeout` alone would not provide that guarantee. Subprocess timeout,
termination, bounded output, and platform-specific recovery remain a separate
release requirement. Production persistence, local role approval, sensitive
action confirmation, and the versioned in-place updater task also remain open.

## Step 38 — Bound control subprocesses and sanitize execution failures

### Goal

Prevent control, discovery, and metrics commands from hanging the daemon or
accumulating unbounded output, while preserving the behavior of user-launched
applications whose lifetime belongs to the user.

### Changes

- Added `ProcessCommandExecutor.bounded()` with validated timeout, termination
  grace, and combined stdout/stderr byte-limit options. It starts processes
  without a shell, drains both pipes concurrently, closes stdin, and returns
  normal `ProcessResult` values including nonzero exits.
- Bounded failures use sanitized reason codes for start, timeout, output-limit,
  and I/O failures. Timeout/output failures terminate the direct child with
  POSIX TERM-then-KILL escalation and bounded cleanup. This does not claim
  process-tree termination, especially for descendants or Windows.
- Standalone control, app discovery, and metrics operations now use the bounded
  executor by default. `launch_app` and `open_url` retain the legacy executor so
  a timeout policy cannot kill an application the user intentionally opened;
  injected test executors remain compatible.
- Added real subprocess probes for argv/environment, nonzero exits, timeout and
  TERM-ignoring children, output floods, sanitized startup errors, descendant
  pipe handling, and executor reuse. Added server integration tests for bounded
  action errors and separate launch/control executors.

### Verification

- Focused executor/integration/auth/action tests: **57 passed**.
- Full backend serial suite: **180 passed**.
- `dart analyze`: no errors; **21 informational notices** remain.
- Format, daemon compilation, and `git diff --check` passed. No commit or push
  performed for Step 38.

### Remaining work and next slice

The direct-child boundary is deliberate: descendants may survive, and Windows
termination semantics need platform verification. User-launched application
ownership/lifetime and fabricated metrics remain open. Production persistence
policy, local role approval, sensitive action confirmation, Flutter auth/WSS,
and the versioned in-place updater remain release work.

## Step 39 — Gate sensitive power and session actions

### Goal

Prevent authenticated remote control clients from invoking KDE power/session
actions unless a local daemon policy explicitly enables them and destructive
actions receive a local confirmation.

### Changes

- Added the default-deny `SensitiveActionPolicy` seam to the standalone server.
  Production setup can configure it before accepting remote clients; tests can
  inject an isolated policy without credentials or request data.
- `sleep`, `shutdown`, `logout`, and `lock` now fail closed unless the explicit
  sensitive-action policy is enabled. Existing authenticated control capability
  checks remain required.
- `sleep`, `shutdown`, and `logout` additionally require an action-scoped async
  local confirmation callback. Missing, false, throwing, or stale-generation
  confirmations deny the command. `lock` can be enabled without confirmation,
  but remains denied by default.
- Denials use the existing bounded requester-only `action_error` response and
  never reach the command executor. Confirmation and command continuations keep
  the existing socket/lifecycle fencing.
- Added deterministic tests for default denial, positive/negative confirmation,
  lock policy behavior, requester-only errors, ordinary-action isolation, and
  stop-time confirmation fencing.

### Verification

- Focused sensitive-action, command-limit, and auth tests: **43 passed**.
- Full backend serial suite: **187 passed**.
- `dart analyze`: no errors; **22 informational notices** remain.
- Format, daemon compilation, and `git diff --check` passed. No commit or push
  performed for Step 39.

### Remaining work and next slice

This adds a backend policy seam, not a desktop confirmation UI or role-approval
workflow. The policy must be wired to a trusted local UI/desktop prompt before
production sensitive actions are enabled. Local role selection, production
persistence safety, approved application identities, client authentication UX,
and versioned in-place upgrades remain open.

## Step 40 — Advertise standalone protocol metadata

### Goal

Add a small additive compatibility advertisement to authenticated standalone
`init_state` responses without changing authentication, message ordering, action
behavior, or the embedded Flutter server.

### Changes

- Added immutable `StandaloneProtocolMetadata` with protocol version `1` and the
  bounded capability list `trigger_action`, `save_config`, and `get_system_apps`.
- Added `protocol_version` and `capabilities` to authenticated standalone
  `init_state` messages. The fields contain no credentials, paths, or host
  details.
- Added focused authenticated protocol assertions and documented that the fields
  are advertisement only; no negotiation or compatibility enforcement is added.

### Changed files

- `deckboard_daemon/backend/lib/protocol_metadata.dart`
- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/test/dart_server_auth_test.dart`
- `docs/protocol.md`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- `dart test test/dart_server_auth_test.dart -r compact`: **PASS**, 33 tests.
- `dart format lib/protocol_metadata.dart lib/dart_server_service.dart
  test/dart_server_auth_test.dart`: **PASS**, no files changed.
- `git diff --check`: **PASS**.

### Scope boundary

This is advertisement only. Version negotiation, compatibility enforcement,
embedded Flutter convergence, and client consumption remain future work.

## Step 41 — Advertise authenticated session capabilities

### Goal

Expose the validated session's existing authorization capabilities so clients
can hide unsupported controls without changing server-side authorization.

### Changes

- Added `session_capabilities` to authenticated standalone `init_state`
  messages, derived directly from the existing `AuthRole` permission model.
- Added reconnect coverage for viewer, control, and config-admin sessions.
- Documented that the field is informational and does not grant permissions.

### Changed files

- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/test/dart_server_auth_test.dart`
- `docs/protocol.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- `dart test test/dart_server_auth_test.dart -r compact`: **PASS**, 36 tests.
- `dart format ...`: **PASS**, no files changed.
- `git diff --check`: **PASS**.

### Scope boundary

Client UI consumption, version negotiation, compatibility enforcement, and
embedded Flutter convergence remain future work.

## Step 42 — Add a backward-compatible config schema marker

### Goal

Create a small compatibility boundary for future configuration migrations
without requiring an older installation to be removed or rewriting legacy files
just because they omit a version marker.

### Changes

- Added `currentConfigSchemaVersion` with value `1` to the standalone validator.
- Legacy configs without `config_schema_version` are accepted and normalized in
  memory; explicit version `1` is accepted, while other values return the
  bounded `unsupported_config_version` error.
- New default configs include `config_schema_version: 1`.
- Added validator, daemon-default, and protocol documentation coverage.

### Changed files

- `deckboard_daemon/backend/lib/config_validator.dart`
- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/test/config_validator_test.dart`
- `deckboard_daemon/backend/test/dart_server_config_test.dart`
- `docs/protocol.md`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- `dart test test/config_validator_test.dart test/dart_server_config_test.dart
  -r compact`: **PASS**, 20 tests.
- `dart format --set-exit-if-changed ...`: **PASS**, no files changed.
- `git diff --check`: **PASS**.

### Scope boundary

This adds a compatibility marker only. Version migrations, protocol negotiation,
production persistence enablement, and release updater behavior remain pending.

## Step 43 — Enforce an optional standalone protocol version

### Goal

Turn the existing standalone protocol advertisement into a small compatibility
boundary without breaking clients that predate version negotiation.

### Changes

- Added optional `protocol_version` validation to standalone `authenticate`
  frames.
- Accepted omitted versions and the advertised version `1` for backward
  compatibility.
- Rejected unsupported or malformed supplied versions with the bounded
  `unsupported_protocol_version` authentication error before credentials are
  evaluated. Rejected versions do not consume pairing codes or create sessions.
- Added authenticated integration coverage and documented the client message
  shape and compatibility behavior.

### Changed files

- `deckboard_daemon/backend/lib/protocol_metadata.dart`
- `deckboard_daemon/backend/lib/dart_server_service.dart`
- `deckboard_daemon/backend/test/dart_server_auth_test.dart`
- `docs/protocol.md`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- `dart test test/dart_server_auth_test.dart -r compact`: **PASS**, 37 tests.
- Full backend `dart test -r compact`: **PASS**, 194 tests.
- `dart format --set-exit-if-changed ...`: **PASS**, no files changed.
- `git diff --check`: **PASS**.

### Scope boundary

This enforces an optional version on the standalone authentication boundary.
Embedded Flutter convergence, client-side version handling, protocol migration
policy, production persistence, and the versioned in-place updater remain
pending.

## Step 44 — Expose standalone daemon release metadata

### Goal

Create a small, scriptable release identity for the standalone daemon without
starting a listener or changing its persisted-data behavior.

### Changes

- Added `StandaloneReleaseMetadata` with artifact name `kdedeck_daemon`, version
  `1.0.0`, build `1`, and display value `kdedeck_daemon 1.0.0+1`.
- Added `--version` handling to the daemon entry point; it prints the release
  identity and exits before server startup.
- Aligned the backend package version with the release version/build metadata.
- Added regression coverage and documented the command in the root README.

### Changed files

- `deckboard_daemon/backend/lib/release_metadata.dart`
- `deckboard_daemon/backend/bin/backend.dart`
- `deckboard_daemon/backend/pubspec.yaml`
- `deckboard_daemon/backend/test/release_metadata_test.dart`
- `README.md`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- `dart test test/release_metadata_test.dart -r compact`: **PASS**, 1 test.
- `dart run bin/backend.dart --version`: **PASS**, prints
  `kdedeck_daemon 1.0.0+1` and exits without opening a listener.
- Full backend `dart test -r compact`: **PASS**, 195 tests.
- Focused `dart analyze`: **PASS**, no issues.
- `dart format --set-exit-if-changed ...` and `git diff --check`: **PASS**.

### Scope boundary

This establishes standalone daemon metadata only. Flutter package identity,
stable Android/Linux application IDs, signed artifacts, migration automation,
atomic replacement, rollback, and clean-install/upgrade tests remain pending.

## Step 45 — Establish stable Android/Linux application identity

### Goal

Remove generated Flutter example identifiers from the Android and Linux targets
so future in-place updates address the same installed application.

### Changes

- Set the Android namespace and `applicationId` to
  `io.github.deepthumar81.kdedeck`.
- Moved `MainActivity` into the matching Kotlin package.
- Set the Linux GTK application ID to the same stable identifier.
- Recorded the identity decision in the pending-work tracker.

### Changed files

- `kdedeck_mobile/android/app/build.gradle.kts`
- `kdedeck_mobile/android/app/src/main/kotlin/io/github/deepthumar81/kdedeck/MainActivity.kt`
- `kdedeck_mobile/android/app/src/main/kotlin/com/example/kdedeck_mobile/MainActivity.kt`
- `kdedeck_mobile/linux/CMakeLists.txt`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- `flutter analyze`: **PASS**, no errors; 96 existing warnings/informational
  diagnostics remain.
- `flutter build apk --debug`: **PASS**, producing
  `kdedeck_mobile/build/app/outputs/flutter-apk/app-debug.apk`.
- A repository search found no remaining `com.example.kdedeck_mobile` identity.
- Existing provider-less widget smoke-test status remains separate from this
  native identity change.

### Scope boundary

This establishes Android/Linux identity only. iOS/macOS bundle identifiers,
signed artifacts, migrations, atomic replacement, rollback, and clean-install /
upgrade tests remain pending.

## Step 46 — Standalone persistence safety and conflict boundary

### Goal

Harden the standalone persistence boundaries and exercise them through the
public server without turning the opt-in test seam into production behavior.

### Changes

- Added `deckboard_daemon/backend/test/server_persistence_safety_test.dart`.
- Session-store writes now retain the pending marker if clearing it fails after
  the new snapshot has been installed, preserving fail-closed restart behavior.
- Authenticated standalone `init_state` and `config_updated` messages now carry
  an in-process config revision. Explicit stale saves receive a bounded
  `config_conflict` response and cannot overwrite active or persisted config;
  clients omitting the field remain backward-compatible.
- The integration coverage starts a standalone server with the explicit
  `sessionStoreFactory` test seam, authenticates over WebSocket, saves a valid
  configuration, rejects a stale revision without changing the saved file,
  stops it, then creates a fresh server instance and reconnects with the
  restored bearer token. The fresh instance loads the saved config and starts
  a new in-memory revision counter.
- The failure case injects a session-store marker-clear failure and verifies the
  public protocol returns only a bounded credential-neutral authentication
  error; the pending marker then prevents a restarted server from listening.
- All storage fixtures use temporary paths. Production startup remains in-memory.

### Verification

- `dart test test/server_persistence_safety_test.dart -r expanded`: **PASS**,
  2 tests (Flutter-bundled Dart SDK).
- Full backend `dart test -r compact`: **PASS**, 199 tests.
- Focused session-store/config/server tests: **PASS**.
- `dart analyze test/server_persistence_safety_test.dart`: **PASS**, no issues.
- `dart format --output=none --set-exit-if-changed
  test/server_persistence_safety_test.dart`: **PASS**, zero files changed.
- `git diff --check`: **PASS**.

### Scope boundary

This records public-server coverage for the opt-in test persistence boundary.
Production persistence is not solved: storage-failure policy, directory
durability, cross-platform replacement/ACL behavior, multi-isolate ownership,
and production startup wiring remain pending.

## Step 47 — Make web configuration saves revision-aware

### Goal

Have the existing web configurator participate in the standalone protocol's
optional compatibility and config-conflict boundaries without breaking older
servers or silently overwriting another client's changes.

### Changes

- Web authentication now advertises standalone protocol version `1`.
- The configurator tracks the revision from `init_state` and
  `config_updated`, sending it with subsequent `save_config` requests when
  available.
- A `config_conflict` response preserves the local draft, blocks further saves,
  and tells the user to reload instead of retrying a stale write.
- Legacy servers that omit revisions remain usable; the client simply omits the
  optional field.

### Changed files

- `deckboard_daemon/frontend/app.js`
- `docs/PENDING_WORK.md`
- `docs/DEVELOPMENT_LOG.md`

### Verification

- `node --check app.js`: **PASS**.
- Focused backend regression coverage remains provided by Step 46.

### Scope boundary

This covers web revision participation only. WebSocket credential storage,
complete browser end-to-end tests, Flutter auth/WSS, and server-side production
persistence remain pending.
