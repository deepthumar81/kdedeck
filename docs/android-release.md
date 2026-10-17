# Android APK signing and distribution

KDE Deck can be distributed as an APK without Google Play. Android requires an
APK to be signed, and every update to the same application ID must use the same
signing key. Treat the release keystore and both passwords as irreplaceable
secrets: losing them prevents users from installing future updates over an
existing installation.

## Build types in this repository

- `flutter build apk --release` without signing variables is a validation build.
  It uses the Android debug key, so it is suitable for CI checks and local
  device testing but must not be published as a public release.
- A production build opts in with
  `KDEDECK_ANDROID_SIGNING_REQUIRED=true`. Gradle then requires all four signing
  variables and a non-empty keystore file. Missing or partial values stop the
  build instead of silently producing a debug-signed APK.
- CI validation runs `scripts/check-android-signing.sh` in its default mode.
  The tag release workflow runs it with `--require-release`, which rejects the
  Android debug certificate before publishing.

## Local production build

Generate a keystore once on a trusted workstation. The command below is an
example; `keytool` will prompt for passwords instead of putting them in shell
history:

```bash
mkdir -p kdedeck_mobile/android/keystore
keytool -genkeypair -v \
  -keystore kdedeck_mobile/android/keystore/kdedeck-release.jks \
  -alias kdedeck-release \
  -keyalg RSA -keysize 4096 -validity 10000
```

The `.gitignore` rules exclude the keystore location and common keystore file
extensions. Never add the keystore, its passwords, or a base64 export to GitHub
or to the repository. Keep an encrypted backup in a separate password manager
or secret store.

Set the values only in the current shell (or a local secret manager), then
build and verify the APK. Do not enable shell tracing while these variables are
present:

```bash
export KDEDECK_ANDROID_SIGNING_REQUIRED=true
export KDEDECK_ANDROID_KEYSTORE_PATH="$PWD/kdedeck_mobile/android/keystore/kdedeck-release.jks"
export KDEDECK_ANDROID_KEYSTORE_PASSWORD='(keystore password)'
export KDEDECK_ANDROID_KEY_ALIAS='kdedeck-release'
export KDEDECK_ANDROID_KEY_PASSWORD='(key password)'

mkdir -p artifacts
cd kdedeck_mobile
flutter build apk --release
cd ..
cp kdedeck_mobile/build/app/outputs/flutter-apk/app-release.apk artifacts/app-release.apk
sh scripts/check-release-artifacts.sh artifacts
sh scripts/check-android-signing.sh artifacts/app-release.apk --require-release
```

Unset the variables after the build. The resulting `artifacts/app-release.apk`
can be copied to a phone, shared from a trusted HTTPS location, or attached to
a GitHub Release. Users must enable installation from the source they chose in
Android settings and explicitly confirm the APK installation.

## GitHub Releases through Actions

The checked-in `.github/workflows/android-release.yml` runs when a `v*` tag is
pushed. Before creating the tag, configure these **repository Actions secrets**
under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `KDEDECK_ANDROID_KEYSTORE_BASE64` | Base64 of the binary `.jks` keystore |
| `KDEDECK_ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `KDEDECK_ANDROID_KEY_ALIAS` | The alias passed to `keytool` |
| `KDEDECK_ANDROID_KEY_PASSWORD` | Password for that alias |

For a Linux runner, create the first value locally with
`base64 -w 0 kdedeck_mobile/android/keystore/kdedeck-release.jks` and paste the
single-line output into the secret. On macOS, use
`base64 kdedeck_mobile/android/keystore/kdedeck-release.jks | tr -d '\n'`.
These commands read the local keystore; they do not belong in a workflow or
tracked file.

The workflow materializes the keystore under the ephemeral GitHub runner temp
directory, builds the APK with signing required, verifies that it is not debug
signed, and publishes `app-release.apk` with `gh release create`. If any secret
is missing or the decoded keystore is invalid, the job fails before publishing.
The workflow needs the repository's normal tag-push permission (`contents:
write` is declared in the workflow). Protect release tags if contributors must
not be able to publish an APK.

The ordinary `CI` workflow intentionally continues to build a debug-signed
validation APK and uploads it only as a workflow artifact. Do not copy that
artifact into a public release. Use the tag workflow, or run the local
production procedure above, for distributable APKs.
