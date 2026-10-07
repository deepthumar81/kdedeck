# Required pending work

This index tracks unfinished limitations from the development log and security
requirements. Items are required, not optional. Close an item only with changes
and verification recorded in `DEVELOPMENT_LOG.md`. This is not a claim of full
security or UI/platform parity.

## Backend/security

- [x] Revalidate session expiry/revocation before broadcasts (Step 16).
- [x] Revalidate delayed app-discovery responses (Step 17).
- [x] Promptly disconnect manager-revoked standalone sessions (Step 18).
- [ ] Audit other delayed operations and implement local administrative controls.
- [x] Bound rate-limiter identity storage and expire stale entries.
- [x] Add bounded standalone WebSocket connections and per-client message/action
  flood protection.
- [x] Bound standalone WebSocket frame bytes and reject binary frames before JSON
  parsing.
- [x] Add standalone HTTP security headers and a no-store cache policy for
  frontend, icon, missing, and error responses.
- [x] Validate browser WebSocket Origin against the same HTTP scheme/host/port;
  preserve Origin-less native clients and reject malformed/cross-origin upgrades.
- [x] Bound standalone HTTP request targets, normalized header bytes/count, and
  request bodies before route handling.
- [x] Replace frontend user-controlled HTML interpolation with text-safe DOM
  rendering for board/item titles, installed-app labels, icons, and imported
  configuration values.
- [ ] Device-scoped credential persistence with protected storage, rotation,
  local recovery, safe diagnostics, and administrative revocation UI.
- [x] Add opt-in backend session-store seam with SHA-256 token fingerprints,
  private atomic file storage, bounded restore, and restart/failure tests.
- [x] Refuse stale restoration when interrupted writes leave a pending marker
  (Step 28); tested for single/role/all revocation.
- [x] Add confirmed terminal-only offline session-store reset/re-pair recovery
  (Step 29); never clear marker before committing an empty snapshot.
- [x] Add exclusive FileSessionStore ownership and reset contention protection;
  Linux subprocess release/exit tested (Step 30).
- [x] Integrate injected store acquisition/release/restart with standalone
  lifecycle; production persistence unchanged (Step 31).
- [x] Cover opt-in standalone persistence through the public server across
  save, conflict, restart, and storage failure (Step 46); production persistence
  remains disabled.
- [x] Fence stale standalone WebSocket upgrades, messages, and state-changing
  continuations across stop/restart (Step 32).
- [x] Serialize standalone start/stop requests in invocation order, including
  overlapping restart and duplicate shutdown calls (Step 33).
- [x] Fence in-flight metrics ticks and prevent overlapping metrics probes
  across stop/restart (Step 34).
- [x] Fence in-flight HTTP preparation/routing against old lifecycle
  generations (Step 35).
- [x] Define queued config-save shutdown semantics: stale queued writes must not
  overwrite config loaded by a restarted server; drain or cancel safely (Step 36).
- [ ] Wire production persistence only with an explicit policy for
  marker-creation/storage failure. Verify
   directory durability, Windows replacement/ACLs, cross-platform locking and
   multi-isolate ownership. Audit in-flight operation shutdown ordering.
- [ ] Stabilize lock-probe subprocess tests under parallel suite load; serial
  backend suite passes, but one parallel probe timed out during Step 31.
- [ ] Local approval and role selection instead of always pairing as configAdmin;
  background/tray local pairing without logging codes.
- [x] Gate sensitive power/session actions behind an explicit policy and local
  confirmation for sleep, shutdown, and logout (Step 39).
- [ ] Restrict application execution to approved identities; no arbitrary
  executable or interpreter invocation even when argv has no shell syntax.
- [x] Return bounded action results/errors and preserve state after command
  failures (Step 37).
- [x] Bound control, discovery, and metrics subprocesses with deadlines,
  direct-child termination, sanitized failures, and combined output limits
  (Step 38).
- [ ] Define safe ownership/lifetime for user-launched applications and process
  trees across platforms; remove fabricated metrics.
- [x] Add standalone in-process config revision/conflict detection and injected
  persistence failure coverage (Step 46).
- [ ] Verify restrictive config-file permissions and cross-platform atomic
  replacement behavior.
- [x] Add a backward-compatible `config_schema_version` marker and reject
  unsupported versions without rewriting legacy files (Step 42).
- [ ] Icon authorization, file/content limits and safe SVG behavior; valid Snap,
  user-local Flatpak and package icon roots with no feature regression.
- [ ] TLS certificate provisioning, verified fingerprint/trust workflow, expiry
  and hostname rejection fixtures, rotation UX and physical LAN verification.
- [x] Reject explicitly unsupported protocol versions before standalone
  authentication consumes credentials (Step 43); omitted versions remain
  backward-compatible.
- [ ] Converge embedded Flutter server with shared auth/validation/TLS policy;
  complete cross-server/client compatibility enforcement and server
  lifecycle/tray path reliability.

## Clients, UX, platforms, releases

- [ ] Flutter pairing/auth/WSS, secure token storage, expiry/reconnect/re-pair UI;
  record device QA.
- [x] Fix the provider-less Flutter widget smoke test by matching the production
  `WebSocketService` provider boundary (Step 48).
- [ ] Web authenticated error/capacity/rate-limit/config rejection handling;
  avoid persistent JS-readable credentials and complete browser end-to-end tests.
- [x] Send standalone protocol version and compare-and-swap config revisions from
  the web configurator; block unsafe retry after a conflict (Step 47).
- [ ] Android and Linux UX bugs, accessible layouts/drag/drop/sliders, undo,
  connection profiles and onboarding; record real device manual QA.
- [ ] Windows/macOS adapters, capability-driven unsupported-feature UI, native
  launching/paths/storage and build tests (do not treat compilation as parity).
- [ ] Add the planned plugins/features only after security/UX baseline acceptance.
- [ ] CI, packaging, clean-install/upgrade/recovery tests, release checks and docs
  synchronization (architecture and older baseline descriptions are historical).
- [ ] Define versioned in-place app updates for the Linux daemon and Flutter app:
  monotonic release/build metadata, stable package identity, preserved user
  configuration and session data, explicit migrations and protocol compatibility,
  signed artifacts, atomic replacement with rollback, and clean-install/upgrade
  tests. Never require uninstalling the older version before a successful update.
- [x] Expose the standalone daemon's stable artifact name, release version, and
  build number through `--version` (Step 44); package identity and updater
  automation remain pending.
- [x] Replace generated Flutter Android/Linux example identifiers with the stable
  application ID `io.github.deepthumar81.kdedeck` (Step 45); iOS/macOS bundle
  identity and updater automation remain pending.

Completed slices so far: documentation baseline, test/executor seams, standalone
auth gates, per-peer failed-attempt throttling, config validation/backup, bounded
session manager, capacity response, safe bind defaults, TLS listener, and explicit
foreground terminal pairing, an opt-in persisted session-store boundary with
public-server safety coverage, and standalone protocol metadata advertisement.
Embedded-server convergence and compatibility enforcement remain pending.
Automated checks do not replace device/browser QA.
