#!/usr/bin/env bash
# Archive the iOS app and upload it to App Store Connect / TestFlight.
#
# The App Store Connect API key is GPG-encrypted (to the developer's YubiKey).
# Apple's uploader (Transporter/altool, invoked by xcodebuild) requires the key
# as a file on disk, so we decrypt it onto a RAM-backed volume and eject it on
# exit. This avoids writing the plaintext key to the normal filesystem; it is
# not an absolute guarantee, since macOS can still page memory to swap or capture
# it in a crash dump.
#
# Secrets are NOT stored in this script. Provide them via the environment:
#   ASC_KEY_ID=<keyid> ASC_ISSUER_ID=<uuid> ./scripts/upload-testflight.sh
# The encrypted key lives outside the repo (default: ~/.appstoreconnect/...).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

PROJECT="AndBible.xcodeproj"
SCHEME="AndBible"
ARCHIVE="build/AndBible.xcarchive"
EXPORT_DIR="build/export"
EXPORT_OPTS="build/ExportOptions.plist"
INFOPLIST="AndBible/Info.plist"

# shellcheck source=scripts/lib-asc-api-key.sh
. "$SCRIPT_DIR/lib-asc-api-key.sh"

# asc_prepare_api_key installs its own `trap ... EXIT` for the RAM disk while it
# runs (protecting it even if a later line in this function fails). Only AFTER
# it returns do we install `cleanup` as the EXIT trap: `trap` registrations are
# last-one-wins, so registering `cleanup` here — after, not before,
# asc_prepare_api_key — is what makes it the trap that is actually live for the
# rest of the script. `cleanup` calls asc_cleanup_api_key itself, so the RAM
# disk is still ejected either way; registering in the other order would mean
# asc_prepare_api_key's own trap silently wins instead and the Info.plist
# restore below would never run.
asc_prepare_api_key

INFOPLIST_BAK=""
cleanup() {
	# Eject the RAM disk FIRST and unconditionally. It holds the decrypted key,
	# so ejecting it must never be skipped by a failure below - under this
	# script's `set -e`, a failing command anywhere in this function body would
	# otherwise abort the function and leave the volume mounted.
	asc_cleanup_api_key
	# Restore the original Info.plist byte-for-byte. PlistBuddy reorders keys on
	# write, so restoring a saved copy (not re-setting the version) keeps the
	# tree clean. A failed restore is reported (mv's own stderr is not
	# suppressed) but must not be fatal - the `||` keeps `set -e` from treating
	# it as a reason to skip anything that might follow.
	if [ -n "$INFOPLIST_BAK" ] && [ -f "$INFOPLIST_BAK" ]; then
		mv -f "$INFOPLIST_BAK" "$INFOPLIST" || echo ">> WARNING: failed to restore $INFOPLIST from $INFOPLIST_BAK - the stamped build number is still in your working tree." >&2
	fi
}
trap cleanup EXIT

KEYFILE="$ASC_KEY_FILE"
KEYDIR="$(dirname "$KEYFILE")"
TEAM_ID="$ASC_TEAM_ID"
KEY_ID="$ASC_KEY_ID"
ISSUER_ID="$ASC_ISSUER_ID"

# 2) Generate export options with the locally resolved team (kept out of the repo).
mkdir -p "$(dirname "$EXPORT_OPTS")"
cat > "$EXPORT_OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<!-- Automatic (cloud) signing: the Admin App Store Connect API key creates and
	     downloads the iOS Distribution certificate and App Store provisioning
	     profile on demand. Requires xcodebuild -allowProvisioningUpdates. -->
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

# 3) Archive (iOS only — no Mac Catalyst). Set REUSE_ARCHIVE=1 to skip and reuse
#    an existing archive (handy when iterating on the export/upload step).
if [ "${REUSE_ARCHIVE:-0}" = "1" ] && [ -d "$ARCHIVE" ]; then
	echo ">> Reusing existing archive: $ARCHIVE"
else
	# Unique, increasing build number (UTC YYYY.MMDD.HHMMSS). Back up the original
	# plist first; cleanup restores it on exit so the working tree stays clean and
	# successive uploads never collide.
	INFOPLIST_BAK="build/Info.plist.orig"
	cp "$INFOPLIST" "$INFOPLIST_BAK"
	BUILD_NUMBER="$(date -u '+%Y.%m%d.%H%M%S')"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFOPLIST"
	echo ">> Archiving (build $BUILD_NUMBER)…"
	xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
		-sdk iphoneos -destination 'generic/platform=iOS' \
		-archivePath "$ARCHIVE" -allowProvisioningUpdates \
		-authenticationKeyPath "$KEYFILE" \
		-authenticationKeyID "$KEY_ID" \
		-authenticationKeyIssuerID "$ISSUER_ID" \
		clean archive
fi

# 4) Export + upload to App Store Connect.
echo ">> Exporting and uploading…"
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportOptionsPlist "$EXPORT_OPTS" \
	-exportPath "$EXPORT_DIR" \
	-allowProvisioningUpdates \
	-authenticationKeyPath "$KEYFILE" \
	-authenticationKeyID "$KEY_ID" \
	-authenticationKeyIssuerID "$ISSUER_ID"

echo ">> Done. Build uploaded to App Store Connect (TestFlight processing)."
