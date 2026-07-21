# 0007: iOS Discrete SKU and Runtime Icon Boundary

Status: Accepted

Date: 2026-06-30

## Context

Android's standard app build can change launcher identity at runtime by toggling
between launcher activity aliases. The normal launcher entry uses
`@string/app_name_short` and the calculator alias uses
`@string/app_name_calculator`; `CommonUtils.changeAppIconAndName()` enables the
active component and disables the inactive component. Android's discrete flavor
goes further by baking the calculator identity into flavor resources:
`app/src/discrete/res/values/strings.xml` maps `app_name_short` to
`app_name_calculator`, and `app/src/discrete/AndroidManifest.xml` enables the
calculator launcher alias.

iOS has a narrower public runtime surface. The app's visible name is declared in
bundle metadata through `CFBundleDisplayName`, and alternate launcher icons are
declared through `CFBundleIcons` / `CFBundleIcons~ipad`. At runtime,
`UIApplication.setAlternateIconName(_:completionHandler:)` accepts an alternate
icon name only; it does not accept a display name. The signed app bundle's
Info.plist and localized `InfoPlist.strings` resources are install-time
metadata, not app-controlled runtime settings.

That makes Android's full "rename the app to Calculator" behavior impossible to
match from an in-app iOS setting. iOS can change the launcher icon when
`discrete_mode` changes, but it cannot rename the installed Home Screen label
without shipping a different bundle, target, flavor, or localization resource
set.

## Decision

iOS ships two explicit identity contracts:

1. The standard `AndBible` target keeps the optional runtime `discrete_mode`
   adaptation. It may switch to the bundled `CalculatorIcon`, but its signed
   display name remains AndBible because iOS cannot rename an installed bundle.
   Product copy must describe this as icon-only and warn that the real signed
   identity remains discoverable in system app information.
2. The `AndBibleDiscrete` target is the Android-discrete-flavor equivalent. It
   builds a separately installable `Calculator.app` with a fixed Calculator
   display name, calculator primary icon, distinct bundle identifier, distinct
   CloudKit container, and calculator gate enforced as a target invariant before
   SwiftUI startup and throughout the process lifetime.

Each target owns a concrete `ANDBIBLE_CLOUDKIT_CONTAINER_IDENTIFIER` build
setting. Xcode writes it to the processed Info.plist as
`AndBibleCloudKitContainerIdentifier`; the app validates that value once and
injects the same typed identifier into both SwiftData and `SyncService`.
Standard uses `iCloud.org.andbible.ios`, while Calculator uses
`iCloud.com.app.calculator.ios`. There is no runtime fallback between them.

The targets also own separate Info.plist source files. Standard advertises the
SWORD ZIP, EPUB, and font document types. Calculator advertises no external
document types, matching Android's discrete flavor, while retaining the shared
in-app import workflow.

The discrete target must hide the runtime `discrete_mode` and `show_calculator`
switches because its identity and launch gate are target invariants. It keeps
Calculator-specific security help and Calculator PIN controls. The standard
target keeps those switches, icon-only disclosure, and a link directing users
who need stronger protection to the Calculator product documentation.

Both targets share application code and Android-compatible settings data. The
target boundary owns product identity; no in-app shortcut, notification label,
or internal title may be used as a substitute for signed bundle metadata.

## Consequences

- The standard app's runtime toggle remains an icon-only platform adaptation.
- Users who require the full disguised identity install the separately signed
  Calculator SKU, matching Android's discrete distribution model.
- App Store records, provisioning profiles, and the
  `iCloud.com.app.calculator.ios` container must be configured before distributing
  the Calculator SKU.
- Structural tests and CI build both target identities so product metadata cannot
  silently collapse back into one bundle. CI inspects processed Info.plists and
  ad-hoc-signed simulator entitlements, installs Calculator, and executes its
  launch-gate/settings-boundary smoke test.
- Repository checks cannot establish Apple-side provisioning. Distribution
  requires the signed-archive and external-evidence gate documented in
  `docs/howto/distribution-release-readiness.md`.

## Related

- [ADR 0008: Parity Documentation Ownership](0008-parity-documentation-ownership.md)
- [Distribution release readiness](../howto/distribution-release-readiness.md)
- [Apple CFBundleDisplayName](https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundledisplayname)
- [Apple CFBundleIcons](https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundleicons)
- [Apple alternate app icons](https://developer.apple.com/documentation/xcode/configuring-your-app-to-use-alternate-app-icons)
- [UIApplication.setAlternateIconName(_:completionHandler:)](https://developer.apple.com/documentation/uikit/uiapplication/setalternateiconname(_:completionhandler:))
