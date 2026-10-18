#!/bin/sh

# Release gate for the alpha end-user flow.  The source-only mode is safe to
# run offline and does not need an APK, Android SDK, emulator, or device.
# Artifact mode composes the repository's portable artifact and signing checks
# after CI has built the outputs.  Neither mode claims physical alpha
# acceptance unless the explicit acceptance mode is requested.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
  printf 'alpha readiness check failed: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -s "$1" ] || fail "missing or empty $2 ($1)"
}

require_marker() {
  file=$1
  marker=$2
  description=$3
  grep -Fq -- "$marker" "$file" || fail "missing $description in $file"
}

source_gate() {
  metadata="$root/deckboard_daemon/backend/lib/release_metadata.dart"
  alpha_doc="$root/docs/alpha-release.md"
  backend="$root/deckboard_daemon/backend"
  mobile="$root/kdedeck_mobile"
  require_file "$alpha_doc" 'alpha release plan'
  require_file "$root/scripts/check-release-metadata.sh" 'release metadata gate'
  require_file "$root/scripts/check-release-artifacts.sh" 'release artifact gate'
  require_file "$root/scripts/check-android-signing.sh" 'Android signing gate'
  require_file "$metadata" 'release metadata'
  require_file "$root/deckboard_daemon/tray/main.go" 'Linux tray source'
  require_file "$root/deckboard_daemon/frontend/browser_e2e.test.mjs" 'browser flow test'
  require_file "$backend/lib/enrollment_protocol.dart" 'daemon enrollment protocol source'
  require_file "$backend/lib/mdns_service_advertiser.dart" 'daemon mDNS advertisement source'
  require_file "$backend/lib/dart_server_service.dart" 'daemon HTTP/WebSocket source'
  require_file "$backend/test/enrollment_protocol_test.dart" 'daemon enrollment tests'
  require_file "$mobile/lib/services/onboarding_service.dart" 'Android onboarding source'
  require_file "$mobile/lib/services/websocket_service.dart" 'Android transport source'
  require_file "$mobile/test/onboarding_service_test.dart" 'Android enrollment tests'

  # A documentation-only mention of discovery is not an implementation.  The
  # Linux advertisement must carry the exact DNS-SD service type consumed by
  # the Android NSD client.  Search only implementation trees so this cannot
  # be satisfied by the release plan itself.
  require_marker "$backend/lib/mdns_service_advertiser.dart" \
    "static const String serviceType = '_kde-deck._tcp';" \
    'Linux _kde-deck._tcp advertisement service type'
  require_marker \
    "$mobile/android/app/src/main/kotlin/io/github/deepthumar81/kdedeck/MainActivity.kt" \
    '_kde-deck._tcp.' 'Android NSD service type'
  require_marker \
    "$mobile/android/app/src/main/kotlin/io/github/deepthumar81/kdedeck/MainActivity.kt" \
    'discoverKdeDeck' 'Android discovery method-channel source'
  require_marker "$backend/lib/dart_server_service.dart" \
    "import 'mdns_service_advertiser.dart';" 'daemon mDNS advertiser import'
  require_marker "$backend/lib/dart_server_service.dart" \
    '_startMdnsAdvertisement' 'daemon mDNS advertiser lifecycle wiring'
  require_marker "$backend/lib/dart_server_service.dart" \
    'MdnsServiceAdvertiser' 'daemon mDNS advertiser implementation wiring'

  # Require the real enrollment boundary on both sides of the wire.  These
  # checks intentionally name source symbols rather than accepting a heading
  # or a test fixture that is disconnected from the running flow.
  require_marker "$backend/lib/dart_server_service.dart" \
    "request.uri.path == '/enrollment'" 'daemon enrollment route'
  require_marker "$backend/lib/dart_server_service.dart" \
    'issueEnrollmentPayload' 'daemon enrollment payload issuance'
  require_marker "$backend/lib/dart_server_service.dart" \
    'consumeChallenge' 'daemon enrollment challenge consumption'
  require_marker "$mobile/lib/services/onboarding_service.dart" \
    'class EnrollmentInvite' 'Android enrollment invite parser'
  require_marker "$mobile/lib/services/onboarding_service.dart" \
    'class AndroidHostDiscovery' 'Android NSD discovery abstraction'
  require_marker "$mobile/lib/services/websocket_service.dart" \
    'Future<void> enroll' 'Android enrollment transport'
  require_marker "$mobile/lib/ui/neumorphic_deck.dart" \
    'mobile_scanner' 'Android QR scanner integration'

  for heading in \
    '## Linux tray and daemon' \
    '## Browser dashboard and discovery' \
    '## QR pairing and camera-less fallback' \
    '## Android installation' \
    '## Signing and artifact gates' \
    '## Rollback' \
    '## Manual acceptance'; do
    grep -Fq "$heading" "$alpha_doc" || fail "alpha plan is missing heading: $heading"
  done

  # These are intentionally documentation/source checks only.  They keep the
  # CI gate aligned with the user-visible flow while leaving device actions to
  # the explicit manual acceptance section.
  grep -Fq 'Pair with code' "$alpha_doc" || fail 'alpha plan omits one-time pairing'
  grep -Fq 'camera-less' "$alpha_doc" || fail 'alpha plan omits camera-less fallback'
  grep -Fq 'certificate' "$alpha_doc" || fail 'alpha plan omits certificate identity binding'
  grep -Fq 'adb install' "$alpha_doc" || fail 'alpha plan omits Android installation command'
  grep -Fq 'make alpha-readiness-check' "$alpha_doc" || fail 'alpha plan omits automated gate command'
  grep -Fq 'make alpha-release-check' "$alpha_doc" || fail 'alpha plan omits production acceptance gate command'
  grep -Fq 'Acceptance status:' "$alpha_doc" || fail 'alpha plan omits machine-readable acceptance status'

  # This gate is the source/artifact contract, not physical device QA.  Make
  # the distinction explicit in the output and keep the latter as a separate
  # opt-in check below.
  sh "$root/scripts/check-release-metadata.sh"
}

