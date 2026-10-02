# ADR-001: Keep the Dart backend as the local control plane

- **Status:** Accepted; describes the current implementation
- **Date:** 2026-10-01
- **Scope:** Local daemon, Flutter desktop server, WebSocket protocol, and OS
  integration boundary

## Context

KDE Deck began as a Linux remote-deck project and the repository documents a
migration from a Python prototype to Dart/Flutter. The current product target
is KDE Plasma on Linux (Wayland and X11), with Windows and macOS planned later
([`README.md`](../../README.md#L21-L28), [`ROADMAP.md`](../../ROADMAP.md#L10-L18)).
The system needs one local process that can accept phone/browser commands,
persist boards, expose the web configurator, and execute host actions without
requiring a Python or Node runtime.

The repository now contains:

- a standalone Dart server in
  `deckboard_daemon/backend/lib/dart_server_service.dart`;
- an embedded, similar Dart server in
  `kdedeck_mobile/lib/services/dart_server_service.dart` for Flutter desktop;
- a Flutter client using `WebSocketService`;
- a static web configurator; and
- a Go tray process that launches the standalone Dart server.

The two Dart servers are already the de facto control plane, but they are not
yet a shared library and have observable behavior differences. Linux system
operations are implemented through `SystemActionsService` and
`LinuxActionsService`; Windows/macOS host-operation branches are incomplete.

## Decision

Keep Dart as the local backend/control-plane language and keep JSON over
WebSocket on port `8484` as the compatibility protocol. Continue to separate
the user interfaces (Flutter phone, Flutter desktop configurator, and browser)
from host execution. Retain the Go tray as a thin process launcher rather than
moving protocol or OS actions into Go.

The immediate architectural rules are:

1. **Preserve Linux behavior.** Existing Linux audio, brightness, MPRIS/KDE,
   app discovery, icon lookup, metrics, and config flows are compatibility
   requirements. New platform work must not replace the Linux command/D-Bus,
   sysfs, `/proc`, desktop-entry, Flatpak, Snap, or icon paths.
2. **Treat the wire format as shared API.** Keep `init_state`, `trigger_action`,
   `save_config`, `config_updated`, `state_update`, and
   `system_apps_list` stable while clients are updated. Document unsupported
   or compatibility-only messages rather than implying they work.
3. **Keep OS code behind an explicit boundary.** The current
   `SystemActionsService`/`LinuxActionsService` branches are the extension
   point. Windows and macOS support should be added as platform adapters for
   launch, audio, brightness, media, app discovery, and icons, not by making
   the protocol platform-specific.
4. **Prefer one shared core in the future.** The standalone and embedded Dart
   servers should converge on shared protocol/config/state code. Transport
   hosting (standalone HTTP/static files versus embedded Flutter `/ws`) and
   platform adapters may remain separate.

## Current implementation evidence

- Standalone daemon startup and signal handling are in
  [`bin/backend.dart`](../../deckboard_daemon/backend/bin/backend.dart#L5-L28).
- Standalone HTTP/WebSocket routing and client broadcast state are in
  [`dart_server_service.dart`](../../deckboard_daemon/backend/lib/dart_server_service.dart#L49-L165).
- Standalone persistence and validation are in
  [`dart_server_service.dart`](../../deckboard_daemon/backend/lib/dart_server_service.dart#L196-L225)
  and [`dart_server_service.dart`](../../deckboard_daemon/backend/lib/dart_server_service.dart#L407-L478).
- Standalone Linux host integration and Windows/macOS TODO branches are in
  [`system_actions_service.dart`](../../deckboard_daemon/backend/lib/system_actions_service.dart#L44-L133)
  and [`system_actions_service.dart`](../../deckboard_daemon/backend/lib/system_actions_service.dart#L135-L274).
- The Flutter desktop app starts the embedded server on all three desktop
  platforms, but embedded action execution is currently Linux-gated
  ([`main.dart`](../../kdedeck_mobile/lib/main.dart#L17-L35),
  [`services/dart_server_service.dart`](../../kdedeck_mobile/lib/services/dart_server_service.dart#L171-L231)).
- The Go tray launches the standalone daemon and chooses a browser opener by
  OS ([`main.go`](../../deckboard_daemon/tray/main.go#L51-L100)).

## Consequences

### Positive

- A compiled Dart daemon can be distributed without a Python virtual
  environment, matching the stated migration goal.
- Flutter clients can remain relatively thin and reuse the same config/state
  vocabulary across phone and desktop surfaces.
- Linux can continue to use its native integration paths while other operating
  systems are developed incrementally.
- The Go tray remains small and replaceable; it does not become a second
  protocol implementation.

### Accepted costs and limitations

- There is temporary duplication between the standalone and embedded Dart
  servers. Config persistence, validation, HTTP routes, app discovery, MPRIS,
  and KDE behavior can diverge.
- The current protocol has no authentication, encryption, request IDs,
  acknowledgements, structured errors, or version negotiation. The server
  binds all IPv4 interfaces and reports `pin_required: false`.
- Host actions can execute powerful commands, and `/system_icons` accepts a
  caller-provided file path. This is not yet a hardened network service.
- Windows/macOS compilation/launch branches exist, but system control and app
  discovery are not complete. They must not be advertised as parity with
  Linux until the adapters and tests exist.
- Current tests do not cover the protocol; the backend test is still the
  generated `calculate()` sample.

## Future boundary design

The intended incremental refactor is:

```text
Standalone HTTP/WebSocket adapter       Flutter embedded WebSocket adapter
                 \                       /
                  --> shared protocol/core <--
                         |
                    SystemActionsPort
              /          |             \
       Linux adapter  Windows adapter  macOS adapter
```

The shared core should own config schema/defaults, validation, state
transitions, action names, capability reporting, and protocol errors. Each
transport should only adapt connection lifecycle and persistence/static-file
concerns. Each platform adapter should report an explicit result so the core
does not broadcast successful-looking state when an OS command failed.

Migration should be staged:

1. Add protocol/config tests against the current standalone behavior.
2. Extract common message handling and config validation without changing the
   existing Linux wire messages.
3. Inject a platform action interface, first backed by the existing Linux
   implementation.
4. Implement and test Windows/macOS adapters and tray launch details.
5. Add optional authentication, safe icon allowlisting, request IDs, and
   structured errors as additive protocol features.

Until that work is complete, treat the standalone daemon as the reference
Linux implementation and the embedded server as a desktop convenience path,
not as two interchangeable releases.
