.PHONY: release-check release-artifact-check tls-smoke test

release-check:
	sh scripts/check-release-metadata.sh

release-artifact-check:
	sh scripts/check-release-artifacts.sh $(ARTIFACT_DIR)

tls-smoke:
	cd deckboard_daemon/backend && dart run tool/tls_android_smoke.dart

test: release-check
	cd deckboard_daemon/backend && dart test -j 1
	$(MAKE) tls-smoke
	node --test deckboard_daemon/frontend/ui_policy.test.mjs
	node --test deckboard_daemon/frontend/browser_e2e.test.mjs
	node --check deckboard_daemon/frontend/app.js
	cd deckboard_daemon/tray && go test ./...
	cd deckboard_daemon/tray && go vet ./...
	cd kdedeck_mobile && flutter test
