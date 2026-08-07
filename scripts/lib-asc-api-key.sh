#!/usr/bin/env bash
# Decrypt the App Store Connect API key onto a RAM-backed volume.
#
# Source this file and call asc_prepare_api_key. It sets:
#   ASC_KEY_FILE  path to AuthKey_<id>.p8   (xcodebuild / Transporter)
#   ASC_KEY_JSON  path to asc_api_key.json  (fastlane --api_key_path)
#   ASC_TEAM_ID   the resolved Apple Developer team
# and registers an EXIT trap that ejects the volume. That trap call REPLACES
# any EXIT trap already registered in the calling shell (bash allows only one
# `trap ... EXIT` at a time) - a caller with its own cleanup must register it
# AFTER calling asc_prepare_api_key, not before, or the earlier trap is
# silently discarded and never runs.
#
# The key is GPG-encrypted to the developer's YubiKey. Apple's tooling requires
# it as a file on disk, so it is decrypted onto a RAM disk rather than the normal
# filesystem. That is not an absolute guarantee - macOS can still page memory to
# swap or capture it in a crash dump.

asc_prepare_api_key() {
	local key_id="${ASC_KEY_ID:?Set ASC_KEY_ID to the App Store Connect API key ID}"
	local issuer_id="${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to the App Store Connect API issuer UUID}"
	local enc_key="${ASC_KEY_GPG:-$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8.gpg}"
	local signing_xcconfig="${ASC_SIGNING_XCCONFIG:-Config/Secrets.xcconfig.local}"

	[ -f "$enc_key" ] || { echo "Encrypted key not found: $enc_key" >&2; return 1; }

	ASC_TEAM_ID="${ASC_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
	if [ -z "$ASC_TEAM_ID" ] && [ -f "$signing_xcconfig" ]; then
		ASC_TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$signing_xcconfig" | tr -d '[:space:]')"
	fi
	[ -n "$ASC_TEAM_ID" ] || {
		echo "Could not resolve the Apple Developer team. Set ASC_TEAM_ID or DEVELOPMENT_TEAM in $signing_xcconfig." >&2
		return 1
	}

	# hdiutil pads the device node with trailing whitespace - trim it, or
	# diskutil cannot find the disk. Register cleanup immediately after
	# attaching so a later failure never leaves the RAM disk mounted.
	ASC_RAM_DEV="$(hdiutil attach -nomount ram://40960 | tr -d '[:space:]')"
	# shellcheck disable=SC2064
	trap "asc_cleanup_api_key" EXIT

	local volume_name="asckey-$$"
	diskutil erasevolume HFS+ "$volume_name" "$ASC_RAM_DEV" >/dev/null
	local keydir="/Volumes/$volume_name"
	[ -d "$keydir" ] || { echo "RAM disk mount not found: $keydir" >&2; return 1; }

	ASC_KEY_FILE="$keydir/AuthKey_${key_id}.p8"
	ASC_KEY_JSON="$keydir/asc_api_key.json"

	# Create both files and lock their permissions BEFORE any plaintext is
	# written, so the decrypted key is never even momentarily readable by
	# other users. The > redirect truncates without changing the mode.
	touch "$ASC_KEY_FILE" "$ASC_KEY_JSON"
	chmod 600 "$ASC_KEY_FILE" "$ASC_KEY_JSON"
	echo ">> Decrypting API key onto RAM disk (YubiKey PIN + touch may be required)…"
	gpg --quiet --decrypt "$enc_key" > "$ASC_KEY_FILE"

	KEY_ID="$key_id" ISSUER_ID="$issuer_id" KEY_PATH="$ASC_KEY_FILE" \
		python3 -c '
import json, os
print(json.dumps({
    "key_id": os.environ["KEY_ID"],
    "issuer_id": os.environ["ISSUER_ID"],
    "key": open(os.environ["KEY_PATH"], encoding="utf-8").read(),
    "in_house": False,
}))' > "$ASC_KEY_JSON"

	export ASC_KEY_FILE ASC_KEY_JSON ASC_TEAM_ID
}

asc_cleanup_api_key() {
	if [ -n "${ASC_RAM_DEV:-}" ]; then
		hdiutil detach "$ASC_RAM_DEV" >/dev/null 2>&1 \
			|| diskutil eject "$ASC_RAM_DEV" >/dev/null 2>&1 || true
		ASC_RAM_DEV=""
	fi
}
