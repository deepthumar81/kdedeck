# KDE Deck protocol (current state)

This is the protocol actually implemented by the standalone Dart server on
`main`. It is JSON-over-WebSocket with no negotiated subprotocol. After
authentication, `init_state` includes additive protocol metadata advertising a
stable version and bounded capability list. The standalone server requires
authentication before sending state or handling control/configuration requests.
The Flutter embedded server remains a separate implementation and is not
changed by this step.

## Transport and endpoints

| Endpoint | Standalone daemon | Flutter desktop embedded server |
|---|---|---|
| Bind | `127.0.0.1:8484` by default; `0.0.0.0:8484` only with `allow_lan: true` | `0.0.0.0:8484` (`anyIPv4`) |
| WebSocket | `wss://host:8484/ws` for LAN/TLS; `ws://127.0.0.1:8484/ws` only when loopback TLS is unset | `ws://host:8484/ws` |
| `/` and static frontend | Serves `deckboard_daemon/frontend` | Not served; returns `KDeDeck Server Running` with 404 |
| `/system_icons?path=...` | Serves an existing file path | Not served |
| Persistence | `deckboard_config.json` in daemon working directory | `SharedPreferences` key `deck_config_data` |

The standalone routes are in
[`deckboard_daemon/backend/lib/dart_server_service.dart`](../deckboard_daemon/backend/lib/dart_server_service.dart#L59-L114).
The embedded route behavior is in
[`kdedeck_mobile/lib/services/dart_server_service.dart`](../kdedeck_mobile/lib/services/dart_server_service.dart#L62-L76).
Every WebSocket frame is expected to be one JSON object. Invalid JSON is
ignored without echoing or logging the frame; there is no structured error
response for malformed JSON.

### Standalone bind mode

The standalone daemon reads one optional top-level transport setting from the
validated configuration:

```json
{ "allow_lan": true, "boards": [] }
```

Only the JSON boolean `true` opts into the LAN bind (`anyIPv4`, normally
`0.0.0.0`). An omitted setting, `false`, or any invalid value fails closed to
the IPv4 loopback address (`127.0.0.1`). Arbitrary `bind_address` values are
not supported, and no WebSocket request can select a remote bind address.
Changes made through `save_config` take effect after the daemon restarts; the
current WebSocket protocol and endpoint remain unchanged. Startup logs report
only the selected loopback or LAN mode and address/port, never configuration
contents or credentials. Non-loopback listeners now require valid TLS.

Existing phone users connecting over a LAN must add `"allow_lan": true` to the
standalone `deckboard_config.json` top-level object, provide local certificate
and key paths via `KDEDECK_TLS_CERT_FILE` and `KDEDECK_TLS_KEY_FILE`, and restart
the daemon. Missing, incomplete, malformed, or mismatched TLS credentials stop
startup before a listener is opened. There is no plaintext LAN fallback.
Loopback remains HTTP/WS when neither TLS variable is set, or HTTPS/WSS when
both valid variables are supplied. Invalid explicit TLS never downgrades even
on loopback. Certificate paths are not board settings and are not sent to clients.

See [TLS setup](security/tls-setup.md). Certificate provisioning and client trust
on real devices are still required; Flutter currently only supports its legacy
plain WebSocket flow and needs a separate WSS/trust implementation.

## Connection lifecycle

1. A client upgrades `/ws`.
2. The server adds the socket to its in-memory client list and sends only
   `{ "type": "auth_required" }`. No config, metrics, pairing code, or other
   privileged state is sent at this point.
3. The client sends `authenticate` with either the one-time pairing code or a
   previously issued bearer token.
4. After successful authentication, the server sends `auth_success` followed
   by one `init_state` object. Authenticated clients can then send actions or
   config changes. The server broadcasts
   `config_updated` and `state_update` to all connected clients as applicable.
5. A disconnect removes the socket's in-memory auth association. Bearer
   sessions remain valid for reconnect until expiry or revocation. The Flutter
   client retries after four seconds, and the web configurator retries after a
   short delay and re-authenticates with its stored bearer token.

### Authentication messages

The initial challenge is intentionally minimal:

```json
{ "type": "auth_required" }
```

Pair with the local one-time code:

Start the standalone daemon in an interactive terminal with
`dart run bin/backend.dart --pair` (or `./kdedeck_daemon --pair`). Both stdin and
stdout must be terminals; redirects/pipes are refused before startup. Only after
successful startup is a new code displayed directly in that terminal. In the
same running terminal, type `pair` and Enter to issue a new code for another
device or after expiry. Each issuance invalidates the old code, not active tokens.
Normal startup creates no pairing code. No HTTP/WebSocket request issues or
reveals a code. The first paired device still receives `configAdmin` privileges.

The terminal is a sensitive local display: do not use terminal recording or share
screenshots of it. Background/tray mode has no pairing display yet; use this
foreground workflow and do not start a second daemon on an occupied port.

```json
{ "type": "authenticate", "pairing_code": "<pairing-code>" }
```

Reconnect with a token returned by a prior successful pairing:

```json
{ "type": "authenticate", "token": "<bearer-token>" }
```

On success the standalone server returns the bearer token, its assigned role,
and then `init_state`:

```json
{ "type": "auth_success", "token": "<bearer-token>", "role": "configAdmin" }
```

The token is a client credential and must be stored securely; it is never
logged by the server. Invalid credentials and authorization failures use a
bounded response without echoing credentials or request payloads:

```json
{ "type": "auth_error", "code": "invalid_credentials" }
```

The standalone daemon also limits failed `authenticate` frames per WebSocket
peer address. The default policy accepts five failed attempts, then returns
`{ "type": "auth_error", "code": "rate_limited" }` for that address for one
minute. The rate-limited response is bounded and never echoes a token, pairing
code, or request payload. A successful pairing or token authentication clears
that peer's failure state. The limiter applies only while a socket is not
authenticated; it does not interrupt existing authenticated sessions or their
normal action/configuration requests.

The standalone backend keeps bearer sessions in memory and bounds the active
session table as described below. Manager revocation immediately clears affected
standalone sockets and closes them with WebSocket code 1008 and a generic
`Session invalid` reason. Other valid sessions remain connected. Administrative
revocation UI is not implemented yet.

The standalone backend bounds the active
session table to 100 sessions by default. Expired sessions are removed
opportunistically and before a new pairing is issued. The session manager also
supports administrative revoke-all and revoke-by-role operations; these
operations return counts and never expose tokens. A pairing attempt at capacity
is rejected with the bounded `{ "type": "auth_error", "code":
"session_capacity" }` response without consuming the pairing code. Invalid
pairing codes and invalid bearer tokens continue to return the bounded
`invalid_credentials` response. Once an administrator revokes a session, the
retained pairing code can be used for a new session.

The standalone web configurator waits for `auth_required` before sending any
privileged request. It prompts for the one-time pairing code when no session is
available, then stores the returned bearer token under `kdedeck.authToken` in
browser `sessionStorage` and `localStorage` for reconnects. An invalid saved
token clears both storage entries and returns the UI to the pairing prompt.
Installed-app discovery begins only after `init_state` has been received, and
configuration saves remain gated on the authenticated WebSocket session.

For this first standalone-server slice, successful bootstrap pairing is always
assigned `configAdmin` for compatibility. Any caller-supplied role field is
ignored and cannot elevate itself. This is a deliberate bootstrap limitation,
not a general role-provisioning model; future pairing/provisioning work must
replace it with an explicit administrator workflow.

The role capabilities are:

| Request | Required capability |
|---|---|
| `trigger_action` | `control` |
| `save_config` | `configAdmin` |
| `get_system_apps` | `configAdmin` |

Unauthenticated or insufficiently privileged requests receive `auth_error` and
do not invoke command execution, configuration persistence, or app discovery.

### `init_state` (server -> client)

```json
{
  "type": "init_state",
  "protocol_version": 1,
  "capabilities": ["trigger_action", "save_config", "get_system_apps"],
  "session_capabilities": ["view", "control", "configAdmin"],
  "config": { "boards": [] },
  "pin_required": true,
  "state": {
    "volume": 50,
    "brightness": 70,
    "is_muted": false,
    "metrics": {
      "cpu_temp": 45,
      "cpu_load": 15,
      "gpu_temp": 50,
      "gpu_load": 20,
      "ram_used_gb": 8.0,
      "ram_total_gb": 16.0,
      "ram_percent": 50
    }
  }
}
```

`protocol_version` is a stable integer for the standalone wire protocol.
`capabilities` is a bounded list of supported protocol operation names. These
fields are advertisement only: clients may observe them, but this slice adds no
version negotiation, capability negotiation, or compatibility enforcement.
`session_capabilities` is the bounded list of authorization capabilities granted
to the authenticated session; it is derived from the server's existing role
permissions and does not grant permissions by itself.

`pin_required` is retained as a legacy compatibility flag and is now `true` for
authenticated standalone-server sessions. The actual protocol authentication is
the `authenticate` exchange above; client PIN fields alone are not proof of
identity.

## Client -> server messages

### `trigger_action`

```json
{
  "type": "trigger_action",
  "action": "mpris_action",
  "payload": "play-pause",
  "value": null,
  "item_id": "item_123"
}
```

`action` defaults to an empty string, `payload` is converted to a string (or
empty), and `value` is passed through. `item_id` is accepted from Flutter but
currently ignored by both servers. There is no acknowledgement or action
result message.

Current action names and payloads:

| Action | Payload/value | Standalone daemon | Embedded Flutter server |
|---|---|---|---|
| `launch_app` | shell/command string | `SystemActionsService.executeLaunch` | Linux `LinuxActionsService.executeLaunch` only |
| `open_url` | `http://` or `https://` URL | `xdg-open`; Windows `cmd`; macOS `open` | Linux implementation only due to server gate |
| `audio_volume` | numeric `value`, clamped 0-100 | `pactl`, then `amixer` | Linux `pactl`, then `amixer` |
| `audio_mute_toggle` | none | `pactl`, then `amixer` | Linux `pactl`, then `amixer` |
| `brightness` | numeric `value`, clamped 5-100 | sysfs, `brightnessctl`, `xrandr` | same Linux sequence |
| `mpris_action` | `play-pause`, `next`, `previous`, `stop`, `play`, `pause`, `volume_up`, `volume_down`, `mute` | D-Bus MPRIS enumeration; volume/mute use audio helpers | `playerctl` for payload; `mute` uses audio helper |
| `kde_action` | `sleep`, `shutdown`, `lock`, `logout`, or command | Linux `systemctl`/`qdbus`, otherwise shell command | Linux delegates payload to launch helper |

The web UI also exposes `clock_widget`. It is rendered locally by the web and
Flutter deck views and has no corresponding server-side action; unknown action
names are silently ignored by the dispatch switch.

The standalone dispatch is
[`dart_server_service.dart`](../deckboard_daemon/backend/lib/dart_server_service.dart#L250-L305).
The embedded dispatch refuses all actions when `Platform.isLinux` is false and
is therefore not a Windows/macOS system-control implementation
([`services/dart_server_service.dart`](../kdedeck_mobile/lib/services/dart_server_service.dart#L171-L231)).

### `save_config`

```json
{
  "type": "save_config",
  "config": {
    "config_schema_version": 1,
    "boards": [
      {
        "id": "board_default",
        "title": "Main Deck",
        "grid_columns": 5,
        "grid_rows": 3,
        "items": []
      }
    ]
  }
}
```

The standalone server accepts a strict JSON map with a top-level `boards` list.
`config_schema_version` is optional for legacy clients; omitted values are
normalized to the current version, `1`. Other versions are rejected with the
bounded `unsupported_config_version` validation result. This marker is a
compatibility boundary, not a migration engine; existing user files are not
rewritten merely because they omit it.
Boards require non-empty unique `id` values and an `items` list; grid dimensions
and item spans/coordinates must be positive integers within the board. Item
fields commonly include `id`, `title`, `type`, `action`, `payload`, `icon`,
`span_cols`, `span_rows`, `grid_x`, and `grid_y`. Optional UI fields include
`icon_base64` data URLs and `system_icon_path` references. Existing desktop-app
payloads, slider types/spans, and safe actions (`launch_app`, `open_url`, audio,
`mpris_action`, `kde_action`, and `clock_widget`) remain supported.

The validator also bounds board/item counts, IDs, titles, payloads, icon data,
nesting, and serialized size; rejects non-finite/fractional values, malformed
maps/lists, duplicate IDs, unsafe URLs/launch syntax, and unknown action names.
Rejected saves return only `{ "type": "config_error", "code":
"invalid_config" }`; the submitted config is never echoed. On the standalone
server, validation completes before active state changes. Valid writes go to a
temporary file and atomically replace `deckboard_config.json`; the prior valid
file is retained as the bounded `deckboard_config.json.bak`. Startup validates
the primary, then the backup, and otherwise uses the safe default. A failed or
invalid save leaves the active config unchanged. The embedded server remains a
separate implementation and is not changed by this step. See
[`dart_server_service.dart`](../deckboard_daemon/backend/lib/dart_server_service.dart#L177-L187),
[`dart_server_service.dart`](../deckboard_daemon/backend/lib/dart_server_service.dart#L196-L225),
and [`services/dart_server_service.dart`](../kdedeck_mobile/lib/services/dart_server_service.dart#L140-L150).

### `get_system_apps`

```json
{ "type": "get_system_apps" }
```

Only the standalone daemon implements this request. It replies to the
requesting socket with `system_apps_list`:

```json
{
  "type": "system_apps_list",
  "apps": [
    { "name": "Example", "payload": "example", "icon": "example", "system_icon_path": "/..." }
  ]
}
```

On Linux, apps come from `.desktop` entries under system, user, and Flatpak
directories, with Snap entries added when `snap list` succeeds. Windows and
macOS branches are TODO. The web editor requests this after authenticated
`init_state` and when opening an item editor
([`app.js`](../deckboard_daemon/frontend/app.js#L196),
[`app.js`](../deckboard_daemon/frontend/app.js#L920-L927)).

### Messages currently sent but not implemented by the server

`WebSocketService.toggleMetricsEnabled` sends:

```json
{ "type": "set_metrics_enabled", "enabled": true }
```

Neither Dart server handles it. The client can parse `state_poll`, but neither
server currently sends it. These are compatibility remnants, not available
request/response features ([`websocket_service.dart`](../kdedeck_mobile/lib/services/websocket_service.dart#L249-L264),
[`websocket_service.dart`](../kdedeck_mobile/lib/services/websocket_service.dart#L201-L217)).

## Server -> client messages

### `config_updated`

```json
{ "type": "config_updated", "config": { "boards": [] } }
```

This is broadcast after a successful `save_config` handling path. The web and
Flutter clients replace their current config with the supplied map.

### `state_update`

```json
{ "type": "state_update", "key": "volume", "value": 60 }
```

Current keys are `volume`, `brightness`, and `is_muted`. The Flutter client
also accepts `muted` as an alias. Successful action dispatch broadcasts state
after the command succeeds, while the four-second Linux poll broadcasts changes
observed from `pactl` or backlight sysfs. There is no timestamp, source,
revision, or operation ID.

### `action_result`

```json
{ "type": "action_result", "action": "audio_volume", "success": true }
```

The authenticated action's command completed successfully. State-changing
actions emit their `state_update` before this result.

### `action_error`

```json
{ "type": "action_error", "action": "audio_volume", "code": "action_failed" }
```

The action was invalid, unsupported, threw an executor failure, or returned a
nonzero exit status. The server intentionally does not disclose command lines,
paths, payloads, or exception text. The failed action does not mutate state.

### `system_apps_list`

Described above. It is a response to `get_system_apps`, not a broadcast.

### Accepted but not currently emitted

The web UI has compatibility handling for `config_sync`, and Flutter has
handling for `state_poll`; no current server code emits either. A future
protocol revision should either remove these paths or define them explicitly
with a versioned schema.

## Icon HTTP route

The standalone server accepts `GET /system_icons?path=<filesystem path>`. If
the path exists, it streams PNG, SVG, or XPM content with a matching content
type and a one-day cache header; missing paths return 404. Flutter constructs
this URL from `system_icon_path` for remote icon rendering
([`neumorphic_deck.dart`](../kdedeck_mobile/lib/ui/neumorphic_deck.dart#L396-L408)).

This route is currently unauthenticated and does not constrain the path to an
icon directory. Treat it as a local-trusted-network development feature, not
a safe public HTTP file server.

## Compatibility and future boundary

The existing action names and config keys should remain stable for Linux
clients. A future protocol should add, rather than silently reinterpret,
capability discovery, request IDs, config revision/conflict handling, and
optional authentication. Windows/macOS action implementations should sit behind
platform adapters while retaining the same
logical actions where semantics match. Linux D-Bus, PulseAudio/PipeWire,
sysfs, `/proc`, desktop-entry, Flatpak, Snap, and icon behavior is the baseline
to preserve.
