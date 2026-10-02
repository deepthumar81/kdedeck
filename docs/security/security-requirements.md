# KDE Deck security requirements

## How to use this document

These requirements apply to both Dart server implementations unless a
requirement names a platform-specific exception. They are intended to be
implemented behind the shared protocol/core boundary proposed in
[`../architecture.md`](../architecture.md#future-boundary-design), not as
separate security logic in the standalone and embedded servers.

Priorities:

* **P0 — must:** required before a server listens beyond loopback or is called
  LAN-ready. A failing P0 is a release blocker.
* **P1 — should:** required for the hardened LAN release and before enabling a
  sensitive capability by default.
* **P2 — may:** defense in depth or usability improvement that must not weaken a
  P0/P1 control.

Acceptance criteria below are deliberately observable. They can be implemented
as unit tests with fake executors, Dart server integration tests on ephemeral
ports, fixture filesystem tests, and controlled Linux end-to-end checks as
outlined in [`../testing.md`](../testing.md).

## Transport and exposure

### SEC-TRN-001 — Safe default bind (P0)

The standalone and embedded servers **must** bind loopback by default. LAN
listening must require an explicit user-visible setting and must report the
active bind mode and port.

**Acceptance criteria:** A default-start integration test connects from
`127.0.0.1` and cannot connect through the machine's LAN address; a configured
LAN mode binds the requested interface only; startup state never silently
falls back from loopback to `anyIPv4`.

### SEC-TRN-002 — Authenticated encrypted LAN transport (P0)

LAN WebSocket sessions **must** use `wss` with certificate verification and a
documented trust/fingerprint flow. Plain `ws` is permitted only for explicitly
marked loopback/development mode.

**Acceptance criteria:** A client rejects an invalid, expired, hostname-mismatched,
or untrusted certificate; a LAN connection attempting plain `ws` is rejected
or receives a clear disabled response; no credential is sent before TLS is
established.

### SEC-TRN-003 — WebSocket/HTTP request limits (P0)

The server **must** cap concurrent connections, handshake/header size, frame
size, JSON nesting depth, string length, collection counts, and request body
size. It must close or reject malformed/over-limit sessions without an
uncaught exception.

**Acceptance criteria:** Tests send invalid JSON, non-object JSON, deeply nested
JSON, oversized strings/base64 images, and oversized frames; each receives a
bounded error/close, consumes bounded memory, and cannot trigger an action or
config write.

### SEC-TRN-004 — Browser origin and cache policy (P1)

The HTTP/configurator path **must** enforce an explicit origin policy for
browser-controlled requests, avoid permissive CORS, and prevent private state
or icon responses from being cached or reflected to an unauthorized origin.

**Acceptance criteria:** Requests from an unapproved origin cannot upgrade or
read protected endpoints; responses do not contain permissive `*` credentials
headers; authenticated state and error responses carry no-store or equivalent
private cache policy.

## Authentication and pairing

### SEC-AUT-001 — Pair before state or commands (P0)

The server **must** authenticate a client before sending `init_state`, metrics,
configuration, app inventory, or accepting any action/configuration message.
Unauthenticated sockets must have no privileged protocol behavior.

**Acceptance criteria:** An unauthenticated socket receives no config, metrics,
installed-app list, icon bytes, or action result; `trigger_action`, `save_config`,
and `get_system_apps` are rejected and the fake executor records zero calls.

### SEC-AUT-002 — One-time pairing bootstrap (P0)

Pairing **must** require explicit local approval and a cryptographically random,
short-lived, one-time bootstrap code. The daemon **must** store only a salted
verifier and **must not** log or include the code in protocol state.

**Acceptance criteria:** A code expires at its configured deadline, succeeds only
once, cannot be reused after a successful pair, and is absent from captured
logs, `init_state`, errors, and persisted plaintext config.

### SEC-AUT-003 — Token protection and revocation (P0)

An established client credential **must** be high entropy, scoped to a client,
stored in the platform secure store on the client where available, and
revocable. Revocation **must** close active sockets and invalidate outstanding
credentials for that client.

**Acceptance criteria:** A revoked token cannot reconnect or continue an active
session; another client's token remains valid; no token is stored in
`deckboard_config.json`, logs, or broadcast messages; reconnect does not
silently downgrade to unauthenticated access.

### SEC-AUT-004 — Brute-force resistance (P0)

Pairing and authentication **must** have per-source and global rate limits,
exponential backoff or temporary lockout, and a bounded failure response. The
implementation must avoid revealing whether a client identifier exists.

**Acceptance criteria:** A test burst of failed attempts reaches a documented
limit, delays or blocks further attempts, does not affect already paired
clients, and emits redacted audit events without the submitted secret.

### SEC-AUT-005 — Explicit legacy behavior (P1)

The `pin_required` field **must not** claim authentication is active when it is
not. Any legacy unauthenticated mode must be loopback-only, visibly marked, and
disabled when LAN mode is enabled.

**Acceptance criteria:** Protocol tests verify the flag and connection policy
match actual enforcement; a LAN configuration cannot start with
`pin_required: false` and open command access.

## Authorization and sensitive actions

### SEC-AZ-001 — Capability-based authorization (P0)

The server **must** authorize every request by authenticated client and
capability, not merely by connection status. At minimum, separate state/view,
ordinary control, and configuration/discovery permissions.

**Acceptance criteria:** A viewer cannot trigger actions or save config; a
control client cannot save config or request discovery; an authorized client
can perform only the actions listed in its capability set. Negative tests cover
every message type and action name.

### SEC-AZ-002 — Sensitive power/session actions (P0)

Sleep, shutdown, logout, lock, and future equivalent actions **must** be
disabled for ordinary remote clients and require a separately enabled policy.
Shutdown/logout/suspend **must** require a local confirmation by default.

**Acceptance criteria:** Remote calls fail closed without the capability and
without confirmation; no system command is recorded by the fake executor. A
controlled manual test verifies the confirmation path without executing a
destructive action on a developer workstation.

### SEC-AZ-003 — Request scoping and broadcasts (P1)

Requester-specific responses (including app discovery and errors) **must** be
sent only to the requester. Broadcasts **must** contain only data authorized
for all connected recipients and no credentials, raw paths, or host errors.

**Acceptance criteria:** Two-client integration tests prove that a discovery
response and an authorization error are not delivered to the other socket;
shared state updates contain only the documented public fields.

## Command execution and URL handling

### SEC-CMD-001 — No shell for network-controlled input (P0)

No action or discovered-app payload received from a client **may** be passed to
`sh -c`, `cmd /c`, PowerShell, or an equivalent shell. Host execution **must**
use an executable plus an argv list, with a fixed environment and timeout.

**Acceptance criteria:** Fake-executor tests submit `;`, `&&`, backticks,
newlines, redirections, and environment expansions; none reach a shell and
none execute. The recorded request has a structured executable and arguments.

### SEC-CMD-002 — Action allowlists and typed values (P0)

The protocol **must** allowlist action names and payload enums. Volume and
brightness values must be finite numeric values within policy bounds. Unknown
actions, invalid types, NaN/infinite values, and extra command fields must be
rejected with an explicit error.

**Acceptance criteria:** Boundary and malformed-value tests cover every action;
accepted values are clamped or rejected according to one documented rule, and
the host executor is called only for valid requests.

### SEC-CMD-003 — URL validation (P0)

`open_url` **must** accept only parsed `http`/`https` URLs, with bounded length,
no control characters, and no implicit credentials or alternate schemes. The
complete URL must be passed as one argument to the platform opener.

**Acceptance criteria:** Tests reject `file:`, `javascript:`, `data:`, shell
metacharacters/control characters, malformed URLs, and overlong URLs; valid
HTTP(S) URLs remain launchable on Linux and are represented as one argv value.

### SEC-CMD-004 — Safe platform adapters (P0)

Linux, Windows, and macOS adapters **must** expose explicit capability and
success/failure results. Unsupported operations must not fall through to a
generic shell or claim success. Linux D-Bus, sysfs, `/proc`, PulseAudio/PipeWire,
desktop-entry, Flatpak, Snap, and icon behavior remains the compatibility
baseline.

**Acceptance criteria:** Capability tests show unsupported Windows/macOS
operations as unavailable; fake Linux adapters preserve all currently supported
safe actions; failed commands produce failed results and no optimistic success
state.

## Configuration validation and persistence

### SEC-CFG-001 — Shared strict schema (P0)

Both servers **must** validate the same config schema before applying or
persisting it. The validator must bound board/item counts, IDs, titles, grid
dimensions, spans, coordinates, action/payload lengths, and encoded image size;
require finite integers where appropriate; reject malformed maps/lists and
duplicate IDs.

**Acceptance criteria:** The same fixture corpus produces the same accept/reject
decision in standalone and embedded tests. Invalid, huge, negative, fractional,
duplicate, and deeply nested values do not alter the active config or call a
host executor.

### SEC-CFG-002 — Preserve valid features without preserving dangerous input (P0)

Validation **must** preserve valid boards, slider semantics, titles, safe action
names, desktop-app payloads, `icon_base64`, and `system_icon_path` references
needed by the current clients. Unknown fields may be retained only when they
meet size/type safety limits and are never interpreted as commands.

**Acceptance criteria:** Round-trip fixtures from the checked-in config, valid
desktop entries, Flatpak/Snap entries, and valid PNG/SVG/XPM references render
after save/reload; dangerous payloads and oversized images are rejected with a
visible error.

### SEC-CFG-003 — Revision and atomic recovery (P0)

Config writes **must** use a revision or compare-and-swap check, write to a
temporary file/preference transaction, atomically replace the active value, and
retain a bounded last-known-good backup. A failed write must leave the prior
config usable.

**Acceptance criteria:** Concurrent stale saves receive a conflict and cannot
overwrite a newer config; injected write failure leaves the prior config
loadable; restart selects the last valid config and records a redacted recovery
event.

### SEC-CFG-004 — Safe defaults and local recovery (P1)

If config parsing or validation fails, the daemon **must** fail closed to a
minimal safe default or last-known-good config, must not execute entries while
recovering, and must provide a local-only reset/re-pair path.

**Acceptance criteria:** Corrupt, truncated, and tampered fixtures load without
crashing; no payload executes during recovery; a local user can reset config and
revoke all clients without a network-authenticated session.

## App discovery and icon access

### SEC-FS-001 — Constrained icon roots (P0)

`/system_icons` **must** resolve paths against approved system, Flatpak, Snap,
and configured user icon roots. It must canonicalize the path, reject traversal
and symlink escapes, require a regular PNG/SVG/XPM file, and enforce file-size
and response limits. Arbitrary filesystem paths are forbidden.

**Acceptance criteria:** Tests accept valid icons in each approved root and
reject `..`, absolute paths outside roots, non-icon extensions, directories,
broken links, and symlink escapes. Valid icons still render in the web and
Flutter clients.

### SEC-FS-002 — Preserve safe Linux discovery (P0)

Hardening **must not remove valid applications** from `/usr/share/applications`,
the user application directory, Flatpak exports, or Snap. Desktop-entry parsing
must handle placeholders such as `%U`/`%F`, malformed entries, missing icons,
duplicates, and localized names without turning `Exec` into shell input.

**Acceptance criteria:** Fixture scans retain all valid expected apps, deduplicate
by stable identity, preserve safe Flatpak/Snap launch forms, and exclude
malformed or unsafe entries. Discovery results contain safe structured launch
data rather than an arbitrary shell string.

### SEC-FS-003 — Discovery privacy (P1)

App discovery and icon responses **must** be capability-gated, requester-scoped,
bounded, and minimized. Raw host paths should not be exposed to clients unless
needed for the approved icon flow; if exposed, they remain constrained to the
approved roots.

**Acceptance criteria:** An unauthorized client cannot enumerate apps or read
icons; an authorized response is bounded and contains no files outside approved
roots; logs do not include full discovery payloads by default.

## Logging, privacy, and operations

### SEC-LOG-001 — Redacted security logging (P0)

Security logs **must** record pairing, authentication, authorization denials,
rate-limit events, config recovery, and adapter failures with timestamp,
outcome, client identifier, and correlation ID. They **must not** contain
pairing codes, bearer tokens, passwords, full command payloads, raw config,
icon bytes, or URL query secrets.

**Acceptance criteria:** A redaction test scans structured logs generated by
each failure and success path for submitted secrets, tokens, and known payloads;
none are present. Log output is bounded and uses stable event names.

### SEC-LOG-002 — Privacy-minimizing state (P1)

Metrics, installed-app inventory, client addresses, and filesystem paths
**must** be disclosed only to the roles that need them. Errors sent to clients
must be safe summaries, not process output or stack traces.

**Acceptance criteria:** Role-based protocol tests verify the minimum state in
`init_state` and responses; client-visible errors contain no stack trace,
command line, token, or unapproved absolute path.

### SEC-LOG-003 — Audit retention and access (P1)

The product **must** document retention, rotation, and local filesystem access
for security logs. Logs must be written with permissions appropriate to the
launching user and must not become a second unbounded storage channel.

**Acceptance criteria:** A rotation/size test bounds log growth and verifies
that the log file is not world-readable by default; the documentation states
how a user can export or delete logs during recovery.

### SEC-RATE-001 — Resource and action rate limits (P0)

The server **must** limit new connections, authentication attempts, config
writes, app discovery, icon reads, and host actions per source/client, with
separate concurrency and queue limits. Safe polling must not starve control or
recovery operations.

**Acceptance criteria:** Flood tests hit documented limits without unbounded
memory, process creation, or file reads; valid clients recover after the
window; shutdown/recovery remains available to the local operator.

### SEC-REC-001 — Fail-closed restart and recovery (P0)

On crash, restart, failed adapter, failed authentication store, or unavailable
TLS material, the service **must** disable remote privileged operation rather
than fall back to unauthenticated `ws` or arbitrary command execution.

**Acceptance criteria:** Fault-injection tests for each dependency produce a
non-running or loopback-safe server, preserve the last valid config, and require
explicit local repair/re-pair before LAN actions resume.

## Windows and macOS future support

### SEC-XPLAT-001 — Isolated platform implementations (P0)

Windows and macOS support **must** be implemented behind platform adapters and
the shared protocol/core policy. Each adapter must use native structured APIs
or fixed argv tools, never a shell fallback, and must report capabilities
explicitly.

**Acceptance criteria:** Platform matrix tests show no Linux command or generic
shell is selected on Windows/macOS; unsupported actions return a stable
capability error; authentication, authorization, limits, logging, and config
validation tests run unchanged for all platforms.

### SEC-XPLAT-002 — Preserve Linux baseline (P0)

Adding another platform **must not** remove or weaken Linux D-Bus, sysfs,
`/proc`, PulseAudio/PipeWire, desktop-entry, Flatpak, Snap, or icon behavior.

**Acceptance criteria:** The Linux regression gates in `testing.md` pass before
and after each cross-platform change, including valid installed-app discovery,
valid icon rendering, and safe audio/brightness/media/KDE operations.

### SEC-XPLAT-003 — Platform-specific storage and permissions (P1)

Future desktop clients must use OS-appropriate secure storage and file
permissions for tokens, config, backups, and logs. The tray/embedded server
must not expose a LAN listener merely because the desktop build is running.

**Acceptance criteria:** Windows and macOS packaging tests verify private token
and config permissions, loopback default binding, explicit LAN opt-in, and
local-only reset/revoke behavior.

## Release gate

A release is LAN-ready only when all P0 requirements pass on the standalone
daemon and embedded server, all applicable P1 requirements have an owner or
documented exception, and the regression gates in `docs/testing.md` demonstrate
that valid boards, installed apps, icons, and Linux actions remain functional.
Any exception must name the affected asset, exposure, compensating control,
expiry/review date, and the user-visible warning.
