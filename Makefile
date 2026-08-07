# AndBible iOS — developer convenience targets.
#
# Local-only config (App Store Connect identifiers) is read from outside the repo
# if present, so this file stays free of secrets and identifiers.
-include $(HOME)/.appstoreconnect/asc-api.env
export ASC_ISSUER_ID ASC_KEY_ID ASC_KEY_GPG ASC_TEAM_ID

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
		| awk -F':.*## ' '{ printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }'

.PHONY: testflight
testflight: ## Archive and upload a build to TestFlight (ASC API key decrypted via YubiKey)
	@scripts/upload-testflight.sh

.PHONY: appstore-metadata
appstore-metadata: ## Generate the App Store metadata tree from the Android store copy
	@python3 scripts/assemble_appstore_metadata.py

.PHONY: appstore-validate
appstore-validate: ## Check the metadata tree for drift and rule violations (offline)
	@python3 scripts/assemble_appstore_metadata.py --check

.PHONY: appstore-precheck
appstore-precheck: ## Run Apple's own metadata rules against the live listing (macOS)
	@scripts/deliver-appstore-metadata.sh precheck

.PHONY: appstore-deliver
appstore-deliver: ## Upload App Store text metadata (macOS, YubiKey)
	@scripts/deliver-appstore-metadata.sh
