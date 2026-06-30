# 0006: Modal Presentation Ownership For Android Parity

Status: Accepted

Date: 2026-06-23

## Context

The iOS app has several user-visible presentation surfaces implemented with
SwiftUI sheets, confirmation dialogs, alerts, UIKit wrappers, and reader-owned
modal coordinators. Some of those are legitimate iOS platform boundaries, such
as share sheets and file import/export pickers. Others are app-owned AndBible
flows that Android presents through the reader WebView bridge, Android
activities, popup menus, or domain-specific dialogs.

Treating every Android dialog or activity as interchangeable with a SwiftUI
sheet creates parity drift. It can preserve a rough user outcome while changing
the ownership model, visual hierarchy, available actions, default/cancel
semantics, state persistence, or follow-up routing. The risk is highest in the
reader because reader actions can cross WebView state, module selection,
bookmark and StudyPad mutation, settings inheritance, and platform services.

The project parity standard allows native iOS presentation only when it
preserves the same visible information architecture and user outcome. That rule
needs a concrete ownership matrix so future PRs can decide whether a sheet is a
valid parity implementation, a temporary gap, or an intentional platform
adaptation.

## Decision

iOS presentation work must classify each parity-sensitive modal, sheet, dialog,
popover, alert, file picker, and share surface by ownership before adding,
preserving, or replacing it.

Use these ownership categories:

| Owner category | Definition | iOS rule |
| --- | --- | --- |
| `Vue/WebView-owned` | Android owns the interaction from the shared document client or `BibleJavascriptInterface`, and the flow depends on WebView document state or bridge callbacks. | Prefer the same WebView/bridge-owned route on iOS. A native SwiftUI sheet is a parity gap unless a product decision documents why the bridge-owned surface cannot be used. |
| `Android app-owned` | Android presents an AndBible activity, fragment, popup menu, or custom dialog for an app workflow. | Build or reuse an iOS app-owned surface that matches Android behavior and visual structure. Do not substitute a generic iOS sheet merely because it is easier to present. |
| `iOS system boundary` | The action crosses into an operating-system service such as sharing, file import/export, document picker, clipboard, or external URL handling. | Native iOS APIs are acceptable when they only replace the OS boundary and do not skip an AndBible-owned preview, confirmation, selection, or import step. |
| `Platform adaptation` | Android's exact surface is unavailable, unsafe, or intentionally out of scope on iOS, but the user outcome is equivalent. | Document the Android behavior, iOS behavior, reason, validation boundary, and re-evaluation trigger. |
| `Undecided parity gap` | Ownership has not been classified or Android behavior has not been inspected. | Treat as incomplete. Do not claim `Pass` or `Adapted Pass` until the owner is resolved. |

The initial cross-domain matrix is:

| Surface area | Current iOS pattern | Android owner or target | Required iOS direction | Follow-up |
| --- | --- | --- | --- | --- |
| Reader modal routing | `BibleReaderView` sheet and modal coordinator | Mixed: WebView bridge, app activities, popup menus, dialogs | Classify each reader action before preserving sheet usage | #244 |
| Document/module chooser | SwiftUI sheet with `BibleReaderModulePicker` | `ChooseDocument` activity backed by `DocumentSelectionBase` | App-owned chooser matching Android behavior, or documented adaptation | #245 |
| Bookmarks, labels, StudyPad | SwiftUI sheets for label assignment, label manager, and note editing | WebView events, `BibleView`, `ManageLabels`, StudyPad document updates | WebView/app-owned surfaces according to Android ownership | #246 |
| Search translation picker | SwiftUI sheet/list | Android multiselect `AlertDialog` from `Search.showTranslationSelector` | Android-equivalent multiselect surface, or documented adaptation | #247 |
| Text display editors | SwiftUI sheets and `UIFontPickerViewController` | Preference rows plus custom Android widgets/dialogs | Android-equivalent editor widgets where behavior or choices differ | #248 |
| Share/export/import file boundaries | `UIActivityViewController`, `fileImporter`, `fileExporter` | Android intents, content pickers, and share flows | iOS system boundary is acceptable when only the OS boundary is replaced | Document per feature when touched |
| Alerts and confirmation dialogs | SwiftUI `.alert` and `.confirmationDialog` | Android `AlertDialog` and `PopupMenu` | Acceptable only when labels, choices, defaults, destructive/cancel semantics, and follow-up behavior match | Document high-impact cases when touched |

Every PR that adds or materially changes a parity-sensitive presentation surface
must identify the owner category in one of:

- an ADR when the decision is durable or cross-cutting
- source comments or tests when the route is easy to regress
- the PR description when the change is small and already covered by an ADR or
  source/test contract

## Consequences

- A SwiftUI sheet is not automatically a parity problem, but it is also not
  automatically a valid adaptation. Ownership decides the bar.
- Reader presentation changes need extra scrutiny because they often sit at the
  boundary between native SwiftUI routing and WebView-owned Android behavior.
- Platform-native share and file pickers remain acceptable when they are only
  replacing platform services, but they must not swallow AndBible-owned
  selection, confirmation, preview, or import/export behavior.
- Domain issues for the highest-risk surfaces stay separate so fixes can be
  implemented and validated without one large presentation rewrite.
- Parity status should use `Partial`, `Documented Divergence`, or `Automation
  Gap` when a surface has equivalent behavior but no ownership classification or
  visual validation.
- If Android changes a surface owner, this ADR and the relevant tests or source
  contracts should be updated before iOS preserves the older route.

## Related

- [ADR 0008: Parity Documentation Ownership](0008-parity-documentation-ownership.md)
- #244
- #245
- #246
- #247
- #248
- #249
