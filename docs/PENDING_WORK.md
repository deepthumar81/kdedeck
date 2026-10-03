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
- [ ] Bound rate-limiter identity storage, expire stale entries, add global limits
  and prevent connection/action/request floods.
- [ ] Frame/JSON decode limits before allocation; HTTP limits and origin policy;
  static path containment and frontend XSS-safe rendering.
- [ ] Device-scoped credential persistence with protected storage, rotation,
  local recovery, safe diagnostics, and administrative revocation UI.
- [ ] Local approval and role selection instead of always pairing as configAdmin;
  background/tray local pairing without logging codes.
- [ ] Sensitive power/session action authorization and confirmation.
- [ ] Restrict application execution to approved identities; no arbitrary
  executable or interpreter invocation even when argv has no shell syntax.
- [ ] Action results/errors, subprocess timeouts and bounded execution, correct
  state after command failures; remove fabricated metrics.
- [ ] Config revision/conflict detection, restrictive file permissions, injected
  persistence failure tests, cross-platform atomic replacement verification.
- [ ] Icon authorization, file/content limits and safe SVG behavior; valid Snap,
  user-local Flatpak and package icon roots with no feature regression.
- [ ] TLS certificate provisioning, verified fingerprint/trust workflow, expiry
  and hostname rejection fixtures, rotation UX and physical LAN verification.
- [ ] Converge embedded Flutter server with shared auth/validation/TLS policy;
  versioned protocol/capabilities and server lifecycle/tray path reliability.

## Clients, UX, platforms, releases

- [ ] Flutter pairing/auth/WSS, secure token storage, expiry/reconnect/re-pair UI;
  fix the existing provider-less widget smoke test.
- [ ] Web authenticated error/capacity/rate-limit/config rejection handling;
  avoid persistent JS-readable credentials and complete browser end-to-end tests.
- [ ] Android and Linux UX bugs, accessible layouts/drag/drop/sliders, undo,
  connection profiles and onboarding; record real device manual QA.
- [ ] Windows/macOS adapters, capability-driven unsupported-feature UI, native
  launching/paths/storage and build tests (do not treat compilation as parity).
- [ ] Add the planned plugins/features only after security/UX baseline acceptance.
- [ ] CI, packaging, clean-install/upgrade/recovery tests, release checks and docs
  synchronization (architecture and older baseline descriptions are historical).

Completed slices so far: documentation baseline, test/executor seams, standalone
auth gates, per-peer failed-attempt throttling, config validation/backup, bounded
session manager, capacity response, safe bind defaults, TLS listener, and explicit
foreground terminal pairing. Automated checks do not replace device/browser QA.
