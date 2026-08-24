# KdeDeck 🚀

**KdeDeck** is a ultra-lightweight, open-source Stream Deck / Macro Pad server and Progressive Web App (PWA) designed specifically for **Linux (KDE Plasma 6 on Wayland & X11)**.

Built as a high-performance alternative to Electron-based macro pads, **KdeDeck consumes ~14MB of RAM** (compared to 400MB+ in traditional Electron apps) while offering deep integration with KDE Plasma, Wayland, MPRIS D-Bus, and KDE Connect.

---

## Features ✨

* 📱 **PWA Mobile Support**: No APK installation needed! Open `http://<YOUR_PC_IP>:8484` on your Android or iOS device, tap **"Add to Home Screen"**, and launch as a fullscreen app with low-latency touch controls and vibration haptics (`navigator.vibrate`).
* 👈👉 **Multi-Board Swipe Navigation**: Create unlimited boards (e.g., *System & Audio*, *Media & Browser*, *KDE Connect*, *Active Taskbar*). Swipe left/right on your phone screen to switch between boards.
* ⚡ **Ultra-Low Memory Footprint**: Runs on a Python asynchronous backend (`aiohttp`) consuming **~14MB RAM** in the background.
* 🎚️ **Interactive Touch Sliders**: Smooth real-time touch sliders for per-monitor brightness (`ddcutil` / `brightnessctl`) and system/application sound volume (`pactl`).
* 🖼️ **Live KWin Taskbar Switcher**: Dynamic board page that streams running KDE application windows in real time. Tapping an app tile focuses that window instantly on Wayland.
* 📲 **KDE Connect Integration**: Native deck actions to find/ring your phone 🔔, check battery status 🔋, and sync clipboard 📋.
* 🎵 **MPRIS Media Controls**: Play, pause, skip tracks, and display metadata for Spotify, VLC, Firefox, Chrome, etc.
* 🎨 **Rich UI & Themes**: Glassmorphism design with preset themes (*KDE Breeze Dark*, *Cyberpunk Neon*, *OLED Black*, *Sunset Gradient*) and 1,000+ vector icons.
* 🛠️ **Visual Board Editor**: Customize buttons, icons, colors, actions, and layouts directly from your PC browser.

---

## Quick Start 🛠️

### 1. Start KdeDeck Server
```bash
./kdedeck/cli/kdedeck start
```

### 2. Check Status & Memory Usage
```bash
./kdedeck/cli/kdedeck status
```

### 3. Open Deck on Mobile Device
Open `http://<YOUR_PC_IP>:8484` in Chrome or Firefox on your phone, then tap **"Add to Home Screen"**.

### 4. Enable Launch on KDE Boot (Autostart)
```bash
./kdedeck/cli/kdedeck enable-autostart
```

---

## Project Architecture

```
kdedeck/
├── server/               # Asynchronous Python Backend (~14MB RAM)
│   ├── main.py           # Web & WebSocket Server
│   ├── config_manager.py # JSON Configuration & Multi-Board Storage
│   └── plugins/          # Action Handlers (PulseAudio, D-Bus, KWin, MPRIS, KDE Connect)
├── web/                  # Progressive Web App (PWA)
│   ├── index.html        # Mobile & Desktop Single Page App
│   ├── css/style.css     # Glassmorphism & Theme Engine
│   ├── js/app.js         # WebSocket, Touch Swipe & Editor Logic
│   └── js/icons.js       # Vector Icon Dataset
└── cli/
    └── kdedeck           # CLI Service Management Script
```

---

## License 📜

Distributed under the MIT License.
