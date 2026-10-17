#!/bin/sh

# Release-readiness gate for the alpha end-user flow.  The source-only mode is
# safe to run offline and does not need an APK, Android SDK, emulator, or
# device.  Artifact mode composes the repository's portable artifact and
# signing checks after CI has built the outputs.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
  printf 'alpha readiness check failed: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -s "$1" ] || fail "missing or empty $2 ($1)"
}

source_gate() {
  metadata="$root/deckboard_daemon/backend/lib/release_metadata.dart"
  alpha_doc="$root/docs/alpha-release.md"
  require_file "$alpha_doc" 'alpha release plan'
  require_file "$root/scripts/check-release-metadata.sh" 'release metadata gate'
  require_file "$root/scripts/check-release-artifacts.sh" 'release artifact gate'
  require_file "$root/scripts/check-android-signing.sh" 'Android signing gate'
  require_file "$metadata" 'release metadata'
  require_file "$root/deckboard_daemon/tray/main.go" 'Linux tray source'
  require_file "$root/deckboard_daemon/frontend/browser_e2e.test.mjs" 'browser flow test'

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
}

if [ "${1:-}" = '--source-only' ]; then
  [ "$#" -eq 1 ] || fail 'usage: check-alpha-readiness.sh --source-only'
  source_gate
  printf 'alpha source readiness OK (no device or APK required)\n'
  exit 0
fi

artifact_dir=${1:-"$root/artifacts"}
signing_mode=${2:-allow-debug}
case "$signing_mode" in
  allow-debug|--require-release) ;;
  *) fail "unknown signing mode: $signing_mode" ;;
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

printf 'alpha release readiness OK (%s, %s)\n' "$artifact_dir" "$signing_mode"
