# KdeDeck - Project Roadmap & Plan 🗺️

**Current Version**: `v1.1.0`  
**License**: MIT  
**Target Platform**: Linux (KDE Plasma 6 on Wayland & X11)

---

## 🎯 Active Features List (v1.1.0)

* 📱 **PWA Mobile Experience**: Native "Add to Home Screen" support on Android & iOS with touch haptic feedback (`navigator.vibrate`).
* 🎨 **iOS 18 & One UI 9 Aesthetics**: Squircle square button grid (`aspect-ratio: 1 / 1`), rectangle slider cards, smooth glassmorphism, vibrant theme modes (*Light*, *Breeze Dark*, *iOS 18 / One UI 9 Colorful*).
* 👈👉 **Carousel & Multi-Board Swipe Navigation**: Unlimited deck pages. Supports touch swipe on phone, carousel `<` `>` buttons on desktop, mouse drag-swipe, and keyboard Left/Right arrow keys.
* 💾 **Import & Export Settings**: 1-Click JSON export (`kdedeck-config.json`) and configuration import tool to easily migrate settings across computers.
* ✏️ **Board Renaming & Management**: Full board renaming capability, "+ Button" addition, "+ Board" creation, and item deletion.
* 📦 **Universal Linux App Scanner**: Scans Debian/APT (`/usr/share/applications`), Flatpak (`/var/lib/flatpak/exports`), and Snap (`/var/lib/snapd/desktop`) desktop entries.
* 🖼️ **Native Desktop App Icons**: Exposes `/api/icon/<name>` endpoint to render high-resolution PNG/SVG icons directly from system icon themes.
* 🔐 **Security PIN Authorization**: 4-Digit Security PIN (Default: `8484`) and session token verification.
* 🪟 **Active KWin Taskbar Board**: Dynamic board page querying running windows on KDE Plasma 6 Wayland via KWin D-Bus scripting.
* 🎵 **MPRIS & KDE Connect Integration**: Media controls (Spotify/VLC/Browser) and KDE Connect actions (Find Phone, Battery meter, Clipboard sync).

---

## 🚫 Cancelled / Deprecated Features

* ❌ **`ddcutil` Hardware I2C Polling**: 
  - *Reason for Cancellation*: `ddcutil` communicates synchronously over hardware I2C bus with external monitors, taking 500ms–2000ms per poll. This caused KDE Plasma GPU frame drops and system-wide lag every 5 seconds.
  - *Replacement*: Brightness control now uses non-blocking `brightnessctl` and `/sys/class/backlight` without I2C polling overhead.

---

## 🔮 Upcoming Roadmap (v1.2.0+)

- [ ] **Custom Icon File Upload**: Upload local PNG/SVG icon images for custom buttons.
- [ ] **OBS Studio Scene Switcher Plugin**: Built-in OBS WebSocket plugin tab with live scene preview.
- [ ] **System Hardware Monitoring Widget**: Real-time CPU, RAM, and GPU temperature touch tiles.
- [ ] **Custom Hotkey Sequence Recording**: Record multi-key hotkey combos (e.g. `Ctrl + Alt + Shift + T`).
