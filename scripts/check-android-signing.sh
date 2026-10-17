#!/bin/sh

# Verify an APK's cryptographic signature. CI validation APKs may use the
# Android debug key; public release APKs must explicitly reject that key.
set -eu

fail() {
  printf 'Android signing check failed: %s\n' "$1" >&2
  exit 1
}

apk=${1:-}
mode=${2:-allow-debug}
[ -n "$apk" ] || fail 'usage: check-android-signing.sh APK [--require-release]'
[ -s "$apk" ] || fail "missing or empty APK ($apk)"
case "$mode" in
  allow-debug|--require-release) ;;
  *) fail "unknown mode: $mode" ;;
esac

apksigner=''
android_home=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
if command -v apksigner >/dev/null 2>&1; then
  apksigner=$(command -v apksigner)
elif [ -n "$android_home" ]; then
  for candidate in "$android_home"/build-tools/*/apksigner; do
    if [ -x "$candidate" ]; then
      apksigner=$candidate
    fi
  done
fi
[ -n "$apksigner" ] || fail 'apksigner is required (install Android SDK build-tools)'

details=$(mktemp)
trap 'rm -f "$details"' EXIT HUP INT TERM
"$apksigner" verify --verbose --print-certs "$apk" >"$details" 2>&1 || \
  fail 'APK signature verification failed'

if [ "$mode" = '--require-release' ] && \
   grep -Eiq 'certificate DN:.*CN=Android Debug' "$details"; then
  fail 'APK is signed with the Android debug certificate; use the production keystore'
fi

printf 'Android APK signature OK (%s): %s\n' "$mode" "$apk"
