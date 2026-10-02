# KDE Deck threat model

## Status and scope

This threat model describes the Linux-first implementation on `main` and the
security properties required before the daemon is exposed to a LAN. It covers
the standalone Dart daemon, the embedded Flutter Dart server, the Flutter
mobile/desktop clients, the browser configurator, the Go tray launcher, the
configuration stores, and the host-system adapters. The current wire format
and topology are described in [`../protocol.md`](../protocol.md) and
[`../architecture.md`](../architecture.md).

This is a design document, not a claim that the current implementation already
meets these properties. At present both Dart servers bind `anyIPv4:8484`, use
plain `ws://`, accept connections without authentication, and can reach host
commands. The standalone icon route also accepts an arbitrary filesystem path.

The threat model does not attempt to protect a host from a user who already has
equivalent local OS privileges, a compromised operating system, or a malicious
binary installed outside KDE Deck. It does protect the host from unpaired
network clients and from malformed or malicious protocol/configuration input.

## Security objectives

1. Only an explicitly paired and authorized client can read state, change the
   deck, or cause a host-side action.
2. A network client cannot turn a deck action, config field, app-discovery
   result, or icon request into arbitrary code execution or arbitrary file
   disclosure.
3. Authentication and authorization fail closed on startup, reconnect, error,
   and platform capability gaps.
4. Valid Linux behavior remains available: desktop-entry, Flatpak, and Snap
   application discovery; valid PNG/SVG/XPM icons; PulseAudio/PipeWire,
   brightness, MPRIS, and KDE actions.
5. Configuration and pairing state survive crashes without partial writes or
   accidental disclosure, and a user has a documented local recovery path.
6. Windows and macOS adapters can be added without weakening the Linux
   boundary or reintroducing shell execution.

## System and trust boundaries

```text
 Untrusted LAN / browser / mobile client
                |
       HTTP and WebSocket boundary
       (bind, TLS, origin, framing,
        pairing and authorization)
                |
       Dart transport and protocol core
       (schema, limits, policy, audit)
          /          |           \
     config FS   icon/app FS   state/metrics
        |             |             |
  persistence    discovery/read    host adapters
                                  (argv, D-Bus,
                                  sysfs, native APIs)
                                        |
                                local user session / OS
```

* **Network boundary:** Any process able to route to port 8484 is untrusted
  until authenticated. This includes another user on the Wi-Fi, a guest VLAN,
  a hostile browser on the same machine, and a process that connects through a
  forwarded port. A LAN is not treated as a trusted perimeter.
* **Browser boundary:** The served configurator is not a security principal.
  Browser JavaScript, `Origin`, and a local web page must not be able to bypass
  pairing or authorization. A browser on the same host may be controlled by a
  different local user.
* **Client boundary:** The Flutter client is untrusted input even after it has
  been paired. Its local preferences, including the current PIN fields, are
  not proof of identity. A stolen client token is revocable and scoped.
* **Daemon boundary:** The protocol/core is the policy enforcement point. Both
  standalone and embedded servers must apply the same policy; platform code is
  not allowed to make a second, weaker decision.
* **Filesystem boundary:** Configuration, backups, icon roots, desktop-entry
  files, and app metadata are local resources. Paths received over the network
  are untrusted and must be canonicalized and constrained before access.
* **Host execution boundary:** The daemon runs with the launching user's
  privileges. A successful request can control audio/display/media/session
  state, launch a program, or suspend/shut down the host. Host commands are an
  execution boundary, not a string-formatting detail.

## Assets

| Asset | Confidentiality | Integrity/availability impact |
|---|---|---|
| Host command and session-control capability | High | Unauthorized launch, arbitrary command execution, logout, suspend, shutdown |
| `deckboard_config.json` and embedded preference config | Medium | Persistent malicious actions, loss of boards, client-wide config poisoning |
| Pairing secrets, bearer tokens, and recovery material | High | Impersonation and durable remote control |
| Audio, mute, brightness, media, and power state | Low to medium | Annoyance, disruption, denial of service |
| Installed-app list, desktop-entry metadata, icon paths/files | Medium | Application inventory disclosure and arbitrary file-read risk |
| RAM/system metrics and host/network metadata | Low to medium | Fingerprinting and privacy leakage |
| Logs and crash/error output | Medium | Secret, command, URL, path, and topology disclosure |
| Service availability and client connections | Medium | Flooding, resource exhaustion, loss of local control |

## Attacker assumptions and capabilities

The primary attacker can send TCP/HTTP/WebSocket traffic to the daemon, open
many connections, send arbitrary JSON and binary/text frame sizes allowed by the
transport, replay captured messages, choose action/config fields, request app
discovery, and request icon paths. They may know the port, inspect public
protocol documentation, and observe broadcast messages on a connection they
control. They may also exploit a browser's ability to make cross-origin
requests if the server accepts them.

The attacker cannot read the daemon's process memory, bypass filesystem
permissions, become the local user, or alter trusted application binaries. If
they do obtain a valid pairing token, the threat is a stolen-client case: the
token must be revocable, rate-limited, scoped, and excluded from logs, but the
host cannot distinguish the thief from that client without re-pairing.

The product must assume a hostile LAN even when the intended use is a phone on
the home network. Port forwarding, a misconfigured firewall, captive portals,
shared Wi-Fi, and compromised IoT devices are in scope. The product does not
promise security if the user deliberately exposes an unauthenticated legacy
build to the Internet.

## Abuse cases and mitigations

