#!/usr/bin/env bash
# Archive the iOS app and upload it to App Store Connect / TestFlight.
#
# The App Store Connect API key is GPG-encrypted (to the developer's YubiKey).
# Apple's uploader (Transporter/altool, invoked by xcodebuild) requires the key
# as a file on disk, so we decrypt it onto a RAM-backed volume that exists only
# in memory and is ejected on exit — the plaintext .p8 never touches the SSD.
#
# Secrets are NOT stored in this script. Provide them via the environment:
#   ASC_ISSUER_ID=<uuid> ./scripts/upload-testflight.sh
# The encrypted key lives outside the repo (default: ~/.appstoreconnect/...).
set -euo pipefail

PROJECT="AndBible.xcodeproj"
SCHEME="AndBible"
KEY_ID="${ASC_KEY_ID:-7F76P3UCYV}"
ISSUER_ID="${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to the App Store Connect API issuer UUID}"
ENC_KEY="${ASC_KEY_GPG:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8.gpg}"
ARCHIVE="build/AndBible.xcarchive"
EXPORT_DIR="build/export"
EXPORT_OPTS="scripts/ExportOptions.plist"
INFOPLIST="AndBible/Info.plist"

[ -f "$ENC_KEY" ] || { echo "Encrypted key not found: $ENC_KEY" >&2; exit 1; }

# 1) RAM-backed volume for the decrypted key (auto-ejected on exit).
# hdiutil pads the device node with trailing spaces/tabs — trim it, or diskutil
# can't find the disk.
RAM_DEV="$(hdiutil attach -nomount ram://40960 | tr -d '[:space:]')"   # ~20 MB
diskutil erasevolume HFS+ asckey "$RAM_DEV" >/dev/null
KEYDIR="/Volumes/asckey"
RESTORE_BUILD=""
cleanup() {
	[ -n "$RESTORE_BUILD" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RESTORE_BUILD" "$INFOPLIST" >/dev/null 2>&1
	hdiutil detach "$RAM_DEV" >/dev/null 2>&1 || diskutil eject "$RAM_DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT
KEYFILE="$KEYDIR/AuthKey_${KEY_ID}.p8"
# Create the file and lock its permissions BEFORE any plaintext is written, so the
# decrypted key is never even momentarily readable by other users. The `>` redirect
# truncates the existing file without changing its mode, so 600 is preserved.
touch "$KEYFILE"
chmod 600 "$KEYFILE"
echo ">> Decrypting API key onto RAM disk (YubiKey PIN + touch may be required)…"
gpg --quiet --decrypt "$ENC_KEY" > "$KEYFILE"

# 2) Archive (iOS only — no Mac Catalyst). Set REUSE_ARCHIVE=1 to skip and reuse
#    an existing archive (handy when iterating on the export/upload step).
if [ "${REUSE_ARCHIVE:-0}" = "1" ] && [ -d "$ARCHIVE" ]; then
	echo ">> Reusing existing archive: $ARCHIVE"
else
	# Unique, increasing build number (UTC YYYY.MMDD.HHMM), restored on exit so the
	# working tree stays clean and successive uploads never collide.
	RESTORE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFOPLIST")"
	BUILD_NUMBER="$(date -u '+%Y.%m%d.%H%M')"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFOPLIST"
	echo ">> Archiving (build $BUILD_NUMBER)…"
	xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
		-sdk iphoneos -destination 'generic/platform=iOS' \
		-archivePath "$ARCHIVE" -allowProvisioningUpdates \
		clean archive
fi

# 3) Export + upload to App Store Connect.
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
