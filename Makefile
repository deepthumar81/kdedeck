.PHONY: release-check release-artifact-check android-signing-check alpha-source-check alpha-readiness-check alpha-release-check test-environment-check tls-smoke test

APK ?= artifacts/app-release.apk
ARTIFACT_DIR ?= artifacts
SIGNING_MODE ?= allow-debug
ACCEPTANCE_MODE ?= allow-pending
TEST_TIMEOUT ?= 180s

release-check:
	sh scripts/check-release-metadata.sh

release-artifact-check:
	sh scripts/check-release-artifacts.sh $(ARTIFACT_DIR)

android-signing-check:
	sh scripts/check-android-signing.sh $(APK) $(SIGNING_MODE)

alpha-source-check:
	sh scripts/check-alpha-readiness.sh --source-only

alpha-readiness-check:
	sh scripts/check-alpha-readiness.sh $(ARTIFACT_DIR) $(SIGNING_MODE) $(ACCEPTANCE_MODE)

alpha-release-check:
	sh scripts/check-alpha-readiness.sh $(ARTIFACT_DIR) --require-release --require-acceptance

test-environment-check:
	@missing=0; \
	for tool in dart flutter node go timeout; do \
		if ! command -v "$$tool" >/dev/null 2>&1; then \
			printf 'test environment missing required command: %s\n' "$$tool" >&2; \
			missing=1; \
		fi; \
	done; \
	exit "$$missing"

tls-smoke:
	cd deckboard_daemon/backend && timeout --foreground $(TEST_TIMEOUT) dart run tool/tls_android_smoke.dart

test: test-environment-check release-check alpha-source-check
	cd deckboard_daemon/backend && timeout --foreground $(TEST_TIMEOUT) dart test -j 1
	$(MAKE) tls-smoke
	timeout --foreground $(TEST_TIMEOUT) node --test deckboard_daemon/frontend/ui_policy.test.mjs
	timeout --foreground $(TEST_TIMEOUT) node --test deckboard_daemon/frontend/browser_e2e.test.mjs
	timeout --foreground $(TEST_TIMEOUT) node --check deckboard_daemon/frontend/app.js
	cd deckboard_daemon/tray && timeout --foreground $(TEST_TIMEOUT) go test ./...
	cd deckboard_daemon/tray && timeout --foreground $(TEST_TIMEOUT) go vet ./...
	cd kdedeck_mobile && timeout --foreground $(TEST_TIMEOUT) flutter test