| ID | Abuse case | Impact | Required mitigation |
|---|---|---|---|
| A-01 | Unpaired peer upgrades `/ws` and sends `trigger_action`. | Remote host control. | Bind loopback by default; require authenticated pairing before `init_state` or any request; reject and rate-limit unauthenticated sockets. |
| A-02 | Attacker guesses, replays, or brute-forces a PIN/pairing code. | Client impersonation. | One-time, expiring bootstrap code; salted hash at rest; constant-time verification; per-source and global backoff; token rotation/revocation; never use the existing local PIN preference as authentication. |
| A-03 | `launch_app` or `kde_action` payload is passed to `sh -c`/`cmd /c`. | Arbitrary commands under the daemon user. | Use structured executable plus argument vectors, approved discovered-app records, fixed action enums, and no shell for network-controlled data. |
| A-04 | A valid-looking `open_url` launches a dangerous scheme or embeds shell metacharacters. | Local app launch, data exfiltration, command execution. | Permit only `http`/`https` with valid URI parsing, bounded length, no control characters/credentials unless explicitly supported; pass as one argv item. |
| A-05 | Caller supplies `/etc/shadow`, a symlink, or `../../` to `/system_icons`. | Arbitrary file disclosure. | Canonicalize and require a regular file under approved icon roots; allow only PNG/SVG/XPM, size/content limits, and reject symlink escapes. |
| A-06 | Malicious `save_config` contains huge/deep JSON, invalid numbers, duplicate IDs, unsupported actions, or hostile titles/icons. | Memory/CPU exhaustion, persistent client-side injection, action poisoning. | Frame/body/depth/string/count limits; strict schema; finite bounded numbers; action/payload policy; safe text rendering; atomic bounded persistence; reject with structured errors. |
| A-07 | Attacker overwrites a valid config while another client is editing. | Loss of boards or persistence of attacker-controlled actions. | Config-write authorization, revision/compare-and-swap, conflict response, atomic write plus backup, and local recovery. |
| A-08 | Client floods actions, app scans, icon reads, or connections. | Process exhaustion, command storms, degraded desktop. | Per-IP/per-token connection and request limits, concurrency caps, per-action cooldowns, bounded queues, timeouts, and disconnect on repeated violations. |
| A-09 | Authenticated low-privilege client invokes shutdown/logout or changes configuration. | Disruption or privilege expansion. | Capability/role authorization; sensitive power/session actions require explicit local confirmation or a separately enabled policy; configuration is separate from ordinary control. |
| A-10 | A client observes `init_state`, metrics, installed apps, or paths before auth, or one client's secret/error is broadcast. | Privacy leakage and cross-client disclosure. | Authenticate before state; minimize state by role; target responses to the requester; redact logs and errors; never broadcast credentials or raw host errors. |
| A-11 | Discovery parses a desktop file's `Exec` string and preserves shell syntax. | App-discovery becomes command injection. | Parse desktop-entry field codes into executable/argv; reject unsupported field codes and shell operators; retain Flatpak/Snap launchers through explicit safe templates. |
| A-12 | A filesystem icon root is replaced or a symlink points outside it. | Read of arbitrary user/system files. | Canonical-root check at request time, no link following outside root, regular-file check, allowlisted MIME/extensions, bounded response, and tests for root replacement. |
| A-13 | Failure of auth/config validation/platform adapter falls through to permissive behavior. | Security bypass or unsafe optimistic state. | Fail closed, return explicit errors, do not execute on parse/adapter failure, do not advertise unsupported capabilities, and reconcile state only after success. |
| A-14 | Logs record full pairing tokens, commands, URLs, paths, or request payloads. | Credential and privacy disclosure. | Structured security events with redaction, identifiers instead of secrets, bounded output, access-controlled logs, and retention guidance. |
| A-15 | A Windows/macOS implementation adds a shell fallback or weakens bind/auth defaults. | Cross-platform remote command execution. | Shared protocol/core policy, native structured APIs, platform capability declarations, platform-specific tests, and a no-shell requirement for every adapter. |

## Authentication and pairing model

The target model is two-stage:

1. **Local bootstrap:** The daemon is reachable on loopback (or through an
   explicit local UI) and displays a short-lived, one-time pairing code only
   after the user requests pairing. The code is never printed to logs or sent
   in an unauthenticated `init_state`. A user explicitly approves the client.
2. **Authenticated operation:** Pairing establishes a high-entropy client
   credential stored in the platform secure store where available. The daemon
   stores only a salted verifier, supports expiry/rotation/revocation, and
   requires the credential during WebSocket authentication before sending
   configuration, metrics, app inventory, or accepting actions.

Remote pairing must use authenticated transport (`wss`) with certificate
verification and a user-visible fingerprint/approval path. A PIN sent over
plain `ws` is not sufficient against a LAN man-in-the-middle. Legacy `ws`
connections may remain available only for loopback development mode, with a
visible warning and no assumption that LAN traffic is safe.

At minimum, authorization should distinguish `viewer` (state only), `control`
(safe audio/brightness/media/open-url operations), and `config_admin`
(configuration and discovery). Sleep, shutdown, logout, and arbitrary session
control require a separately enabled sensitive-action capability and, by
default, a local confirmation. Revoking a client invalidates all of its active
sockets and tokens.

## Residual risk

An authenticated controller can still cause the same host-level effects that
the user intentionally paired it to control. A local user with equivalent OS
privileges can inspect or modify the daemon, intercept local IPC, or replace
desktop entries/icons. Native platform APIs may have different security and
confirmation semantics. These risks are reduced by least-privilege roles,
explicit sensitive-action policy, auditable events, and a clear pairing/revoke
UI; they are not eliminated by WebSocket authentication alone.
