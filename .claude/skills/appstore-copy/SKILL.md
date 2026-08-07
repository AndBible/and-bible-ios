---
name: appstore-copy
description: Use when App Store listing copy needs translating or refreshing - the subtitle, keywords and promotional text in appstore/ios_source.yml, and the iOS overrides of the Android description keys. Trigger on "translate the App Store copy", "appstore-validate says locales fall back to English", or after editing appstore/ios_source.yml.
---

# Translating the App Store copy

The App Store description prose comes from the Android repository's Transifex
translations and needs no work here. What this skill covers is the iOS-only
layer: `appstore/ios_source.yml`, translated into
`appstore/ios_translations/<apple-locale>.yml`.

## Find what needs work

```bash
python3 .claude/skills/appstore-copy/find_stale.py
```

Each line is `missing <locale>` (never translated) or `stale <locale>`
(translated against an older English source). Dispatch **one subagent per
locale**, five to eight in parallel.

## What each subagent is given

- the full English `appstore/ios_source.yml`
- the matching Android translation, `<android-root>/play/description-translations/<play-locale>.yml`,
  as the authority for terminology and register — the Play copy is human-translated
  and the App Store copy must not contradict it
- the character limits, as hard constraints

## What each subagent writes

`appstore/ios_translations/<apple-locale>.yml`, with every key from
`ios_source.yml` plus `source_sha`:

```yaml
source_sha: <the digest printed by find_stale.py's --digest flag>
subtitle: "..."
keywords: "..."
promotional_text: >
  ...
feature_08: >
  ...
```

## Rules the subagents must follow

- **Translate idiomatically, not literally.** This is marketing copy. Match the
  register of the Android translation for the same language.
- **The character limits are constraints on the writing, not a truncation step.**
  subtitle 30, keywords 100, promotional_text 170. A translation that overflows
  must be rewritten shorter, never cut off mid-word.
- **The whole rendered description must also stay within 4000 characters, and
  the headroom is already thin.** The description is built from the Android
  translation plus the three feature overrides this skill translates
  (`feature_08`, `feature_09`, `feature_11`); replacing an English override
  sentence with a translated one that is merely "correct" can push the total
  over the limit, because translated text is typically longer than English.
  Headroom shifts every time a translation changes, so don't rely on a number
  written in this file — compute it fresh before you start:

  ```bash
  python3 - <<'PY'
  import sys
  sys.path.insert(0, "scripts")
  import appstore_metadata as meta
  from pathlib import Path

  sources = meta.load_sources(meta.resolve_android_root(Path(".")), Path("appstore"))
  rows = sorted(
      (4000 - len(fields["description"]), apple, len(fields["description"]))
      for play, apple in sources.locale_config.mappings
      for fields in [meta.build_locale_fields(sources, play, apple)]
  )
  for headroom, apple, length in rows[:8]:
      print(f"{apple}: {length}/4000 ({headroom} headroom)")
  PY
  ```

  The tightest locales are the ones with the smallest headroom in that output.
  **Write each translated feature override at or under the English source's
  character length.** This is a constraint on the writing itself, not
  something to fix by truncating afterwards. `make appstore-validate` is what
  enforces the 4000-character total; if it fails on a locale you touched,
  shorten the override's wording, don't cut it off.
- **Keywords are search terms, not a sentence.** Comma separated, no space after
  the comma (it counts against the limit). Do not repeat words that already
  appear in the app name or subtitle — the App Store indexes those anyway.
- **Never write the words Android, Google Play or Play Store.** The validator
  rejects them in any field, in any locale.
- **Leave `{{ variable }}` references untouched** and in a grammatical position.
- **Leave a key out rather than guess.** An absent key falls back to English,
  which is better than a wrong translation.

## Finish

```bash
make appstore-metadata
make appstore-validate
```

`appstore-validate` enforces every limit, including the 4000-character
description total. If a locale overflows, send it back to a subagent with the
measured length — do not truncate it yourself.
