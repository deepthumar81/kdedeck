# KDE Deck - Project Roadmap & Plan 🗺️

**Current Version**: `v2.0.0` (Dart/Flutter Architecture)  
**License**: MIT  
**Target Platform**: Linux (KDE Plasma on Wayland & X11)  
*Future Platforms: Windows & macOS*

---

## 🎯 Active Features List (v2.0.0)

* 📱 **Native Mobile Experience**: Android (and iOS-ready) Flutter app with Neumorphic UI, touch haptic feedback, and dynamic layout scaling.
* ⚡ **Ultra-Low Memory Footprint**: Runs on a compiled Ahead-Of-Time (AOT) Dart daemon backend consuming extremely minimal RAM.
* 👈👉 **Multi-Board Swipe Navigation**: Unlimited deck pages. Supports touch swipe on phone to switch between functional boards.
* 📦 **Universal Linux App Scanner**: Scans Debian/APT (`/usr/share/applications`) and Flatpak (`/var/lib/flatpak/exports`) desktop entries natively.
* 🖼️ **Native Desktop App Icons**: Directly parses and streams high-resolution PNG/SVG icons from Linux system icon themes.
* 🎵 **MPRIS Integration**: Universal media controls (Spotify/VLC/Browser) natively executed via D-Bus (`org.mpris.MediaPlayer2`).
* 🖥️ **Web UI Configurator**: Drag & drop configuration panel served over local HTTP on port `8484`.

---

## 🚫 Cancelled / Deprecated Features

* ❌ **Python / aiohttp Backend**: 
  - *Reason for Cancellation*: High memory usage and complex virtual environment management. Completely replaced by the standalone Dart daemon.
* ❌ **`ddcutil` Hardware I2C Polling**: 
  - *Reason for Cancellation*: Synchronous polling caused KDE Plasma GPU frame drops. Replaced with non-blocking local sysfs scaling.

---

## 🔮 Upcoming Roadmap (v2.1.0+)

- [ ] **Windows & macOS Port**: Implement `Platform.isWindows` and `Platform.isMacOS` OS bridges in `SystemActionsService.dart` to support Windows Start Menu / Media APIs and macOS AppleScript.
- [ ] **Custom Icon File Upload**: Upload local PNG/SVG icon images for custom buttons via the Web UI.
- [ ] **OBS Studio Scene Switcher Plugin**: Built-in OBS WebSocket plugin tab with live scene preview.
- [ ] **System Hardware Monitoring**: Real-time CPU, RAM, and GPU temperature touch tiles pulling from native metrics.
