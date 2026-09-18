"""Dependency-free platform-reference terms forbidden from iOS-facing copy.

Both App Store metadata validation and shipped-localization validation consume
this contract. Keep this module limited to standard-library-free constants so
the localization CI lane does not inherit the metadata generator's PyYAML
dependency merely to enforce the same platform wording boundary.
"""

# Latin-script forms. `validate_fields` lowercases before matching, so these
# are stored lowercase.
_LATIN_TERMS = ("android", "google play", "play store")

# The platform's name transliterated into the scripts AndBible ships in. The
# Latin tuple alone let zh-Hans, ko and he ship the word and cost a rejection
# (Apple submission a2d0a338, 2026-09-08). Lowercasing is a no-op for the
# caseless scripts and correct for Cyrillic. This lists the PLATFORM PRODUCT
# NAME only: the company name is deliberately absent, because this module is
# also consumed by check_settings_localization_guardrails.py, which validates
# shipped in-app strings where Google appears legitimately as an AI provider.
_TRANSLITERATED_TERMS = (
    "安卓",          # zh-Hans, zh-Hant
    "안드로이드",      # ko
    "אנדרואיד",      # he
    "アンドロイド",    # ja
    "андроид",       # ru, bg
    "андроїд",       # uk
    "أندرويد",       # ar
    "एंड्रॉइड",        # hi
    "แอนดรอยด์",      # th
)

FORBIDDEN_PLATFORM_REFERENCE_TERMS = _LATIN_TERMS + _TRANSLITERATED_TERMS
