# Android Settings Theme Design

## Context

Issue #166 exists because #155 and #159 should not each invent local settings styling. The shared layer must also not redesign AndBible. Android source is the source of truth for row icon assets; the Android screenshots supplied on 2026-05-31 and uploaded to [issue #166](https://github.com/AndBible/and-bible-ios/issues/166#issuecomment-4589085013) are the visual source of truth for how those assets are placed and used:

- [Screenshot_20260531-211552.png](https://github.com/user-attachments/assets/c08b2477-025f-4f74-a17d-cedf31975832)
- [Screenshot_20260531-211609.png](https://github.com/user-attachments/assets/9c515308-bad0-438e-8fec-ac31f8e240e3)
- [Screenshot_20260531-211624.png](https://github.com/user-attachments/assets/16301b49-739d-420a-92e3-232c16039e49)
- [Screenshot_20260531-211630.png](https://github.com/user-attachments/assets/e779d546-9fb2-4b27-97ef-1566629f22ce)

Those screenshots show Android native preference screens that still feel like AndBible through app chrome, left-side monochrome icons, full-width rows, title/summary hierarchy, inline controls, disabled-row states, and reset/help actions in the top bar. The screenshots are dark because the Android app was using a dark theme; they are not a requirement to force a dark settings surface on iOS.

Primary Android icon sources:

- Application preferences row/icon mapping: `and-bible/app/src/main/res/xml/settings.xml`
- Sync settings row/icon mapping: `and-bible/app/src/main/res/xml/sync_settings.xml`
- Drawable/vector assets: `and-bible/app/src/main/res/drawable/`

## Goal

Create reusable native SwiftUI settings presentation primitives that implement the Android settings layout and icon contract closely enough for Application preferences to stop feeling like a generic iOS `Form`, while inheriting the rest of the iOS app’s active theme and preserving native iOS accessibility, navigation, Dynamic Type, and state ownership.

## Non-Goals

- Do not create a new card-based, marketing-style, or iOS-only visual redesign.
- Do not replace native SwiftUI settings with Vue only for implementation symmetry.
- Do not hard-code Application preferences behavior into the shared settings theme.
- Do not invent fake AI settings or other dead rows to visually match Android.
- Do not copy Android dark-mode colors as fixed iOS colors. The iOS settings surface must use the same active theme as the rest of the app.

## Android Visual Contract

The shared settings layer should encode these Android-derived presentation rules:

- Screen chrome uses the app settings title, back affordance, and trailing actions such as reset, search, and help where the screen supports them.
- Content is a plain full-width scrolling list, not nested cards.
- Sections use the app theme’s accent treatment for headers and sparse dividers between major groups.
- Rows have a fixed left icon column with Android-equivalent monochrome iconography.
- Row body uses a prominent title and muted summary text from the active app theme.
- Controls live on the trailing edge: toggles, sliders, chevrons, current values, or action indicators.
- Disabled rows visibly dim title, summary, icon, and control together.
- Touch targets remain generous and row height grows naturally for multi-line summaries.
- Accent controls use the app theme’s accent color instead of generic iOS blue.

## Icon Source Contract

Icons must be sourced from Android source, not inferred from screenshots.

For each iOS settings row that corresponds to an Android preference row:

- Use the `android:icon` drawable reference from `settings.xml` or `sync_settings.xml` as the canonical mapping.
- Port the referenced Android drawable/vector asset into an iOS-friendly asset when licensing and format allow.
- Preserve the Android icon metaphor, silhouette, fixed left-column placement, and disabled-state tinting.
- If a direct Android drawable cannot be reused, document the row-level fallback and choose the nearest faithful native replacement. The fallback is a deviation, not a redesign.
- Keep the mapping in source, tests, or a focused ADR so future Android icon
  changes can be audited against iOS without restoring tracker-style parity
  docs.

The screenshots remain useful for validating size, placement, density, and disabled/active treatment after the source assets are mapped.

## Architecture

Add a small shared SwiftUI presentation layer under `Sources/BibleUI/Sources/BibleUI/Settings/`.

The layer should expose reusable primitives, not a global settings framework:

- `AndBibleSettingsScreen`: wraps settings content with shared background, navigation-title conventions, optional toolbar actions, and search affordance hooks.
- `AndBibleSettingsSection`: renders Android-style section headers, spacing, and major dividers.
- `AndBibleSettingsRow`: renders icon, title, optional summary, optional detail/status, disabled state, and trailing content.
- `AndBibleSettingsNavigationRow`: composes `AndBibleSettingsRow` with `NavigationLink`.
- `AndBibleSettingsActionRow`: composes `AndBibleSettingsRow` with a button role, including destructive/reset styling.
- `AndBibleSettingsIcon`: centralizes the fixed icon column, symbol sizing, and disabled tint behavior.

The first consumer is `SettingsView` for #155. `SyncSettingsView` remains a later consumer under #159, but the primitives must be generic enough for Sync settings rows and status rows.

## Ownership Boundary

Screen-specific views own state, persistence, and side effects.

The shared settings layer owns only presentation:

- layout
- icon treatment
- title/summary/detail hierarchy
- disabled and destructive visual states
- accent color application
- accessibility label/value composition
- Dynamic Type-safe spacing

For example, `SettingsView` decides that `navigate_to_verse_pref` writes through `SettingsStore`; `AndBibleSettingsRow` only decides how that row looks and how its label/summary are exposed.

## Search And Reset Relationship

#166 should provide reusable presentation hooks for toolbar actions and searchable settings lists, but #155 owns the actual Application preferences search and reset behavior.

That means #166 can define row metadata fields needed by #155, such as title, summary, icon, accessibility identifier, and search text. #155 then uses that metadata to filter visible rows and reset persisted values.

## Theming

Use semantic SwiftUI colors and local settings theme tokens so the implementation follows the same active theme as the rest of the app. The Android screenshots define structure and icon treatment, not fixed dark colors.

- background, app chrome, primary text, summary text, and disabled colors come from the existing app/theme environment
- section headers and active controls use the app accent token
- icons are monochrome and theme-tinted unless an Android row requires a deliberate warning/destructive tint
- light and dark themes must both preserve the same Android-derived layout, icon column, and title/summary hierarchy

The implementation should not introduce a separate settings palette. If existing app theme tokens are insufficient, #166 may add narrowly scoped settings aliases that map back to the app theme rather than new standalone colors.

## Accessibility

The primitives must preserve or improve native accessibility:

- Row title and summary are combined into stable accessibility labels/values.
- Toggle, picker, slider, and navigation rows keep native control semantics.
- Icons are decorative unless a row has no text alternative.
- Dynamic Type can wrap summaries without overlapping trailing controls.
- Minimum hit targets remain native-sized.

## Testing

Add focused coverage where it gives signal:

- Unit or view-model tests for any row metadata/search helpers introduced for #155.
- UI accessibility export updates proving primary settings links remain discoverable after rows move into shared primitives.
- Visual behavior should be manually verified in the iOS simulator in both light and dark appearances. Compare layout, icon placement, row hierarchy, and controls against the Android screenshots; verify colors inherit the iOS app theme rather than copying the Android dark palette.

## Documentation

Update the relevant ADR, source comments, or tests to say native SwiftUI is the
implementation choice, but the visual contract is Android-derived. The durable
record should explicitly reject one-off local styling in #155 and #159.

## Acceptance

#166 is complete when:

- A shared native SwiftUI settings presentation layer exists.
- `SettingsView` uses it for at least the first Application preferences pass.
- The resulting settings surface follows the Android screenshots for layout and icon treatment: full-width rows, left icons, themed section headers/accent controls, muted summaries, disabled states, and app-style toolbar actions.
- Row icons are mapped from Android `android:icon` references and drawable/vector sources, with documented fallbacks for any asset that cannot be ported directly.
- The settings surface inherits the rest of the app’s active theme in light and dark modes.
- The implementation leaves search/reset behavior to #155 while providing the row metadata and presentation hooks those workflows need.
- The relevant ADR, source comments, or tests describe the Android-derived
  native settings visual contract.
