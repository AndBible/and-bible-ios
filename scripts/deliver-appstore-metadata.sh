#!/usr/bin/env bash
# Upload App Store Connect text metadata with fastlane deliver.
#
# Text only: no binary, no screenshots, no review submission. Screenshots are
# uploaded by hand and the Deliverfile is configured not to touch them.
#
# fastlane/Deliverfile sets `force true`, which skips deliver's interactive
# HTML preview confirmation, and `deliver` has no dry-run mode: a `deliver`
# run pushes every locale directory under fastlane/metadata/ (currently 34)
# plus the app-level copyright.txt/primary_category.txt/secondary_category.txt
# in one shot, live, on the App Store Connect listing. If that listing
# currently has fewer locales enabled than this tree carries, the run
# creates/enables the rest with no separate warning beyond what this script
# prints below. Run `make appstore-precheck` (Apple's own metadata rules
# against the live listing) AFTER the first real `make appstore-deliver`, not
# before: `fastlane precheck` inspects the metadata App Store Connect
# currently holds, so before an upload it can only check the OLD listing —
# and for a first release there is nothing there at all.
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

if [ "$MODE" = "deliver" ]; then
	# Print the blast radius at the moment of running, not only in a comment in
	# this file - counted rather than hardcoded, so it can't silently go stale.
	# Portable globbing only (no GNU-only `find -printf`): this also runs on
	# macOS's BSD find/basename.
	METADATA_DIR="fastlane/metadata"
	locale_count=0
	for d in "$METADATA_DIR"/*/; do
		name="${d%/}"
		name="${name##*/}"
		[ "$name" = "review_information" ] && continue
		locale_count=$((locale_count + 1))
	done
	app_level_files=""
	for f in "$METADATA_DIR"/*.txt; do
		[ -e "$f" ] || continue
		app_level_files="$app_level_files $(basename "$f")"
	done
	echo ">> About to push text metadata for $locale_count locale(s) to the live App Store Connect listing."
	echo ">> force=true: no preview/confirmation prompt. deliver has no dry-run mode."
	echo ">> App-level fields overwritten globally:$app_level_files"
fi

# shellcheck source=scripts/lib-asc-api-key.sh
. "$SCRIPT_DIR/lib-asc-api-key.sh"
asc_prepare_api_key

# --team_id is deliberately NOT passed to deliver/precheck. ASC_TEAM_ID
# resolves to the ten-character Apple Developer Portal team (from
# DEVELOPMENT_TEAM in Config/Secrets.xcconfig.local) - the value ExportOptions'
# teamID needs for xcodebuild. deliver/precheck's own --team_id option instead
# expects the numeric App Store Connect team (fastlane's dev_portal_team_id is
# the portal one, and isn't what these commands take either), so passing
# ASC_TEAM_ID here would be silently wrong, not merely redundant. The API key
# plus fastlane/Appfile's app_identifier already scope the request
# unambiguously - do not add --team_id back.
case "$MODE" in
	deliver)
		fastlane deliver --api_key_path "$ASC_KEY_JSON"
		;;
	precheck)
		fastlane precheck --api_key_path "$ASC_KEY_JSON"
		;;
	*)
		echo "Unknown mode: $MODE (expected 'deliver' or 'precheck')" >&2
		exit 2
		;;
esac
