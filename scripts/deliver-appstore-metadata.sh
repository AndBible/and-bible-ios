#!/usr/bin/env bash
# Upload App Store Connect text metadata with fastlane deliver.
#
# Text only: no binary, no screenshots, no review submission. Screenshots are
# uploaded by hand and the Deliverfile is configured not to touch them.
#
#   ./scripts/deliver-appstore-metadata.sh            # upload
#   ./scripts/deliver-appstore-metadata.sh precheck   # Apple's metadata rules
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

MODE="${1:-deliver}"

command -v fastlane >/dev/null || {
	echo "fastlane is not installed. brew install fastlane" >&2
	exit 1
}

echo ">> Validating the metadata tree before uploading…"
python3 scripts/assemble_appstore_metadata.py --check

# shellcheck source=scripts/lib-asc-api-key.sh
. "$SCRIPT_DIR/lib-asc-api-key.sh"
asc_prepare_api_key

case "$MODE" in
	deliver)
		fastlane deliver --api_key_path "$ASC_KEY_JSON" --team_id "$ASC_TEAM_ID"
		;;
	precheck)
		fastlane precheck --api_key_path "$ASC_KEY_JSON" --team_id "$ASC_TEAM_ID"
		;;
	*)
		echo "Unknown mode: $MODE (expected 'deliver' or 'precheck')" >&2
		exit 2
		;;
esac