manual_acceptance_gate() {
  alpha_doc="$root/docs/alpha-release.md"
  status=$(sed -n 's/^\*\*Acceptance status:\*\* //p' "$alpha_doc")
  [ "$status" = 'PASS' ] || fail \
    "manual alpha acceptance status is '$status' (expected PASS)"

  unchecked=$(awk '/^- \[ \]/ { count++ } END { print count + 0 }' "$alpha_doc")
  [ "$unchecked" -eq 0 ] || fail \
    "manual alpha checklist has $unchecked unchecked acceptance criteria"

  checked=$(awk '/^- \[[xX]\]/ { count++ } END { print count + 0 }' "$alpha_doc")
  [ "$checked" -ge 10 ] || fail \
    "manual alpha checklist has only $checked checked acceptance criteria"

  owner=$(sed -n 's/^\*\*Acceptance owner:\*\* //p' "$alpha_doc")
  [ -n "$owner" ] && [ "$owner" != 'unassigned' ] || \
    fail 'manual alpha acceptance owner is not recorded'
  date=$(sed -n 's/^\*\*Acceptance date:\*\* //p' "$alpha_doc")
  [ -n "$date" ] && [ "$date" != 'not recorded' ] || \
    fail 'manual alpha acceptance date is not recorded'
}

if [ "${1:-}" = '--source-only' ]; then
  [ "$#" -eq 1 ] || fail 'usage: check-alpha-readiness.sh --source-only'
  source_gate
  printf 'alpha source contract OK (physical acceptance and release signing remain separate)\n'
  exit 0
fi

artifact_dir=${1:-"$root/artifacts"}
signing_mode=${2:-allow-debug}
acceptance_mode=${3:-allow-pending}
[ "$#" -le 3 ] || fail \
  'usage: check-alpha-readiness.sh ARTIFACT_DIR [allow-debug|--require-release] [allow-pending|--require-acceptance]'
case "$signing_mode" in
  allow-debug|--require-release) ;;
  *) fail "unknown signing mode: $signing_mode" ;;
esac
case "$acceptance_mode" in
  allow-pending|--require-acceptance) ;;
  *) fail "unknown acceptance mode: $acceptance_mode" ;;
esac

source_gate
sh "$root/scripts/check-release-metadata.sh"
sh "$root/scripts/check-release-artifacts.sh" "$artifact_dir"
sh "$root/scripts/check-android-signing.sh" "$artifact_dir/app-release.apk" "$signing_mode"

# A tag is the release identity in GitHub Actions.  When available, require
# the tag to match the version that the artifact gate already validates.
release_tag=${KDEDECK_RELEASE_TAG:-${GITHUB_REF_NAME:-}}
case "$release_tag" in
  v*)
    expected_version=${release_tag#v}
    actual_version=$(sed -n "s/^[[:space:]]*static const String version = '\([^']*\)';/\1/p" \
      "$root/deckboard_daemon/backend/lib/release_metadata.dart")
    [ "$actual_version" = "$expected_version" ] || \
      fail "release tag $release_tag does not match metadata version $actual_version"
    ;;
esac

if [ "$acceptance_mode" = '--require-acceptance' ]; then
  [ "$signing_mode" = '--require-release' ] || fail \
    'manual alpha acceptance requires a production-signed APK'
  manual_acceptance_gate
  printf 'alpha release gate OK (%s, production signing, manual acceptance PASS)\n' \
    "$artifact_dir"
else
  if [ "$signing_mode" = 'allow-debug' ]; then
    printf 'alpha validation artifacts OK (%s, debug signing allowed; not distributable)\n' \
      "$artifact_dir"
  else
    printf 'alpha production artifact gates OK (%s; manual acceptance still required)\n' \
      "$artifact_dir"
  fi
fi
