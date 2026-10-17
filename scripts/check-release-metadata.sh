#!/bin/sh

# Verify the values that identify a release without requiring a language
# runtime beyond the POSIX shell utilities already present in CI images.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
  printf 'release check failed: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -s "$1" ] || fail "missing or empty $2"
}

read_pin() {
  tr -d '[:space:]' < "$1"
}

read_yaml_version() {
  awk '$1 == "version:" { print $2; exit }' "$1"
}

dart_pin=$(read_pin "$root/.dart-version")
flutter_pin=$(read_pin "$root/.flutter-version")
node_pin=$(read_pin "$root/.nvmrc")

[ -n "$dart_pin" ] || fail '.dart-version is empty'
[ -n "$flutter_pin" ] || fail '.flutter-version is empty'
[ -n "$node_pin" ] || fail '.nvmrc is empty'

backend_pubspec="$root/deckboard_daemon/backend/pubspec.yaml"
mobile_pubspec="$root/kdedeck_mobile/pubspec.yaml"
android_gradle="$root/kdedeck_mobile/android/app/build.gradle.kts"
metadata="$root/deckboard_daemon/backend/lib/release_metadata.dart"
changelog="$root/deckboard_daemon/backend/CHANGELOG.md"

require_file "$backend_pubspec" 'backend pubspec.yaml'
require_file "$mobile_pubspec" 'mobile pubspec.yaml'
require_file "$android_gradle" 'Android app Gradle build file'
require_file "$metadata" 'release metadata'
require_file "$changelog" 'backend changelog'
require_file "$root/deckboard_daemon/backend/pubspec.lock" 'backend pubspec.lock'
require_file "$root/kdedeck_mobile/pubspec.lock" 'mobile pubspec.lock'
require_file "$root/deckboard_daemon/tray/go.sum" 'tray go.sum'

backend_package_version=$(read_yaml_version "$backend_pubspec")
mobile_package_version=$(read_yaml_version "$mobile_pubspec")
metadata_version=$(sed -n "s/^[[:space:]]*static const String version = '\([^']*\)';/\1/p" "$metadata")
metadata_build=$(sed -n "s/^[[:space:]]*static const int build = \([0-9][0-9]*\);/\1/p" "$metadata")
android_version_code=$(sed -n 's/^[[:space:]]*versionCode[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$android_gradle")
android_version_name=$(sed -n 's/^[[:space:]]*versionName[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "$android_gradle")

[ -n "$backend_package_version" ] || fail 'backend package version is missing'
[ -n "$mobile_package_version" ] || fail 'mobile package version is missing'
[ -n "$metadata_version" ] || fail 'release metadata version is missing'
[ -n "$metadata_build" ] || fail 'release metadata build is missing'
[ -n "$android_version_code" ] || fail 'Android versionCode is missing'
[ -n "$android_version_name" ] || fail 'Android versionName is missing'

case "$backend_package_version" in
  *+*) ;;
  *) fail "backend package version must include a build number: $backend_package_version" ;;
esac

case "$mobile_package_version" in
  *+*) ;;
  *) fail "mobile package version must include a build number: $mobile_package_version" ;;
esac

package_version=${backend_package_version%+*}
package_build=${backend_package_version#*+}

[ "$mobile_package_version" = "$backend_package_version" ] || \
  fail "backend/mobile package versions differ ($backend_package_version vs $mobile_package_version)"
[ "$metadata_version" = "$package_version" ] || \
  fail "release metadata version differs from backend package ($metadata_version vs $package_version)"
[ "$metadata_build" = "$package_build" ] || \
  fail "release metadata build differs from backend package ($metadata_build vs $package_build)"
[ "$android_version_name" = "$package_version" ] || \
  fail "Android versionName differs from mobile package ($android_version_name vs $package_version)"
[ "$android_version_code" = "$package_build" ] || \
  fail "Android versionCode differs from mobile package ($android_version_code vs $package_build)"

grep -Fq "## $metadata_version" "$changelog" || \
  fail "changelog has no $metadata_version release heading"

# Keep CI and the container tied to the repository's checked-in runtime pins.
grep -Fq "sdk: $dart_pin" "$root/.github/workflows/ci.yml" || \
  fail "CI Dart SDK does not match .dart-version ($dart_pin)"
grep -Fq "flutter-version: $flutter_pin" "$root/.github/workflows/ci.yml" || \
  fail "CI Flutter SDK does not match .flutter-version ($flutter_pin)"
grep -Fq 'node-version-file: .nvmrc' "$root/.github/workflows/ci.yml" || \
  fail 'CI does not load Node.js from .nvmrc'

docker_pins=$(sed -n 's/^FROM dart:\([^[:space:]]*\).*/\1/p' "$root/Dockerfile")
[ -n "$docker_pins" ] || fail 'Dockerfile has no pinned Dart base image'
for docker_pin in $docker_pins; do
  [ "$docker_pin" = "$dart_pin" ] || \
    fail "Docker Dart pin differs from .dart-version ($docker_pin vs $dart_pin)"
done

printf 'release metadata OK: %s %s (Dart %s, Flutter %s, Node %s)\n' \
  kdedeck_daemon "$backend_package_version" "$dart_pin" "$flutter_pin" "$node_pin"
