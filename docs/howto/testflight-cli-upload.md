# TestFlight CLI upload

Archive and upload a build to App Store Connect / TestFlight from the command
line, without storing the App Store Connect API key in plaintext on disk.

```bash
make testflight
```

That runs `scripts/upload-testflight.sh`, which:

1. Decrypts the App Store Connect API key onto a RAM-backed volume (the plaintext
   `.p8` never touches the SSD; the volume is ejected on exit).
2. Stamps a unique build number (UTC `YYYY.MMDD.HHMM`, restored afterward so the
   working tree stays clean).
3. Archives the app for iOS (no Mac Catalyst) and uploads it via Xcode automatic
   (cloud) signing.

## One-time setup

1. **Create an App Store Connect API key** with the **Admin** role
   (App Store Connect → Users and Access → Integrations). Admin is required because
   Xcode cloud signing creates/downloads the iOS Distribution certificate and the
   App Store provisioning profile via the API; App Manager / Developer keys cannot.

2. **Encrypt the key to your GPG key and keep it out of the repo.** Apple's
   uploader needs the key as a file, so the script decrypts it to a RAM disk at
   run time — but the at-rest copy stays encrypted:

   ```bash
   mkdir -p ~/.appstoreconnect/private_keys
   gpg --encrypt --recipient you@example.com \
       --output ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8.gpg \
       ~/Downloads/AuthKey_<KEYID>.p8
   rm -P ~/Downloads/AuthKey_<KEYID>.p8     # shred the plaintext
   ```

   Back the encrypted blob up somewhere safe — App Store Connect only lets you
   download the `.p8` once.

3. **Record the identifiers** (not secret, but kept out of the repo) in
   `~/.appstoreconnect/asc-api.env`:

   ```sh
   ASC_ISSUER_ID=<issuer-uuid>
   ASC_KEY_ID=<KEYID>
   ```

   The `Makefile` reads this file automatically.

## Options

- `REUSE_ARCHIVE=1 make testflight` — skip archiving and re-export an existing
  `build/AndBible.xcarchive` (useful when iterating on the upload step).
- Override `ASC_ISSUER_ID`, `ASC_KEY_ID`, or `ASC_KEY_GPG` via the environment.

## Notes

- The encrypted key, the `asc-api.env`, and the decrypted RAM-disk copy all live
  outside the repository. `*.p8` is gitignored as a safety net.
- App Store Connect emits a "Missing Document Configuration" warning on upload —
  tracked separately (the app declares `CFBundleDocumentTypes` but does not yet
  wire external file opening).
