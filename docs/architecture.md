# KDE Deck architecture (current state)

This document describes the implementation on `main`, not the intended end
state. The product is currently Linux-first: the README names KDE Plasma 6 on
Wayland/X11 as the target, while Windows and macOS are extension points rather
than supported system-control backends ([`README.md`](../README.md#L1-L5),
[`ROADMAP.md`](../ROADMAP.md#L1-L6)).

## System shape

KDE Deck has four practical parts:

1. **Standalone Dart daemon** in `deckboard_daemon/backend`. It owns the
   WebSocket protocol, serves the local web configurator and icon files, reads
   and writes `deckboard_config.json`, and invokes host commands.
2. **Flutter client** in `kdedeck_mobile`. Android/iOS builds are remote
   clients. Linux/macOS/Windows builds are desktop Flutter applications and
   start an embedded Dart server before showing the desktop configurator.
3. **Web configurator** in `deckboard_daemon/frontend`. It is static HTML/CSS/
   JavaScript served by the standalone daemon and edits the same JSON config
   through WebSocket messages.
4. **Go tray wrapper** in `deckboard_daemon/tray`. It provides a system-tray
   menu, starts the standalone Dart process, opens `http://localhost:8484`, and
   kills the child process on exit.

The repository therefore has two related server implementations. The
standalone implementation and the embedded Flutter implementation share the
wire message names, but they do not have identical HTTP routes, persistence,
validation, or Linux action behavior. Do not assume that changing one changes
the other.

## Runtime topologies

### Linux PC plus phone

```text
Go tray (optional)
       |
       +--> standalone Dart daemon :8484
                    |-- HTTP: web configurator and /system_icons
                    |-- WebSocket: /ws
                    |-- Linux commands, D-Bus, sysfs, /proc
                    +<-- Wi-Fi/LAN --> Flutter Android/iOS client
```

The phone stores connection profiles in `SharedPreferences`, connects to
`ws://<host>:8484/ws`, receives `init_state`, renders board maps, and sends
actions or configuration changes. Connection retry is a four-second timer in
[`websocket_service.dart`](../kdedeck_mobile/lib/services/websocket_service.dart#L163-L177).

### Standalone daemon plus browser

The daemon binds `InternetAddress.anyIPv4` on port `8484` and routes `/ws` to
WebSocket upgrade, `/` and other paths to `../frontend`, and
`/system_icons` to a file response ([`dart_server_service.dart`](../deckboard_daemon/backend/lib/dart_server_service.dart#L49-L114)).
The browser opens one WebSocket, requests installed apps, edits an in-memory
copy, and sends `save_config` ([`app.js`](../deckboard_daemon/frontend/app.js#L1-L95)).

### Flutter desktop

`main.dart` starts `kdedeck_mobile/lib/services/dart_server_service.dart` on
Linux, macOS, and Windows, then displays `DesktopConfiguratorScreen`
([`main.dart`](../kdedeck_mobile/lib/main.dart#L13-L35),
[`main.dart`](../kdedeck_mobile/lib/main.dart#L45-L65)). The desktop
`WebSocketService` connects to `127.0.0.1:8484`, so the embedded server is
normally its own client/server pair. This embedded server returns a 404-style
text response for every HTTP path other than `/ws`; it does not serve the web
frontend or `/system_icons` ([`services/dart_server_service.dart`](../kdedeck_mobile/lib/services/dart_server_service.dart#L51-L82)).

Running the standalone daemon and the Flutter desktop application at the same
time will generally cause a port bind conflict; the code does not negotiate a
different port.

## Component responsibilities

### Standalone Dart backend

- `bin/backend.dart` constructs the singleton `DartServerService`, installs
  SIGINT/SIGTERM shutdown handlers, starts the server, and keeps the process
  alive ([`bin/backend.dart`](../deckboard_daemon/backend/bin/backend.dart#L5-L28)).
- `lib/dart_server_service.dart` owns clients, initial state, action dispatch,
  config persistence/validation, system-app lookup, metrics polling, and
  broadcasting.
- `lib/system_actions_service.dart` is the current host integration layer. It
  executes Linux audio, brightness, MPRIS/KDE actions and scans Linux desktop
  entries/icons. It contains explicit Windows/macOS branches for launch/open
  URL, plus TODO branches for volume, mute, brightness, media, and app
  discovery ([`system_actions_service.dart`](../deckboard_daemon/backend/lib/system_actions_service.dart#L44-L74),
  [`system_actions_service.dart`](../deckboard_daemon/backend/lib/system_actions_service.dart#L78-L133),
  [`system_actions_service.dart`](../deckboard_daemon/backend/lib/system_actions_service.dart#L135-L185),
  [`system_actions_service.dart`](../deckboard_daemon/backend/lib/system_actions_service.dart#L213-L274)).

### Flutter client and desktop configurator

- `WebSocketService` is the transport/state adapter. It uses raw
  `Map<String,dynamic>` config data, exposes volume, brightness, mute and
  metrics state, reconnects, and persists client settings in
  `SharedPreferences` ([`websocket_service.dart`](../kdedeck_mobile/lib/services/websocket_service.dart#L8-L80)).
- `NeumorphicDeckScreen` renders multiple boards with `DynamicMatrixGrid`,
  sends `trigger_action`, and can send layout changes as `save_config`
  ([`neumorphic_deck.dart`](../kdedeck_mobile/lib/ui/neumorphic_deck.dart#L31-L113)).
- `DesktopConfiguratorScreen` edits a draft map and sends it on Save & Apply
  ([`desktop_configurator.dart`](../kdedeck_mobile/lib/ui/desktop_configurator.dart#L33-L52),
  [`desktop_configurator.dart`](../kdedeck_mobile/lib/ui/desktop_configurator.dart#L179-L201)).
- `DynamicMatrixGrid` calculates spans and auto-places invalid/missing
  coordinates at render time ([`dynamic_matrix_grid.dart`](../kdedeck_mobile/lib/ui/dynamic_matrix_grid.dart#L35-L100)).
- `BoardModel` and `DeckItemModel` define typed helpers, but current screens
  use raw maps and these models have no call sites outside their own files.
  The models also omit several persisted fields (`grid_x`, `grid_y`,
  `icon_base64`, `system_icon_path`), so they are not a lossless config model
  ([`board_model.dart`](../kdedeck_mobile/lib/models/board_model.dart#L19-L37),
  [`deck_item_model.dart`](../kdedeck_mobile/lib/models/deck_item_model.dart#L23-L47)).

### Web frontend

The browser configurator maintains `configData` locally, supports board/grid
editing, drag/drop and item editing, and sends the complete config on each
auto-save. It requests `get_system_apps` at connection and editor-open time
([`app.js`](../deckboard_daemon/frontend/app.js#L19-L49),
[`app.js`](../deckboard_daemon/frontend/app.js#L750-L883)). It can also store
custom image data as a base64 data URL in an item. The server does not enforce
an image size or schema limit; the browser UI limits uploads to 5 MiB
([`app.js`](../deckboard_daemon/frontend/app.js#L632-L657)).
The available item types and action selectors are declared in
[`index.html`](../deckboard_daemon/frontend/index.html#L86-L186); the web
frontend's `clock_widget` is rendered locally and is not a host action.

### Go tray

`main.go` uses `github.com/getlantern/systray`, starts
`kdedeck_daemon` when present (otherwise `dart run bin/backend.dart`), and
opens the dashboard using `xdg-open`, `rundll32`, or `open` by `runtime.GOOS`
([`main.go`](../deckboard_daemon/tray/main.go#L14-L83),
[`main.go`](../deckboard_daemon/tray/main.go#L85-L100)). The tray does not
implement protocol or system actions; it is a lifecycle/launcher extension
point for all three desktop operating systems.

## Configuration flow

The shared logical shape is:

```json
{
  "boards": [
    {
      "id": "board_default",
      "title": "Main Deck",
      "grid_columns": 5,
      "grid_rows": 3,
      "items": [
        {
          "id": "btn_1",
          "title": "Terminal",
          "type": "button",
          "action": "launch_app",
          "payload": "konsole || gnome-terminal || xterm",
          "icon": "terminal",
          "span_cols": 1,
          "span_rows": 1,
          "grid_x": 0,
          "grid_y": 0
        }
      ]
    }
  ]
}
```

The server default and the checked-in example are in
[`dart_server_service.dart`](../deckboard_daemon/backend/lib/dart_server_service.dart#L434-L478)
and [`deckboard_config.json`](../deckboard_daemon/backend/deckboard_config.json).
Items may additionally contain `icon_base64`, `system_icon_path`, and other
forward-compatible keys. `type` is normally `button`, `volume_slider`, or
`brightness_slider`; action names are described in
[`protocol.md`](protocol.md).

On standalone startup, the daemon reads `deckboard_config.json` relative to
its working directory and falls back to a default on missing/invalid data. A
standalone `save_config` validates slider spans and clamps item spans/positions
to board bounds before writing the file and broadcasting `config_updated`
([`dart_server_service.dart`](../deckboard_daemon/backend/lib/dart_server_service.dart#L196-L225),
[`dart_server_service.dart`](../deckboard_daemon/backend/lib/dart_server_service.dart#L407-L432)).
The embedded Flutter server instead stores JSON under the
`deck_config_data` `SharedPreferences` key and currently does not run the
standalone validator ([`services/dart_server_service.dart`](../kdedeck_mobile/lib/services/dart_server_service.dart#L130-L150),
[`services/dart_server_service.dart`](../kdedeck_mobile/lib/services/dart_server_service.dart#L334-L355)).

## Linux capabilities to preserve

Linux is the compatibility baseline and must remain functional while adding
other operating systems:

- Launch/open URL via `xdg-open` or a shell command, with `DISPLAY=:0` in the
  standalone service.
- Volume and mute via PulseAudio/PipeWire `pactl`, falling back to `amixer`.
- Brightness via `/sys/class/backlight`, then `brightnessctl`, then
  `xrandr --brightness`.
- MPRIS playback and volume controls via D-Bus (`dbus-send`) in the standalone
  daemon; the embedded Flutter server delegates to `playerctl`.
- KDE sleep/shutdown/lock/logout through `systemctl` and `qdbus` in the
  standalone daemon.
- App discovery from `.desktop` files, Flatpak exports, and Snap; icon lookup
  from Linux icon directories; icon delivery through `/system_icons`.
- RAM metrics from `/proc/meminfo`, plus four-second polling of audio and
  backlight state.

These behaviors are implemented in
[`system_actions_service.dart`](../deckboard_daemon/backend/lib/system_actions_service.dart)
and the embedded Linux-only equivalent
[`linux_actions_service.dart`](../kdedeck_mobile/lib/services/linux_actions_service.dart).

## Current limitations and risks

- There is no authentication or transport encryption. The server binds all
  IPv4 interfaces, always sends `"pin_required": false`, and the client-side
  PIN is only stored/displayed configuration; it is never checked
  ([`dart_server_service.dart`](../deckboard_daemon/backend/lib/dart_server_service.dart#L140-L151),
  [`websocket_service.dart`](../kdedeck_mobile/lib/services/websocket_service.dart#L8-L18)).
- `launch_app`, custom KDE actions, and `/system_icons?path=` can expose or
  execute powerful host operations. The icon route accepts a caller-provided
  filesystem path and has no allowlist.
- Action state is optimistic: volume, brightness, and mute state are updated
  and broadcast without checking the result returned by the host action.
- Metrics defaults include CPU/GPU values, but the current polling code only
  refreshes RAM; CPU/GPU values are not collected. Metrics changes are not
  broadcast as their own message, so connected clients primarily see them at
  `init_state`.
- The client sends `set_metrics_enabled`, but neither server implementation
  handles it. `state_poll` is parsed by the client but has no current server
  producer. The web UI accepts `config_sync`, but the server sends
  `init_state`/`config_updated` instead.
- Standalone and embedded servers differ in config validation, persistence,
  app discovery, icon HTTP serving, KDE actions, and MPRIS implementation.
- The baseline backend test still tests the generated `calculate()` sample
  function ([`backend_test.dart`](../deckboard_daemon/backend/test/backend_test.dart#L1-L8));
  there are no protocol or integration tests.

## Future boundary design

The next architectural boundary should preserve the current wire format while
separating transport/core policy from host integration:

```text
WebSocket + HTTP adapters
          |
          v
Protocol/core (config, action names, state, validation, errors)
          |
          v
SystemActionsPort
   | LinuxActionsPort (existing behavior, unchanged baseline)
   | WindowsActionsPort (Start menu, media/audio/display APIs)
   ` macOSActionsPort (Applications, media/audio/display APIs)
```

The standalone and embedded servers should eventually share the protocol/core
implementation instead of maintaining two copies. Platform adapters should
return explicit success/failure and capability information, while clients keep
the same action names and config shape. Windows/macOS work should be added
behind those adapters and corresponding tray launch paths; it must not remove
or weaken the existing Linux D-Bus, sysfs, `/proc`, desktop-entry, Flatpak,
Snap, or icon behavior.
