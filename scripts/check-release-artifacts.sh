#!/bin/sh

# Validate the files that CI publishes as release build outputs. This checks
# artifact presence and archive integrity without requiring a device, signing
# key, or network access.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
artifact_dir=${1:-"$root/artifacts"}

fail() {
  printf 'release artifact check failed: %s\n' "$1" >&2
  exit 1
}

require_file() {
  [ -s "$1" ] || fail "missing or empty $2 ($1)"
}

daemon="$artifact_dir/kdedeck_daemon"
apk="$artifact_dir/app-release.apk"

require_file "$daemon" 'standalone daemon artifact'
require_file "$apk" 'Android release APK'
[ -x "$daemon" ] || fail 'standalone daemon artifact is not executable'

command -v unzip >/dev/null 2>&1 || fail 'unzip is required to inspect the Android release APK'
unzip -tqq "$apk" >/dev/null 2>&1 || fail 'Android release APK is not a valid ZIP archive'

if ! unzip -l "$apk" | awk '$NF == "AndroidManifest.xml" { found = 1 } END { exit(found ? 0 : 1) }'; then
  fail 'Android release APK has no AndroidManifest.xml entry'
fi

if ! unzip -l "$apk" | awk '$NF ~ /^classes[0-9]*\.dex$/ { found = 1 } END { exit(found ? 0 : 1) }'; then
  fail 'Android release APK has no DEX bytecode entry'
fi

printf 'release artifacts OK: %s and %s\n' "$daemon" "$apk"
