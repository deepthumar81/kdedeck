# KDE Deck alpha release plan

> **Current status: alpha not ready yet.** The automated foundation is in this
> branch, but same-LAN service advertisement, end-to-end QR enrollment, and a
> production-signed APK still require completion and physical acceptance. Do
> not distribute this branch as the first user-facing alpha.

This plan is the release contract for the first end-user flow: a Linux PC
starts KDE Deck, a browser or Android client finds/selects that PC, the user
enrolls one time, and the client can reconnect without repeating enrollment.
The QR path is a convenience; it must never weaken TLS identity checks or
pairing authorization. A camera-less phone can always use the short code and
manual host path below.

## Release inputs and automated gates

Run the source-only gate from the repository root after dependencies have been
installed. It is offline and does not need a phone, camera, emulator, Android
SDK, APK, signing key, or network:

```bash
make alpha-source-check
```

This checks the pinned release metadata, required lockfiles and gate scripts,
the presence of this end-user plan, and the documented tray/browser/pairing /
Android acceptance contract. It is included in `make test`.

After CI or a local build has produced `artifacts/kdedeck_daemon` and
`artifacts/app-release.apk`, run the artifact gate:

```bash
make alpha-readiness-check ARTIFACT_DIR=artifacts SIGNING_MODE=allow-debug
```

The gate validates version/runtime metadata, daemon executability, APK archive
contents, and APK signature verification. `allow-debug` is for CI validation
artifacts only. A distributable alpha must use a production keystore:

```bash
KDEDECK_RELEASE_TAG=v1.0.0 \
  make alpha-readiness-check ARTIFACT_DIR=artifacts SIGNING_MODE=--require-release
```

When `KDEDECK_RELEASE_TAG` (or the GitHub `GITHUB_REF_NAME`) is a `v*` tag, it
must equal the release metadata version. No key, token, pairing code, device
identifier, or workstation path is accepted by these checks. CI does not claim
to have tested a physical camera, Android keyboard, certificate store, or tray
menu; those remain in the manual checklist.

## Linux tray and daemon

1. On a supported KDE Plasma Linux host, install the tray runtime dependency
   (`libayatana-appindicator3`) and place `kdedeck_daemon` and the tray binary
   in the alpha package. Do not run a second daemon if port 8484 is occupied.
2. Start the tray binary from its package directory. Confirm the tray icon and
   **Deckboard Daemon is running** tooltip appear. The tray starts the compiled
   daemon when present; a development checkout may fall back to `dart run`.
3. Use **Open Dashboard** once. The default loopback browser address is
   `http://localhost:8484`. Confirm that the dashboard loads and that **Quit**
   stops the daemon and removes the tray process.
4. For first pairing, use a foreground daemon terminal so the one-time code is
   shown only on the local interactive terminal:

   ```bash
   ./kdedeck_daemon --pair
   ```

   Keep that terminal private. Type `pair` and Enter there to rotate a code;
   never copy a code into logs, issue trackers, screenshots, or CI output.

For a phone on the same LAN, set `allow_lan: true`, configure a certificate
whose SAN contains the hostname/IP used by the phone, and provide matching
`KDEDECK_TLS_CERT_FILE` and `KDEDECK_TLS_KEY_FILE`. LAN mode is HTTPS/WSS only;
missing or invalid TLS must stop startup rather than downgrade to plaintext.

## Browser dashboard and discovery

1. Open the tray dashboard, or browse directly to `http://localhost:8484` for
   loopback. For LAN use `https://<verified-certificate-hostname>:8484`.
2. If the alpha discovery view lists a same-LAN KDE Deck host, select the host
   only after checking the displayed host, port, and certificate fingerprint
   against the trusted Linux terminal/provisioning channel. A discovery result
   is a locator, not proof of identity.
3. If discovery is unavailable, select **Manual host** and enter the verified
   hostname/IP and port `8484`. The client must show a TLS or validation error
   before sending a pairing credential when trust or hostname validation fails.
4. Enter the one-time code in **Pair with code**. After `auth_success` and
   `init_state`, confirm the board loads and the browser can save a harmless
   board change. Reload the page and confirm the browser session reconnects
   without displaying the pairing code again.

Discovery must not auto-trust arbitrary LAN certificates, accept a different
certificate silently, or send a bearer token to an endpoint other than the
selected scheme/host/port identity. If a certificate rotates, replace trust
explicitly and pair again.

The daemon does not yet advertise `_kde-deck._tcp.` on the LAN. Android NSD
support is present behind a bounded client abstraction, but discovery is not
alpha-ready until a real Linux advertisement and a physical same-LAN pass are
verified.

## QR pairing and camera-less fallback

When the tray or dashboard presents a QR enrollment payload, scan it only as a
transport shortcut. The current tray panel is a foundation placeholder until
its payload is emitted in the exact Android `EnrollmentInvite` format and the
daemon consumes the one-time challenge. Before calling this flow complete, the
client must display and bind all of these values:

- the selected host and port;
- the certificate identity/fingerprint (or the verified certificate artifact);
- the one-time pairing data and its expiry; and
- the `https`/`wss` scheme required for LAN use.

The QR payload is rejected when it is malformed, expired, uses an unsupported
protocol version, omits a required identity field, or changes the endpoint
after scanning. Scanning must not bypass the normal certificate validation or
the explicit user confirmation of a separately verified fingerprint.

