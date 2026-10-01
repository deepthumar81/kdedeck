# Contributing to KDE Deck 🛠️

Welcome! We are thrilled that you want to contribute to KDE Deck. To ensure a smooth development experience, please read this guide on how our architecture is structured and how to set up your local environment.

---

## 🏛️ System Architecture

KDE Deck is built on a **Three-Tier Architecture**. Understanding how these pieces talk to each other is critical.

### 1. The Core Server (`deckboard_daemon/backend`)
* **Language:** Dart
* **Role:** The brain of the operation. It runs locally on the user's PC (port `8484`). It hosts the WebSockets connection, serves the local Web UI files, and executes native OS commands (like D-Bus).
* **Important Files:**
  * `lib/dart_server_service.dart`: HTTP and WebSocket initialization.
  * `lib/system_actions_service.dart`: Native Linux execution (D-Bus, `.desktop` parsing).

### 2. The Desktop Wrapper (`deckboard_daemon/tray`)
* **Language:** Go (Golang)
* **Role:** Provides a native OS System Tray icon for the user. Its only job is to provide a GUI menu to Open/Quit the application and to manage the lifecycle of the Dart Core Server process.

### 3. The Mobile Client (`kdedeck_mobile`)
* **Language:** Flutter / Dart
* **Role:** The Neumorphic Android/iOS remote control. It is a "dumb client" that simply renders the JSON state sent by the Core Server over WebSockets.

---

## 💻 Development Environment Setup

Because the project uses three different technologies, you only need to install the SDKs for the parts you intend to modify!

### Modifying the Core Server (Dart)
1. Install the [Dart SDK](https://dart.dev/get-dart).
2. Navigate to the backend directory:
   ```bash
   cd deckboard_daemon/backend
   dart pub get
   ```
3. Run the server in development mode:
   ```bash
   dart run bin/backend.dart
   ```

### Modifying the Desktop Tray (Go)
1. Install [Go](https://golang.org/doc/install).
2. Navigate to the tray directory:
   ```bash
   cd deckboard_daemon/tray
   go mod tidy
   ```
3. Run the tray wrapper:
   ```bash
   go run main.go
   ```

### Modifying the Mobile App (Flutter)
1. Install the [Flutter SDK](https://flutter.dev/docs/get-started/install).
2. Navigate to the mobile directory:
   ```bash
   cd kdedeck_mobile
   flutter pub get
   ```
3. Run the app on your connected device or emulator:
   ```bash
   flutter run
   ```

---

## 🤝 Code Style & Pull Requests
* Please run `dart format .` before submitting PRs for Dart/Flutter code.
* If you are implementing a new OS-specific feature (e.g., Windows media controls), please wrap it in `if (Platform.isWindows)` blocks in the `system_actions_service.dart` file to maintain our cross-platform integrity!
