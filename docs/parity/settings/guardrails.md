# SETPAR-603 Localization Guardrails

## Purpose

Prevent regressions in settings localization parity by enforcing:

1. `AndBible/*.lproj` and `Localizations/*.lproj` stay in sync for parity settings keys.
2. iOS does not keep English strings when Android already has non-English translations.
3. English-placeholder counts per key do not increase above the committed baseline.
4. `SettingsView.localeOptions` stays source-backed against Android
   `prefs_interface_locale_values`, filtered only by shipped iOS `.lproj`
   availability.

## Command

```bash
python3 scripts/check_settings_localization_guardrails.py
```

By default the script uses live Android resources from:

- `../and-bible/app/src/main/res` (when available)

If that path is missing (for example in CI), it automatically falls back to:

- `docs/parity/settings/baselines/localization-android.json`

## Baseline Update

Only run after intentional localization changes:

```bash
python3 scripts/check_settings_localization_guardrails.py --write-baseline
```

This updates:

- `docs/parity/settings/baselines/localization-guardrail.json`

## Android Snapshot Update

Only run when Android source translations changed and you want to refresh the CI fallback snapshot:

```bash
python3 scripts/check_settings_localization_guardrails.py --write-android-snapshot
```

This updates:

- `docs/parity/settings/baselines/localization-android.json`

The snapshot includes both Android non-English settings-string coverage and the
Android `locale_pref` label/value arrays used by CI when the Android checkout is
not present.

## Notes

- Baseline is keyed to the current parity-key set and locale set.
- If Android adds new locale translations, iOS will fail guardrails until matching translations are added (or explicitly updated via approved baseline process).
- If Android adds a `locale_pref` value, the guardrail fails until iOS either
  ships a matching localization resource and exposes the value in Android order,
  or documents the value as unavailable by leaving it filtered out.
- iOS localization resources that Android does not expose in
  `prefs_interface_locale_values` must not become iOS-only picker values.
- CI integration: `.github/workflows/ios-ci.yml` runs this guardrail on pull requests and `main` pushes.

## Current Automation Status

- This is the strongest machine-readable parity guardrail in the current repo.
- Current protection is a combination of:
  - `scripts/check_settings_localization_guardrails.py`
  - committed Android snapshot and baseline files in `baselines/`
  - CI execution through `.github/workflows/ios-ci.yml`
  - settings verification and regression reports in this directory

## Potential Improvements

- add machine-readable guardrails for non-localization settings contracts if the
  key surface grows materially
- add a more focused standard rerun path for high-risk nested settings UI
  workflows if that area expands further