For a camera-less device, choose **Enter code manually**. Select the verified
host from discovery or enter it manually, then type the short, human-readable
fallback code shown by `--pair` (or by the tray enrollment view) into **Pair
with code**. The code is one-use and expires; a failed attempt must show a
bounded error and must not store a token. If the code expires, type `pair` in
the private daemon terminal and use the newly displayed code. Manual host
selection plus the one-time code is the supported fallback when no camera is
available.

## Android installation

On an authorized test phone, transfer the verified APK through a trusted
channel and install it without putting credentials in shell history:

```bash
adb devices
adb install -r artifacts/app-release.apk
```

If Android blocks the install, enable **Install unknown apps** for the chosen
file manager/browser, retry, and explicitly confirm the package. Verify the
application ID and version shown by Android, open KDE Deck, select **Add New PC
IP**, and enter the verified host and port. Use **Secure connection (WSS /
HTTPS)** for LAN. Provision and compare the certificate fingerprint through a
separate trusted channel before selecting **Trust certificate**; never choose
an accept-any-certificate option. Pair with the QR path or camera-less code
fallback above, then verify the board and a harmless control action.

For slow phones, wait for field focus, keyboard animation, complete rendered
text, and the visible result after every tap. Do not use fixed coordinate taps
or record serial numbers, pairing codes, bearer tokens, certificate material,
or screenshots containing secrets. The detailed device procedure is in
[`android-device-testing.md`](android-device-testing.md).

## Signing and artifact gates

The ordinary CI APK is debug-signed and is only a validation artifact. For an
alpha shared outside CI, configure the production keystore in the current
shell or the tag workflow secrets, then build and validate it:

```bash
export KDEDECK_ANDROID_SIGNING_REQUIRED=true
export KDEDECK_ANDROID_KEYSTORE_PATH="$HOME/.config/kdedeck/kdedeck-release.jks"
export KDEDECK_ANDROID_KEYSTORE_PASSWORD='(secret; do not log)'
export KDEDECK_ANDROID_KEY_ALIAS='kdedeck-release'
export KDEDECK_ANDROID_KEY_PASSWORD='(secret; do not log)'

cd kdedeck_mobile
flutter build apk --release
cd ..
mkdir -p artifacts
cp kdedeck_mobile/build/app/outputs/flutter-apk/app-release.apk artifacts/app-release.apk
make alpha-readiness-check ARTIFACT_DIR=artifacts SIGNING_MODE=--require-release
```

Keep the keystore and passwords outside Git and retain an encrypted backup.
The tag workflow requires `KDEDECK_ANDROID_KEYSTORE_BASE64`,
`KDEDECK_ANDROID_KEYSTORE_PASSWORD`, `KDEDECK_ANDROID_KEY_ALIAS`, and
`KDEDECK_ANDROID_KEY_PASSWORD`; it materializes the key only in the ephemeral
runner directory and rejects the Android debug certificate before publishing.
See [`android-release.md`](android-release.md) for the complete secret setup.

## Rollback

1. Stop sharing the alpha URL/APK and mark the release unavailable. Do not
   delete the previous known-good release or its signing key.
2. If the daemon is unhealthy, stop the tray/daemon and restore the previous
   `kdedeck_daemon` and configuration backup. The daemon's atomic config save
   keeps `deckboard_config.json.bak`; validate it before restoring.
3. Revoke active sessions from the private daemon terminal with `revoke all`,
   rotate the pairing code, and require re-pairing after a suspected exposure.
4. For a certificate or key rotation, publish the verified replacement trust
   artifact, explicitly replace endpoint trust on clients, and pair again. Do
   not accept an unexpected certificate to recover service.
5. For Android, distribute a rollback APK signed by the same production key.
   If the key is unavailable, do not promise an in-place update; uninstalling
   the app removes local credentials and requires a fresh install/re-pair.
6. Re-run `make alpha-source-check`, the production artifact gate, and the
   manual acceptance flow before re-enabling distribution.

## Manual acceptance before calling alpha ready

Record only pass/fail and non-sensitive observations. Every item below is
required on at least one supported KDE Plasma Linux host and one authorized
Android phone; automated CI gates do not replace these checks.

- [ ] Tray starts one daemon, shows the running tooltip, opens the browser, and
      quits cleanly without leaving the port occupied.
- [ ] Loopback browser setup loads, displays the pairing prompt, accepts one
      valid code, rejects an invalid/expired code, and reconnects with the
      session token without exposing it.
- [ ] Same-LAN discovery finds the intended host; manual host selection works
      when discovery is unavailable; host, port, and certificate identity are
      visible and match the trusted terminal.
- [ ] HTTPS/WSS succeeds with the verified certificate; wrong hostname,
      changed fingerprint, missing trust, and plaintext LAN are rejected before
      pairing data is sent.
- [ ] QR enrollment binds endpoint, certificate identity, and one-time data;
      malformed/expired QR data is rejected.
- [ ] Camera-less fallback completes with manual host selection and a short
      typed code, including code rotation after expiry.
- [ ] Android installation succeeds from the verified APK, the app reports the
      expected version, and secure trust import plus re-pair works after an
      explicit certificate replacement.
- [ ] An authenticated phone/browser loads the board, performs one harmless
      action, saves a harmless configuration change, reconnects, and preserves
      the change.
- [ ] Production APK signature and release version match pass with
      `--require-release`; no private key, credential, device identifier, or
      sensitive terminal output appears in the release evidence.
- [ ] The rollback procedure is rehearsed with a disposable test profile:
      previous daemon/config restore, session revocation, and same-key APK
      replacement all complete and require re-pair only where documented.

An alpha is ready only when every checkbox passes, the automated gates are
green, and the release owner has retained the non-sensitive pass/fail record.
