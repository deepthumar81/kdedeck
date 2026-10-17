# Standalone daemon TLS setup

## Current behavior

- Default: loopback HTTP/WS only, still requiring WebSocket authentication.
- LAN: `allow_lan: true` plus valid local TLS credentials is required.
- Both HTTPS and WSS use the same port (default 8484).
- Invalid or missing required TLS refuses startup; there is no HTTP LAN fallback.

Provision a PEM certificate chain and matching PEM private key outside this
repository. The certificate must be valid for the hostname/IP clients use,
including the appropriate subject alternative names. Keep the private key
accessible only to the daemon user. Do not commit keys or paste them in chat.

The repository includes a local provisioning helper. It creates a self-signed
certificate with the requested SANs, restricts the key to mode `0600` on POSIX,
and writes a SHA-256 fingerprint manifest plus a public, certificate-only
`server.kdedeck-trust.json` enrollment artifact. It refuses to overwrite
existing files unless `--force` is supplied for intentional rotation:

```bash
cd deckboard_daemon/backend
dart run bin/tls_provision.dart \
  --hostname my-pc.example.test \
  --hostname 192.168.1.50 \
  --output-dir "$HOME/.config/kdedeck/tls"
```

Verify `server.sha256` through a separate trusted local channel before giving
the certificate or `server.kdedeck-trust.json` to a client or installing it
into a device trust store. The fingerprint is an identity check; it does not
replace normal certificate hostname and expiry validation. The enrollment
artifact contains no private key and is safe to copy to the phone for import.

Example invocation from the backend directory, using placeholder paths:

```bash
KDEDECK_TLS_CERT_FILE="$HOME/.config/kdedeck/tls/server.crt" \
KDEDECK_TLS_KEY_FILE="$HOME/.config/kdedeck/tls/server.key" \
./kdedeck_daemon
```

Set `allow_lan` in the existing configuration without discarding its boards.
Open `https://<certificate-hostname>:8484` in the browser; the web client chooses
WSS automatically when loaded over HTTPS.

## Trust

Clients must trust the certificate issuer and verify the hostname. A self-signed
certificate is not automatically trusted. Confirm its identity through a separate
trusted local channel before provisioning trust. Do not globally disable TLS
validation or accept every certificate. TLS encrypts transport; pairing and
authorization are still necessary.

## Flutter client connection

In the phone app, add a PC using its certificate hostname/IP and port. New remote
profiles default to **Secure connection (WSS / HTTPS)**. Certificate trust and
hostname checks are performed by the platform; there is no accept-any-certificate
option or downgrade to plaintext. A self-signed certificate without provisioned
trust will show a connection failure **before any pairing code/token is sent**.
If the phone's platform trust store does not contain the issuer, the connection
screen offers **Trust a verified certificate** after the first WSS failure. The
recommended path is to copy `server.kdedeck-trust.json` from the daemon's TLS
directory to the phone and choose **Import trust file**. This artifact contains
only the public certificate and its SHA-256 digest; it never contains the
private key. The app parses the single certificate, recomputes its digest, and
rejects a modified or mismatched artifact. Before pressing **Trust certificate**
the user must compare the displayed `SHA256:` value with the value shown on the
PC through a separate trusted local channel and tick the confirmation box.
The PEM/fingerprint paste path remains available as a fallback.

The imported certificate is stored in endpoint-scoped secure storage and the
connection still uses the platform's normal hostname and validity-period
checks. It sends no pairing credential during the failed handshake. A
different certificate is rejected until **Replace an existing certificate** is
explicitly selected; replacing first removes the old bearer token and requires
pairing again. If secure credential deletion fails, the old certificate remains
trusted and the rotation is reported as failed.

Start the standalone daemon with `--pair` in its local interactive terminal, then
enter that one-time code in the app's **Pair with code** field. Successful pairing
stores only the issued bearer token using platform secure storage. Use
**Forget credential & re-pair** in the drawer to discard the saved credential.
Tokens are isolated by scheme, host and port; switching endpoints cannot send
the previous endpoint's credential. Android app backup is disabled to avoid
restoring encrypted credential data without its original keystore keys.

On Linux the new secure-storage plugin requires the platform secret service and
libsecret development/runtime packages for building/running the desktop app.
If secure storage is unavailable, authentication fails visibly; preferences are
not used as an insecure fallback. Device keystore/keychain/secret-service
behaviour across upgrades still requires physical-device QA.

The embedded Flutter server now follows the same transport rule: a non-loopback
bind requires `KDEDECK_TLS_CERT_FILE` and `KDEDECK_TLS_KEY_FILE` and serves WSS.
With both variables set, loopback also serves HTTPS/WSS. With neither set, only
a loopback bind may serve plain HTTP/WS. The Flutter client blocks remote plain
WS and uses normal certificate validation. Plain WS remains available only for
numeric loopback (`127.x.x.x` or `::1`), not a DNS alias such as `localhost`.

## Verification completed

Automated tests generate disposable certificate/key fixtures outside the repo:

- Trusted HTTPS and WSS handshake/authentication succeed.
- Untrusted certificates are rejected.
- Plain HTTP and WS cannot access the TLS listener.
- Missing, malformed, partial, and mismatched credentials refuse startup.
- Loopback HTTP remains usable with TLS unset.
- LAN startup requires TLS, including injected non-loopback test binds.
- Flutter Linux tests cover exact PEM/X.509 parsing, fingerprint matching,
  endpoint-scoped trust cleanup, rotation failure handling, and WSS rejection
  of expired and hostname-mismatched certificates before authentication.

Run `dart test test/dart_server_tls_test.dart` in `deckboard_daemon/backend` and
`flutter test test/client_transport_test.dart` in `kdedeck_mobile`. These tests
require OpenSSL on the Linux test host; production uses Dart's TLS
implementation.

## Required follow-ups

- Physical Android import and verified server-identity workflow testing.
- Device keystore upgrade testing.
- Physical Android/Linux LAN pairing and icon/editor end-to-end tests.
- Physical Android/device-keystore testing and physical LAN verification remain
  open; the Linux suite exercises the client trust boundary but cannot replace
  device-platform QA.
- Physical LAN verification for standalone and embedded servers.
