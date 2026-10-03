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
- Flutter WSS connections, secure credential storage, and trusted certificate handling.
- Physical Android/Linux LAN pairing and icon/editor end-to-end tests.
- Certificate expiry/rotation UX and hostname/expiry rejection fixtures.
- Embedded Flutter server transport policy convergence.
