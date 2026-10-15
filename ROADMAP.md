# KDE Deck - Project Roadmap & Plan 🗺️

**Current Version**: `main` after `v3.5.0` (Linux-first hardened development line)
**License**: MIT  
**Target Platform**: Linux (KDE Plasma on Wayland & X11)  
*Future Platforms: Windows & macOS*

---

## 🎯 Active Features (current development line)

* 📱 **Native Mobile Experience**: Android (and iOS-ready) Flutter app with Neumorphic UI, touch haptic feedback, and dynamic layout scaling.
* ⚡ **Ultra-Low Memory Footprint**: Runs on a compiled Ahead-Of-Time (AOT) Dart daemon backend consuming extremely minimal RAM.
* 👈👉 **Multi-Board Swipe Navigation**: Unlimited deck pages. Supports touch swipe on phone to switch between functional boards.
* 📦 **Linux App Scanner**: Scans Debian/APT, Flatpak, and Snap desktop entries natively, with approved application identities for launches.
* 🖼️ **Native Desktop App Icons**: Directly parses and streams high-resolution PNG/SVG icons from Linux system icon themes.
* 🎵 **MPRIS Integration**: Universal media controls (Spotify/VLC/Browser) natively executed via D-Bus (`org.mpris.MediaPlayer2`).
* 🖥️ **Web UI Configurator**: Authenticated drag & drop configuration panel served by the daemon on port `8484`.
* 🔐 **Hardened Transport**: Pairing, bearer sessions, revocation, request limits, loopback-safe defaults, and TLS/WSS for LAN access.

---

## 🚫 Cancelled / Deprecated Features

* ❌ **Python / aiohttp Backend**: 
  - *Reason for Cancellation*: High memory usage and complex virtual environment management. Completely replaced by the standalone Dart daemon.
* ❌ **`ddcutil` Hardware I2C Polling**: 
  - *Reason for Cancellation*: Synchronous polling caused KDE Plasma GPU frame drops. Replaced with non-blocking local sysfs scaling.

---

## 🔮 Upcoming Roadmap

- [ ] **Desktop/LAN readiness**: Complete embedded/standalone server convergence, certificate trust provisioning, physical-device QA, and desktop startup reliability.
- [ ] **Release engineering**: Add CI, packaging, clean-install/upgrade tests, signed artifacts, migrations, rollback, and synchronized release metadata.
- [ ] **Windows & macOS adapters**: Implement tested volume, mute, brightness, media, application discovery, launching, and capability reporting.
- [ ] **Client UX**: Improve onboarding, connection profiles, accessibility, drag/drop, undo, and unsupported-feature messaging.
- [ ] **Custom Icon File Upload**: Keep bounded PNG/SVG upload and validation available through the Web UI.
- [ ] **OBS Studio Scene Switcher Plugin**: Add only after the security and UX baseline is accepted.
- [ ] **System Hardware Monitoring**: Replace placeholder metrics with verified native measurements before exposing them as controls.
