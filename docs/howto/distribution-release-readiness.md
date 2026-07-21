# Distribution Release Readiness

Repository checks prove target metadata, built simulator products, and runtime launch behavior. They
cannot prove Apple Developer Portal state, CloudKit deployment state, App Store Connect records, or
physical-device behavior. Release approval therefore uses a two-stage handoff: one workflow run
builds immutable signed candidates, and a later run validates completed evidence against those exact
archives without rebuilding them.

## Required Inputs

1. A successful `prepare` run of the **Distribution Release Readiness** workflow.
2. Physical-device testing performed from both `.xcarchive` candidates downloaded from that run.
3. The prepare run ID and its generated `release-archive-binding.json`.
4. An evidence JSON derived from
   `scripts/fixtures/distribution-release-evidence.example.json`, with every ID populated and every
   boolean backed by an attached portal export, screenshot, `xcresult`, or release ticket artifact.
   Copy the generated binding values exactly and set `release_binding.validated_at` only after all
   physical-device checks pass.

## Workflow Handoff

1. Dispatch the workflow with `phase=prepare` on the release commit. It installs Node dependencies,
   builds the production Vue bundle before SwiftPM resolution, archives both signed products, verifies
   the exact BibleView resource embedded in each archive, and uploads tar-wrapped candidates plus a
   binding template. Tar is used so GitHub artifact transport cannot rewrite archive symlinks.
2. Download those exact candidates and perform co-installation and CloudKit isolation checks on
   physical devices. Keep the generated archive hashes, versions, builds, creation times, and commit
   SHA unchanged in the evidence document.
3. Store the completed JSON in `DISTRIBUTION_RELEASE_EVIDENCE_JSON` and dispatch the same workflow
   commit with `phase=validate` and `archive_run_id=<prepare run ID>`.
4. Validation verifies the prepare run provenance, downloads and extracts its candidates, recomputes
   each archive-tree hash, checks the packaged production Vue resources, and evaluates signatures,
   profiles, metadata, and external evidence. It never rebuilds an archive.

Prepare artifacts are retained for seven days. The completed `validated_at` timestamp must postdate
both archives, must not be in the future beyond the five-minute clock-skew allowance, and must be no
more than 168 hours old when validation runs.

## Local Validator

The same validator can write a binding template for already-created archives:

```bash
python3 scripts/validate_distribution_release_readiness.py \
  --standard-archive /path/to/AndBible.xcarchive \
  --calculator-archive /path/to/Calculator.xcarchive \
  --expected-commit-sha 0123456789abcdef0123456789abcdef01234567 \
  --write-binding /path/to/release-archive-binding.json
```

After testing those exact archives and completing schema-v2 evidence, validate with:

```bash
python3 scripts/validate_distribution_release_readiness.py \
  --standard-archive /path/to/AndBible.xcarchive \
  --calculator-archive /path/to/Calculator.xcarchive \
  --expected-commit-sha 0123456789abcdef0123456789abcdef01234567 \
  --team-identifier TEAMID1234 \
  --evidence /path/to/distribution-release-evidence.json
```

The archive SHA-256 is canonical over relative directories, file bytes, and symlink targets. Host
ownership and timestamps are excluded so tar handoff preserves identity. The validator also checks
each archive's processed identity and document declarations, verifies the signature, decodes the
embedded provisioning profile, checks profile expiry and App ID, and requires an Apple distribution
certificate plus an App Store profile rather than Ad Hoc, development, or enterprise provisioning.
It requires the exact product CloudKit container in both signed and profile entitlements and compares
the embedded profile UUID with the supplied Apple Developer Portal evidence.

## External Evidence

The evidence document must identify:

- the exact workflow commit and both prepared archive hashes, versions, builds, and creation times;
- a fresh physical-validation timestamp that postdates both archives;
- both explicit App ID records and their association to the exact CloudKit container;
- both distribution provisioning profile UUIDs;
- development and production schema deployment for both CloudKit containers;
- both App Store Connect app record IDs;
- a physical-device run proving both products co-install;
- successful CloudKit round trips in each product and proof that neither product sees the other's
  records.

An ID in the JSON is a pointer to external evidence, not proof by itself. Keep the referenced
artifacts with the release record. Reusing evidence from another commit, build, or archive is rejected
even when all booleans remain true. The workflow and script intentionally fail when any input is
missing; repository code alone never satisfies this checklist.
