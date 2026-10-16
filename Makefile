.PHONY: test

test:
	cd deckboard_daemon/backend && dart test -j 1
	node --test deckboard_daemon/frontend/ui_policy.test.mjs
	node --test deckboard_daemon/frontend/browser_e2e.test.mjs
	node --check deckboard_daemon/frontend/app.js
	cd deckboard_daemon/tray && go test ./...
	cd deckboard_daemon/tray && go vet ./...
	cd kdedeck_mobile && flutter test
