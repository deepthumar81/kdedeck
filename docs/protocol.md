# KDE Deck protocol (current state)

This is the protocol actually implemented by the standalone Dart server on
`main`. It is JSON-over-WebSocket with no version or negotiated subprotocol.
The standalone server requires authentication before sending state or handling
control/configuration requests. The Flutter embedded server remains a separate
implementation and is not changed by this step.

## Transport and endpoints

| Endpoint | Standalone daemon | Flutter desktop embedded server |
|---|---|---|
| Bind | `0.0.0.0:8484` (`anyIPv4`) | `0.0.0.0:8484` (`anyIPv4`) |
| WebSocket | `ws://host:8484/ws` | `ws://host:8484/ws` |
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
   sessions remain valid for reconnect until expiry or revocation. The Flutter client retries after four
   seconds; the web configurator does not automatically reconnect.

### Authentication messages

The initial challenge is intentionally minimal:

```json
{ "type": "auth_required" }
```

Pair with the local one-time code:

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

The config is a free-form JSON map in transit. The common logical schema is a
top-level `boards` array; board fields are `id`, `title`, `grid_columns`,
`grid_rows`, and `items`; item fields commonly include `id`, `title`, `type`,
`action`, `payload`, `icon`, `span_cols`, `span_rows`, `grid_x`, and `grid_y`.
Optional UI fields include `icon_base64` and `system_icon_path`.

On the standalone server, `_validateConfig` forces volume/brightness sliders
to `1x4`, clamps spans to the board, clamps coordinates, writes the JSON file,
then broadcasts `config_updated`. On the embedded server, the map is written
to preferences and broadcast without that validator. See
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
macOS branches are TODO. The web editor requests this at connection and when
opening an item editor ([`app.js`](../deckboard_daemon/frontend/app.js#L19-L24),
[`app.js`](../deckboard_daemon/frontend/app.js#L750-L752)).

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
also accepts `muted` as an alias. Action dispatch broadcasts optimistic state
after clamping, while the four-second Linux poll broadcasts changes observed
from `pactl` or backlight sysfs. There is no timestamp, source, revision, or
operation ID.

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
capability discovery, request IDs, explicit action results/errors, config
revision/conflict handling, and optional authentication. Windows/macOS action
implementations should sit behind platform adapters while retaining the same
logical actions where semantics match. Linux D-Bus, PulseAudio/PipeWire,
sysfs, `/proc`, desktop-entry, Flatpak, Snap, and icon behavior is the baseline
to preserve.
