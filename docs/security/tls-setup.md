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
An in-app fingerprint/trust provisioning workflow is not implemented yet.

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

Run `dart test test/dart_server_tls_test.dart` in `deckboard_daemon/backend`.
Tests require OpenSSL on the test host; production uses Dart's TLS implementation.

## Required follow-ups

- User-friendly certificate provisioning and verified server-identity workflow.
- Verified trust/fingerprint provisioning and device keystore upgrade testing.
- Physical Android/Linux LAN pairing and icon/editor end-to-end tests.
- Certificate expiry/rotation UX and hostname/expiry rejection fixtures.
- Certificate provisioning/fingerprint workflow for standalone and embedded
  servers, plus physical LAN verification.
