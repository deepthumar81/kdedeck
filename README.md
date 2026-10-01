# KDE Deck

**Turn an old Android phone into a Stream Deck for Linux. $0.**

KDE Deck is an open-source macro pad / deck controller for **Linux (KDE Plasma 6, Wayland & X11)**. Instead of paying Elgato money, you run a lightweight server on your PC and drive it from your phone: launch apps, control media, slide volume and brightness, ring your phone, manage windows — a full remote for your Linux box, built from scratch.

![Demo video](assets/demo.mp4)

*One tap on the phone opens YouTube on the monitor, media buttons drive playback and volume, and the last tap opens system settings.*

---

## Screenshots

| Phone deck | Board configurator | Volume & brightness sliders |
|---|---|---|
| ![KDE Deck phone app](assets/app-board.png) | ![Deckboard Configurator](assets/configurator.png) | ![Touch sliders](assets/sliders.png) |

---

## Features

- 📱 **Two clients, your choice** — a native **Flutter Android app** with a connection manager, or a **Progressive Web App**: open `http://<YOUR_PC_IP>:8484` on any phone, tap "Add to Home Screen", done.
- 🖼️ **Real app icons, zero setup** — a universal Linux app scanner reads your installed apps (deb/APT, Flatpak, Snap desktop entries) and the server renders their actual system icons. No manual icon hunting, no broken images.
- 👈👉 **Multi-board swipe navigation** — unlimited boards (System & Audio, Media & Browser, KDE Connect…), swipe between them on the phone.
- 🎚️ **Touch sliders** — per-monitor brightness and system/app volume with real-time feedback.
- 🪟 **Live KWin taskbar** — streams your running KDE windows; tap a tile to focus it instantly on Wayland.
- 📲 **KDE Connect actions** — find/ring your phone, battery status, clipboard sync.
- 🎵 **MPRIS media controls** — play, pause, skip, and metadata for Spotify, VLC, browsers, everything MPRIS-speaking.
- 🛠️ **Visual board configurator** — design buttons, icons, sliders, and layouts from your PC browser; changes sync to the phone live.
- 🔐 **PIN authorization** — 4-digit PIN + session tokens so only your devices can drive your PC.
- ⚡ **Lightweight** — the Python backend idles at ~14MB RAM. No Electron, no bloat.
- 🎨 **Themes** — Breeze Dark, Cyberpunk Neon, OLED Black, Sunset Gradient, and more.

---

## How it's built

```
kdedeck/
├── server/            # Python asyncio backend (aiohttp + WebSockets)
│   ├── main.py        # Web & WebSocket server
│   ├── app_scanner.py # Scans deb / Flatpak / Snap desktop entries
│   ├── config_manager.py
│   └── plugins/       # Action handlers: audio, brightness, D-Bus,
│                      # KWin, MPRIS media, KDE Connect
├── web/               # Progressive Web App client
├── pc_gui/            # Visual board configurator (configurator.py)
├── cli/               # Service management (kdedeck start/status/…)
kdedeck_mobile/        # Native Flutter Android app
│   └── lib/           # WebSocket client, connection manager, board UI
deckboard_daemon/      # Headless Dart WebSocket backend + tray
```

Three ways to drive your PC, one protocol: the Python server is the brain (plugins do the real work over D-Bus, PulseAudio/PipeWire, and KWin scripting), the Flutter app and the PWA are the hands, and the configurator is where you lay out the buttons.

---

## Quick start

### 1. Start the server

```bash
./kdedeck/cli/kdedeck start
```

### 2. Check status

```bash
./kdedeck/cli/kdedeck status
```

### 3. Open the deck on your phone

Open `http://<YOUR_PC_IP>:8484` in Chrome/Firefox and tap **"Add to Home Screen"** — or install the Flutter app from `kdedeck_mobile/`.

### 4. Design your boards

Open `http://localhost:8484` on your PC for the visual configurator, then arrange buttons however you like. Changes appear on the phone instantly.

### 5. Launch on boot (optional)

```bash
./kdedeck/cli/kdedeck enable-autostart
```

---

## Roadmap

See [ROADMAP.md](ROADMAP.md) for what's planned and what's deliberately cut (e.g. why `ddcutil` I2C polling was removed).

---

## License

MIT — do whatever you want with it.
