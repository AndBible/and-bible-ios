"""Dependency-free platform-reference terms forbidden from iOS-facing copy.

Both App Store metadata validation and shipped-localization validation consume
this contract. Keep this module limited to standard-library-free constants so
the localization CI lane does not inherit the metadata generator's PyYAML
dependency merely to enforce the same platform wording boundary.
"""

FORBIDDEN_PLATFORM_REFERENCE_TERMS = ("android", "google play", "play store")
