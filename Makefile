.PHONY: release-check release-artifact-check android-signing-check alpha-source-check alpha-readiness-check tls-smoke test

APK ?= artifacts/app-release.apk
ARTIFACT_DIR ?= artifacts
SIGNING_MODE ?= allow-debug

release-check:
	sh scripts/check-release-metadata.sh

release-artifact-check:
	sh scripts/check-release-artifacts.sh $(ARTIFACT_DIR)

android-signing-check:
	sh scripts/check-android-signing.sh $(APK) $(SIGNING_MODE)

alpha-source-check:
	sh scripts/check-alpha-readiness.sh --source-only

alpha-readiness-check:
	sh scripts/check-alpha-readiness.sh $(ARTIFACT_DIR) $(SIGNING_MODE)

tls-smoke:
	cd deckboard_daemon/backend && dart run tool/tls_android_smoke.dart

test: release-check alpha-source-check
	cd deckboard_daemon/backend && dart test -j 1
	$(MAKE) tls-smoke
	node --test deckboard_daemon/frontend/ui_policy.test.mjs
	node --test deckboard_daemon/frontend/browser_e2e.test.mjs
	node --check deckboard_daemon/frontend/app.js
	cd deckboard_daemon/tray && go test ./...
	cd deckboard_daemon/tray && go vet ./...
	cd kdedeck_mobile && flutter test
