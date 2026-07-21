# Speak localization resources

`divine-name-replacements.json` is generated from Android's
`app/src/main/res/values*/strings.xml` arrays `speak_divinename_original` and
`speak_divinename_replace`.

Regenerate and verify it with:

```sh
python3 scripts/sync_speak_divine_name_catalog.py
python3 scripts/sync_speak_divine_name_catalog.py --check
```

The generator preserves Android resource behavior: a missing localized array inherits the base
English array, while an explicitly empty localized array remains empty.
