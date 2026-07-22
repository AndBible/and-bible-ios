# JSword versification mappings

The `.properties` files in this directory are copied without semantic modification from
AndBible's JSword submodule at commit `0da7412d7716731f402c9002a0b92e4c00ef30eb`:

`src/main/resources/org/crosswire/jsword/versification`

They define Android's non-identity mappings to the KJVA intermediate canon. Each source file
contains its LGPL-2.1-or-later distribution notice. Keep these files synchronized with the JSword
revision pinned by the Android app; do not regenerate them from libsword, whose built-in mapping
coverage differs for several canons.

`canons.json` is generated from `Versifications` at the same JSword revision. It records each
system's ordered OSIS books and last verse for chapter zero through the final chapter. The iOS
mapper uses it to expand ranges and validate coordinates with Android's dimensions instead of
mixing JSword rules with similarly named libsword canon tables.
