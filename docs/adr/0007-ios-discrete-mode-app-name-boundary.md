# 0007: iOS Discrete Mode App Name Boundary

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

iOS discrete mode is an adapted parity implementation, not a complete runtime
identity swap.

iOS must:

- use `UIApplication.setAlternateIconName("CalculatorIcon")` when
  `discrete_mode` is enabled and restore the primary icon when disabled
- package iPhone and iPad alternate icon resources in `CFBundleIcons` and
  `CFBundleIcons~ipad`
- keep `CFBundleDisplayName` fixed for the installed app bundle
- keep settings and help copy honest that iOS changes the launcher icon only and
  cannot change the app display name at runtime

iOS must not:

- promise that the app name changes when the in-app `discrete_mode` toggle is
  enabled
- try to mutate Info.plist, localized bundle resources, or signed app metadata
  at runtime
- implement an app-controlled shortcut, notification label, or internal title
  change as a substitute for changing the Home Screen app name

If product requirements need Android discrete-flavor semantics on iOS, that is a
separate distribution decision: create a dedicated target/SKU/build flavor with
a fixed calculator display name and icon, then review App Store, signing,
localization, support, and migration implications. It should not be implemented
as a runtime setting inside the standard iOS app bundle.

## Consequences

- `discrete_mode` remains `Adapted Pass` in the iOS settings parity matrix.
- The standard iOS app can show a calculator alternate icon, including iPad's
  required 152x152 alternate icon asset, but its Home Screen label remains the
  bundle display name.
- Tests should guard the alternate icon metadata and bundled PNG size contract,
  not assert a runtime app-name change.
- Future copy changes must preserve the iOS limitation instead of importing the
  Android "rename the app" summary verbatim.
- A future fully disguised iOS app identity requires a separate build/distribution
  ADR rather than weakening this runtime boundary.

## Related

- [Android Settings Contract](../parity/settings/contract.md)
- [SETPAR-701 Verification Matrix](../parity/settings/verification-matrix.md)
- [Apple CFBundleDisplayName](https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundledisplayname)
- [Apple CFBundleIcons](https://developer.apple.com/documentation/bundleresources/information_property_list/cfbundleicons)
- [Apple alternate app icons](https://developer.apple.com/documentation/xcode/configuring-your-app-to-use-alternate-app-icons)
- [UIApplication.setAlternateIconName(_:completionHandler:)](https://developer.apple.com/documentation/uikit/uiapplication/setalternateiconname(_:completionhandler:))
